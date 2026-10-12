import Foundation
import EventKit
import DayCueCore

// 苹果提醒事项快照适配器：对账里唯一的「读 EventKit」出口。
//
// 为什么不把这段塞进 ReminderService：
// 那个类的职责是「写入 + 按稳定标识查重」，它的 EKEventStore 是私有属性，
// 而且它服务的是单条任务的写入路径；对账需要的是一次性的全量读取。
// 两种关注点混在一起会让那个文件越来越难改，所以这里单独一个适配器。
//
// EKEventStore 可以安全地多处实例化，授权状态是进程级的、与「用哪个实例」无关，
// 因此这里自建一个 store 不会与 ReminderService 的冲突。

/// 外部快照来源。
///
/// 抽成协议有两个目的：
/// 1. 编排器（ReconciliationCoordinator）不直接依赖 EventKit，将来换数据源不必改它；
/// 2. 让「读取外部快照」在类型上显式化，避免别处又随手 new 一个 EKEventStore 各读各的。
@MainActor
protocol ExternalReminderSnapshotSource {
    var isAuthorized: Bool { get }
    func fetchSnapshot() async -> ExternalSnapshotFetch
}

@MainActor
final class ExternalReminderSnapshotAdapter: ExternalReminderSnapshotSource {

    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    /// 与 ReminderService.isAuthorized 同一口径：只有 fullAccess 才算「能读全部」。
    /// 不能把 .writeOnly / .denied 当成可读：那样会读到空集合，
    /// 而对账层会把「读不到」理解成「外部一条都没有」，进而产出删除决策。
    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// 拉取一次快照。
    ///
    /// **两段式查询是硬要求，不是优化**：
    /// EventKit 把「未完成」与「已完成」分成两个不同的谓词。只查未完成段，
    /// 会把用户在苹果侧勾掉的那条当成「不存在」；而对账层一旦相信「外部没有这条」，
    /// 就会产出删除决策，删掉用户真正存在的东西。
    ///
    /// 所以两段各自独立执行、各自记录成功与否，最后交给 ReminderSnapshotQuery.make
    /// 判定范围。任何一段失败都会被标成「范围不完整」，
    /// 绝不会被折叠成「这些条目不存在」。
    func fetchSnapshot() async -> ExternalSnapshotFetch {
        guard isAuthorized else {
            // 没权限时连一段都不查。这里必须显式传 authorized: false，
            // 而不是返回一个空集合 —— 两者在对账语义上完全不同。
            return ReminderSnapshotQuery.make(
                authorized: false,
                incomplete: .failed,
                completed: .failed
            )
        }

        // 两段顺序执行而不是并行：EKEventStore 的回调队列本来就是这样设计的，
        // 顺序执行换来「不会有两段同时读写 store」的确定性，省下的那点时间用户看不见。
        let incomplete = await fetchSegment(
            predicate: eventStore.predicateForReminders(in: nil),
            segmentIsCompleted: false
        )
        let completed = await fetchSegment(
            predicate: eventStore.predicateForCompletedReminders(
                withCompletionDateStarting: nil,
                ending: nil,
                calendars: nil
            ),
            segmentIsCompleted: true
        )

        // 范围判定与条目合并的唯一入口。适配器不自己拼 scope，
        // 这样「一段失败」的语义与 DayCueCore 里被单元测试锁定的纯逻辑是同一段代码。
        return ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: incomplete,
            completed: completed
        )
    }

    // MARK: - 单段查询

    /// 单段查询。
    ///
    /// EventKit 的 fetchReminders 用「完成回调收到 nil」表示这一批没取到，
    /// 所以「成功与否」必须与「条目列表」分开回传。
    /// 把 nil 折叠成空数组，就是把一次查询失败永久地变成一个「不存在」的断言。
    private func fetchSegment(
        predicate: NSPredicate,
        segmentIsCompleted: Bool
    ) async -> ReminderSnapshotSegment {
        await withCheckedContinuation { (continuation: CheckedContinuation<ReminderSnapshotSegment, Never>) in
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: .failed)
                    return
                }

                let relevant: [EKReminder]
                if segmentIsCompleted {
                    // 已完成谓词本身就是权威：它返回的每一条都按已完成处理。
                    // 这里不再按 isCompleted 二次过滤，避免标记滞后导致条目被两段同时漏掉。
                    relevant = reminders
                } else {
                    // 未完成段剔除已完成项：predicateForReminders 在不同系统版本上的
                    // 完成状态语义并不一致，不过滤就可能与已完成段重叠，
                    // 让引擎误报「同一个任务在外部有重复条目」。
                    relevant = reminders.filter { !$0.isCompleted }
                }

                let items = relevant.map { reminder in
                    ExternalReminderProjection.makeSnapshot(from: reminder, isCompleted: segmentIsCompleted)
                }
                continuation.resume(returning: .ok(items))
            }
        }
    }
}

// MARK: - 投影

/// EKReminder 到 ExternalReminderSnapshot 的纯映射。
///
/// 抽成 enum 的 static 函数而不是实例方法，是因为这些函数会被 EventKit 的回调闭包调用：
/// 闭包不捕获 self，就不会把实例带过隔离边界，也不会因为 self 已释放而出问题。
private enum ExternalReminderProjection {

    static func makeSnapshot(from reminder: EKReminder, isCompleted: Bool) -> ExternalReminderSnapshot {
        ExternalReminderSnapshot(
            // 认不出稳定标识就是 nil，绝不按标题猜：猜错一次就可能删掉用户的东西。
            taskId: ExternalIdentifier.taskId(fromNotes: reminder.notes),
            externalId: reminder.calendarItemIdentifier,
            listId: reminder.calendar?.calendarIdentifier,
            listTitle: reminder.calendar?.title,
            title: reminder.title ?? "",
            // 必须复用核心层的剥离规则：DayCue 的记账行不属于用户备注，
            // 不剥掉的话每一轮对账都会误报「备注被改过」。
            detail: ExternalReminderNoteField.userDetail(fromNotes: reminder.notes),
            isCompleted: isCompleted,
            dueKind: dueKind(from: reminder.dueDateComponents),
            dueLocal: dueLocal(from: reminder.dueDateComponents),
            remindLocal: remindLocal(from: reminder),
            lastModified: reminder.lastModifiedDate.map { RFC3339.utcString(from: $0) }
        )
    }

    /// 截止时间的形态。
    /// 有年月日才谈得上截止日；再带时分就升级成精确时间型。
    static func dueKind(from components: DateComponents?) -> DueKind {
        guard let components,
              components.year != nil,
              components.month != nil,
              components.day != nil else {
            return .none
        }
        if components.hour != nil || components.minute != nil || components.second != nil {
            return .datetime
        }
        return .date
    }

    /// 截止时间的墙面字符串。
    ///
    /// 这里刻意直接用 DateComponents 的年月日时分，不经过 Date 转换：
    /// 写入链（ReminderService.dueComponents）就是把 task.dueLocal 拆成年月日/时分写进 EventKit，
    /// 并没有设置时区。要保证「写出去再读回来」得到同一个字符串，
    /// 读的这一侧也必须原样还原；一旦按某个时区重新换算，就会出现永远对不上的假差异。
    static func dueLocal(from components: DateComponents?) -> String? {
        guard let components,
              let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        switch dueKind(from: components) {
        case .none:
            return nil
        case .date:
            return date
        case .datetime:
            let hour = components.hour ?? 0
            let minute = components.minute ?? 0
            let second = components.second ?? 0
            return String(format: "%@T%02d:%02d:%02d", date, hour, minute, second)
        }
    }

    /// 提醒时刻。
    ///
    /// 只认「绝对时间」的 EKAlarm：App 的写入链只会写 EKAlarm(absoluteDate:)。
    /// 用户在苹果侧自己加的相对偏移提醒（例如「提前 1 天」）无法一一映射成 remind_local，
    /// 硬猜一个值只会制造假的字段差异，所以这里如实返回 nil。
    ///
    /// 时区取 .current：写入链用的是任务自身的 timezone。
    /// 当任务时区与设备时区不一致时，这里读回来的墙上时间可能与本地存的字符串不同，
    /// 这是已知限制（未编译验证），会在交付报告里说明。
    static func remindLocal(from reminder: EKReminder) -> String? {
        guard let alarm = reminder.alarms?.first(where: { $0.absoluteDate != nil }),
              let date = alarm.absoluteDate else {
            return nil
        }
        return RFC3339.localString(from: date, timeZone: .current)
    }
}
