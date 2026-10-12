import Foundation
import EventKit
import DayCueCore

/// 苹果提醒事项清单（EKCalendar，type == .reminder）。
struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
    let isWritable: Bool
}

enum ReminderServiceError: LocalizedError {
    case notAuthorized
    case listNotWritable(String)
    case listNotFound(String)
    case saveFailed(String)
    case deleteFailed(String)
    /// 查重无法给出确定结论（无权限、查询失败、范围不完整）。
    /// 单独一个 case 是为了让调用方能"停下来"，而不是当成"没找到"继续创建。
    case lookupInconclusive(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "尚未获得提醒事项的完整访问权限。"
        case let .listNotWritable(title):
            return "清单「\(title)」不可写入，请换一个清单。"
        case let .listNotFound(id):
            return "找不到指定的清单（\(id)）。"
        case let .saveFailed(message):
            return "写入苹果提醒事项失败：\(message)"
        case let .deleteFailed(message):
            return "删除苹果提醒事项失败：\(message)"
        case let .lookupInconclusive(detail):
            return "无法确认苹果提醒事项里是否已有这条任务（\(detail)），已停止自动写入以免产生重复。"
        }
    }
}

/// EventKit 写入适配器。
///
/// 三条硬规则：
/// 1. 写入前先按稳定标识查重，重试或崩溃都不会产生第二条提醒。
/// 2. 写入成功才保存 external_binding 与字段快照，失败必须落 failed / unknown。
/// 3. 监听 EKEventStoreChanged 后只标记 needs_reconciliation，不猜具体字段变化。
@MainActor
final class ReminderService: ObservableObject {

    static let providerName = "apple_reminders"

    private let store = EKEventStore()

    private var observer: NSObjectProtocol?

    init() {
        // 先把 observer 置空。addObserver 的闭包是逃逸闭包，会捕获 self，
        // 而 Swift 不允许在还有未初始化存储属性时把 self 带进逃逸闭包。
        observer = nil
        // EKEventStoreChanged 只说"有变化"，不含具体字段，所以这里只登记待对账。
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markAllBoundTasksForReconciliation()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 权限

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    /// iOS 17 的完整访问权限申请。
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    // MARK: - 清单

    func reminderLists() -> [ReminderList] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, isWritable: $0.allowsContentModifications) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func writableReminderLists() -> [ReminderList] {
        reminderLists().filter { $0.isWritable }
    }

    func calendar(withIdentifier identifier: String) -> EKCalendar? {
        store.calendar(withIdentifier: identifier)
    }

    // MARK: - 写入

    /// 创建提醒事项。
    ///
    /// - 已经存在同 identifier 或 notes 里带同一个 DayCue 任务 id 的外部对象时，直接复用它，
    ///   不新建——这是"重试不产生重复"的最后一道保险。
    func createReminder(
        for task: TaskRecord,
        listId: String,
        listTitle: String
    ) async throws -> ExternalBindingRecord {
        guard isAuthorized else { throw ReminderServiceError.notAuthorized }
        guard let calendar = store.calendar(withIdentifier: listId) else {
            throw ReminderServiceError.listNotFound(listId)
        }
        guard calendar.allowsContentModifications else {
            throw ReminderServiceError.listNotWritable(calendar.title)
        }

        // 先按稳定标识找已有的外部对象（上次写入成功但没来得及记回执的情况）。
        // 只有"查询成功、范围完整、确实没有"才允许往下创建；
        // 把"查不到"和"查不了"混为一谈，就会凭空多出一条外部提醒。
        let lookup = await lookupReminder(forTaskId: task.id)
        switch lookup.outcome {
        case .found:
            guard let existing = lookup.reminder else {
                throw ReminderServiceError.lookupInconclusive("命中了却取不回对象")
            }
            return try makeBinding(task: task, reminder: existing, listId: listId, listTitle: listTitle)
        case .notFound:
            break
        default:
            throw ReminderServiceError.lookupInconclusive(lookup.outcome.diagnosticName)
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = task.title
        reminder.notes = ExternalIdentifier.noteBody(task: task, deepLink: "daycue://task/" + task.id)

        if let components = dueComponents(for: task) {
            reminder.dueDateComponents = components
        }
        if let alarm = alarm(for: task) {
            reminder.addAlarm(alarm)
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }

        return try makeBinding(task: task, reminder: reminder, listId: listId, listTitle: listTitle)
    }

    /// 查重的完整结论。区分"找到了"与"查不了"是本类型存在的全部理由。
    struct ReminderLookup {
        let outcome: ReminderLookupOutcome
        let reminder: EKReminder?
    }

    /// 按 notes 里的稳定任务标识查重。绝不按标题模糊匹配。
    ///
    /// 必须查两段：EventKit 把"未完成"与"已完成"分成两个谓词。
    /// 只查未完成项，会把用户在苹果侧勾掉的那条当成不存在，然后重建一条重复的。
    func lookupReminder(forTaskId taskId: String) async -> ReminderLookup {
        guard isAuthorized else {
            return ReminderLookup(outcome: .notAuthorized, reminder: nil)
        }

        let incomplete = await fetch(taskId: taskId, predicate: store.predicateForReminders(in: nil))
        let completed = await fetch(
            taskId: taskId,
            predicate: store.predicateForCompletedReminders(
                withCompletionDateStarting: nil,
                ending: nil,
                calendars: nil
            )
        )

        let outcome = ReminderLookupPolicy.classify(
            authorized: true,
            incomplete: ReminderLookupPolicy.Fetch(
                succeeded: incomplete.succeeded,
                matchExternalId: incomplete.match?.calendarItemIdentifier
            ),
            completed: ReminderLookupPolicy.Fetch(
                succeeded: completed.succeeded,
                matchExternalId: completed.match?.calendarItemIdentifier
            )
        )
        return ReminderLookup(outcome: outcome, reminder: incomplete.match ?? completed.match)
    }

    /// EventKit 用「完成回调收到 nil」表示这一批没取到，所以成功与否必须单独回传，
    /// 不能把 nil 折叠成"没找到"。
    private func fetch(
        taskId: String,
        predicate: NSPredicate
    ) async -> (succeeded: Bool, match: EKReminder?) {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: (false, nil))
                    return
                }
                let match = reminders.first { reminder in
                    ExternalIdentifier.taskId(fromNotes: reminder.notes) == taskId
                }
                continuation.resume(returning: (true, match))
            }
        }
    }

    /// 按 EventKit 的 calendarItemIdentifier 取回外部对象。
    func reminder(withIdentifier identifier: String) -> EKReminder? {
        store.calendarItem(withIdentifier: identifier) as? EKReminder
    }

    func deleteReminder(withIdentifier identifier: String) throws {
        guard let reminder = reminder(withIdentifier: identifier) else { return }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw ReminderServiceError.deleteFailed(error.localizedDescription)
        }
    }

    /// 外部对象是否被用户在苹果侧改过。
    /// 用 lastModifiedDate 与写入时的快照比较；任一侧缺失都按"可能被改过"处理，宁可多问一次。
    func isExternallyModified(binding: ExternalBindingRecord) -> Bool {
        guard let externalId = binding.externalId,
              let reminder = reminder(withIdentifier: externalId) else {
            // 外对象已经不在了，这也属于"与快照不一致"。
            return true
        }
        guard let snapshot = binding.externalLastModified,
              let current = reminder.lastModifiedDate else {
            return true
        }
        return RFC3339.utcString(from: current) != snapshot
    }

    // MARK: - 快照与绑定

    private func makeBinding(
        task: TaskRecord,
        reminder: EKReminder,
        listId: String,
        listTitle: String
    ) throws -> ExternalBindingRecord {
        // 拿不到稳定外部标识就无法在重试时查重，这时候必须报失败，
        // 否则会出现"写入成功但下次重试又建一条"的重复。
        guard !reminder.calendarItemIdentifier.isEmpty else {
            throw ReminderServiceError.saveFailed("系统未返回提醒事项的稳定标识")
        }
        return ExternalBindingRecord(
            taskId: task.id,
            provider: Self.providerName,
            listId: reminder.calendar?.calendarIdentifier ?? listId,
            listTitle: reminder.calendar?.title ?? listTitle,
            externalId: reminder.calendarItemIdentifier,
            externalLastModified: reminder.lastModifiedDate.map { RFC3339.utcString(from: $0) },
            snapshotJSON: snapshotJSON(for: reminder),
            createdAt: DayCueClock.nowUTCString()
        )
    }

    /// 快照只记录 App 真正映射过去的字段。苹果侧其他字段的变化不需要让 App 去"理解"。
    private func snapshotJSON(for reminder: EKReminder) -> String? {
        var payload: [String: String] = [:]
        payload["title"] = reminder.title ?? ""
        payload["notes"] = reminder.notes ?? ""
        payload["isCompleted"] = reminder.isCompleted ? "true" : "false"
        if let components = reminder.dueDateComponents {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            if let date = calendar.date(from: components) {
                payload["due"] = formatter.string(from: date)
            }
        }
        return try? DayCueJSON.encodeToString(payload)
    }

    // MARK: - 字段映射

    /// 截止时间映射。
    ///
    /// 日期型只给年月日，精确时间型给到分钟：这是"日期型截止日不得变成假时刻"的落点，
    /// EKReminder 在只有年月日时显示为全天截止，正好符合语义。
    func dueComponents(for task: TaskRecord) -> DateComponents? {
        switch task.dueKind {
        case .none:
            return nil
        case .date:
            guard let local = task.dueLocal, let date = RFC3339.date(fromLocal: local, timeZone: timeZone(for: task)) else {
                return nil
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone(for: task)
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return parts
        case .datetime:
            guard let local = task.dueLocal, let date = RFC3339.date(fromLocal: local, timeZone: timeZone(for: task)) else {
                return nil
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone(for: task)
            return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
    }

    /// 提醒时刻映射为绝对时间 alarm。
    /// 截止时间与提醒时间在 App 里是分离的两个字段，这里也保持分离。
    func alarm(for task: TaskRecord) -> EKAlarm? {
        guard let local = task.remindLocal,
              let date = RFC3339.date(fromLocal: local, timeZone: timeZone(for: task)) else {
            return nil
        }
        return EKAlarm(absoluteDate: date)
    }

    private func timeZone(for task: TaskRecord) -> TimeZone {
        TimeZone(identifier: task.timezone) ?? .current
    }

    // MARK: - 对账

    private func markAllBoundTasksForReconciliation() {
        // 这里不查库、不改状态，只递增一个信号。
        // 原因：EKEventStoreChanged 只说明"有变化"，不含字段级信息；
        // 此时唯一正确的动作是让 UI 触发一次对账，而不是在 EventKit 回调里猜字段。
        storeChangedSignal += 1
    }

    /// 递增即表示"外部变更过，需要对账"。UI 观察它的变化来触发对账。
    @Published private(set) var storeChangedSignal: Int = 0
}
