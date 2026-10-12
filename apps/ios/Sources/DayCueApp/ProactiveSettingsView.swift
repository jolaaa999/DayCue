import SwiftUI
import DayCueCore

/// 「日内分钟数」与 DatePicker 用的 Date 之间的转换。
///
/// DatePicker 只认 Date，而预算与地点规则存的是墙面分钟数。
/// 转换只写这一处：每个界面各自拼一遍 Calendar 的话，迟早有人忘了清掉秒，
/// 结果存进去一个 22:30:47 这种用户没输过的值。
enum ClockEditing {

    static func date(fromMinutes minutes: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = clamped(minutes) / 60
        components.minute = clamped(minutes) % 60
        components.second = 0
        return calendar.date(from: components) ?? Date()
    }

    static func minutes(from date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func text(minutes: Int) -> String {
        String(format: "%02d:%02d", clamped(minutes) / 60, clamped(minutes) % 60)
    }

    private static func clamped(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }
}

/// 主动提醒设置：每日预算、静默时段、按类别开关。
///
/// 这些数字决定「DayCue 会不会烦到你」，所以每一项都要能在这里关掉、调小。
/// 配置存在本机 app_setting 表里，与后台任务共用同一个 key。
struct ProactiveSettingsView: View {

    @EnvironmentObject private var container: AppContainer

    @State private var config = ProactiveBudgetConfig.standard
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Stepper("默认每天最多 \(config.defaultDailyLimit) 条", value: defaultLimitBinding, in: 0...20)
            } header: {
                Text("每日预算")
            } footer: {
                Text("预算按自然日计算，过了零点自动从 0 开始。下面单独设置过的类别用自己的额度，其余用这里的默认值。设为 0 表示不再主动提醒。")
                    .font(.caption)
            }

            Section {
                ForEach(ProactiveMessageKind.allCases, id: \.rawValue) { kind in
                    Toggle(kind.displayName, isOn: enabledBinding(kind))
                    Stepper(
                        "\(kind.displayName)每天最多 \(config.dailyLimit(for: kind)) 条",
                        value: limitBinding(kind),
                        in: 0...10
                    )
                    Stepper(
                        "\(kind.displayName)冷却 \(Int(config.cooldown(for: kind) / 60)) 分钟",
                        value: cooldownBinding(kind),
                        in: 0...480,
                        step: 10
                    )
                }
            } header: {
                Text("按类别")
            } footer: {
                Text("关掉某一类之后，DayCue 不会再发这一类主动提醒。冷却时间指同一类消息两次之间至少要隔多久。")
                    .font(.caption)
            }

            Section {
                Toggle("启用静默时段", isOn: quietEnabledBinding)
                if !config.quietWindows.isEmpty {
                    DatePicker("开始", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: quietEndBinding, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("静默时段")
            } footer: {
                Text("静默时段内到点的提醒会**顺延**到时段结束之后再发，而不是被丢弃；如果顺延之后已经超过有效期，才会作废。跨零点（例如 22:30–07:00）也支持。")
                    .font(.caption)
            }

            Section {
                Text("DayCue 不会为了主动提醒在后台持续取你的位置。地点规则只在系统给出位置更新时判断，位置未知时不触发，也不用其它线索去猜。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("说明")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("主动提醒")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    // MARK: - 绑定

    private var defaultLimitBinding: Binding<Int> {
        Binding(
            get: { config.defaultDailyLimit },
            set: { newValue in
                config.defaultDailyLimit = max(0, newValue)
                persist()
            }
        )
    }

    private func enabledBinding(_ kind: ProactiveMessageKind) -> Binding<Bool> {
        Binding(
            get: { config.isEnabled(kind: kind) },
            set: { newValue in
                config.setEnabled(newValue, for: kind)
                persist()
            }
        )
    }

    private func limitBinding(_ kind: ProactiveMessageKind) -> Binding<Int> {
        Binding(
            get: { config.dailyLimit(for: kind) },
            set: { newValue in
                config.setDailyLimit(newValue, for: kind)
                persist()
            }
        )
    }

    private func cooldownBinding(_ kind: ProactiveMessageKind) -> Binding<Int> {
        Binding(
            get: { Int(config.cooldown(for: kind) / 60) },
            set: { newValue in
                config.setCooldown(TimeInterval(max(0, newValue) * 60), for: kind)
                persist()
            }
        )
    }

    private var quietEnabledBinding: Binding<Bool> {
        Binding(
            get: { !config.quietWindows.isEmpty },
            set: { newValue in
                config.quietWindows = newValue
                    ? [ProactiveQuietWindow(startMinutes: 22 * 60 + 30, endMinutes: 7 * 60)]
                    : []
                persist()
            }
        )
    }

    private var quietStartBinding: Binding<Date> {
        Binding(
            get: { ClockEditing.date(fromMinutes: config.quietWindows.first?.startMinutes ?? 22 * 60 + 30) },
            set: { newValue in
                let start = ClockEditing.minutes(from: newValue)
                var windows = config.quietWindows
                if windows.isEmpty {
                    windows = [ProactiveQuietWindow(startMinutes: start, endMinutes: 7 * 60)]
                } else {
                    windows[0].startMinutes = start
                }
                config.quietWindows = windows
                persist()
            }
        )
    }

    private var quietEndBinding: Binding<Date> {
        Binding(
            get: { ClockEditing.date(fromMinutes: config.quietWindows.first?.endMinutes ?? 7 * 60) },
            set: { newValue in
                let end = ClockEditing.minutes(from: newValue)
                var windows = config.quietWindows
                if windows.isEmpty {
                    windows = [ProactiveQuietWindow(startMinutes: 22 * 60 + 30, endMinutes: end)]
                } else {
                    windows[0].endMinutes = end
                }
                config.quietWindows = windows
                persist()
            }
        )
    }

    // MARK: - 数据

    private func load() {
        config = ProactiveBudgetConfigCodec.decode(container.store.setting(ProactiveSettingsKey.config))
    }

    private func persist() {
        do {
            try container.store.setSetting(
                ProactiveSettingsKey.config,
                value: ProactiveBudgetConfigCodec.encode(config)
            )
            message = "设置已保存。"
        } catch {
            message = "保存设置失败：\(error)"
        }
    }
}
