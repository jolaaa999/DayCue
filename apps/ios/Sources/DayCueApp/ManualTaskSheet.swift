import SwiftUI
import DayCueCore

/// 手动创建任务。
///
/// 存在的意义：后端不可用时（离线、超时、模型输出非法）用户仍然要能把事情记下来。
/// 这里所有字段都由用户自己选，App 不代填任何"猜出来的"时间。
struct ManualTaskSheet: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let captureId: String?
    let onFinished: (String) -> Void

    @State private var title = ""
    @State private var detail = ""
    @State private var dueKind: DueKind = .date
    @State private var dueDate = Date()
    @State private var hasReminder = false
    @State private var remindDate = Date()
    @State private var saving = false

    // 显式给初始化器：不依赖编译器合成的成员式初始化器，
    // 避免 private 属性包装器是否参与合成这种隐式规则影响可编译性。
    init(captureId: String?, onFinished: @escaping (String) -> Void) {
        self.captureId = captureId
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("任务标题", text: $title)
                    TextField("备注（可选）", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Picker("截止方式", selection: $dueKind) {
                        Text("不设置").tag(DueKind.none)
                        Text("仅日期").tag(DueKind.date)
                        Text("精确时间").tag(DueKind.datetime)
                    }
                    .pickerStyle(.segmented)

                    if dueKind != .none {
                        DatePicker(
                            dueKind == .datetime ? "截止时间" : "截止日期",
                            selection: $dueDate,
                            displayedComponents: dueDisplayedComponents
                        )
                    }

                    Toggle("设置提醒时间", isOn: $hasReminder)
                    if hasReminder {
                        DatePicker("提醒时间", selection: $remindDate, displayedComponents: [.date, .hourAndMinute])
                    }
                } header: {
                    Text("时间")
                } footer: {
                    Text("这里的时间完全由你选择。DayCue 不会替你补一个没有说出口的时刻。")
                        .font(.caption)
                }
            }
            .navigationTitle("手动创建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("创建") { Task { await create() } }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var dueDisplayedComponents: DatePickerComponents {
        dueKind == .datetime ? [.date, .hourAndMinute] : [.date]
    }

    private func create() async {
        saving = true
        defer { saving = false }

        let outcome = await container.writer.createManualTask(
            title: title,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : detail,
            dueKind: dueKind,
            dueDate: dueKind == .none ? nil : dueDate,
            remindDate: hasReminder ? remindDate : nil,
            timeZone: container.currentTimeZone,
            captureId: captureId
        )

        onFinished(outcome.note ?? "已创建任务。")
        dismiss()
    }
}
