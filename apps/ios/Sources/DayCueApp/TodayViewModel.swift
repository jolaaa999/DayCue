import Foundation
import DayCueCore

struct TodaySection: Identifiable {
    let id: String
    let title: String
    let footer: String?
    let tasks: [TaskRecord]
}

@MainActor
final class TodayViewModel: ObservableObject {

    /// 临期待办的视野：7 天。更远的任务不出现在今天页，只给一个数量提示。
    static let horizonDays = 7

    @Published private(set) var sections: [TodaySection] = []
    @Published private(set) var pendingCaptures: [CaptureRecord] = []
    @Published private(set) var syncIssues: [TaskRecord] = []
    @Published private(set) var hiddenLaterCount = 0
    @Published private(set) var busyTaskId: String?
    @Published var banner: String?

    /// 需要用户确认才继续的撤销。
    @Published var pendingUndo: (taskId: String, message: String)?

    private var container: AppContainer?

    func attach(_ container: AppContainer) {
        self.container = container
    }

    func reload() {
        guard let container else { return }
        let store = container.store

        let openTasks = (try? store.openTasks()) ?? []
        let issues = (try? store.syncIssueTasks()) ?? []
        syncIssues = issues
        let issueIds = Set(issues.map { $0.id })

        let horizon = Self.horizonLocalDate()
        var visible: [TaskRecord] = []
        var hidden = 0
        for task in openTasks where !issueIds.contains(task.id) {
            guard let plannedDate = Self.plannedDate(of: task) else {
                // 完全没有时间的任务仍然要出现在今天页，否则用户会觉得记录丢了。
                visible.append(task)
                continue
            }
            if plannedDate <= horizon {
                visible.append(task)
            } else {
                hidden += 1
            }
        }
        hiddenLaterCount = hidden

        var built: [TodaySection] = []
        built.append(TodaySection(
            id: "due",
            title: "临期待办",
            footer: hidden > 0 ? "还有 \(hidden) 条更晚的待办，完成当前这些后会出现。" : nil,
            tasks: TaskOrdering.sorted(visible)
        ))
        sections = built
        pendingCaptures = (try? store.unfinishedCaptures()) ?? []
    }

    // MARK: - 操作

    func complete(_ task: TaskRecord) async {
        guard let container else { return }
        busyTaskId = task.id
        defer { busyTaskId = nil }
        let outcome = await container.writer.markDone(taskId: task.id)
        if let note = outcome.note { banner = note }
        reload()
    }

    func reopen(_ task: TaskRecord) async {
        guard let container else { return }
        busyTaskId = task.id
        defer { busyTaskId = nil }
        _ = await container.writer.reopen(taskId: task.id)
        reload()
    }

    func retry(_ task: TaskRecord) async {
        guard let container else { return }
        busyTaskId = task.id
        defer { busyTaskId = nil }
        await container.refreshPermissions()
        let outcome = await container.writer.retryWrite(taskId: task.id)
        banner = outcome.note
        reload()
    }

    func canRetry(_ task: TaskRecord) -> Bool {
        task.status == .open && task.externalWriteState != .written
    }

    func canUndo(_ task: TaskRecord) -> Bool {
        guard let container else { return false }
        return ((try? container.store.externalBinding(taskId: task.id)) ?? nil) != nil
    }

    func undo(_ task: TaskRecord) async {
        guard let container else { return }
        busyTaskId = task.id
        defer { busyTaskId = nil }
        switch await container.writer.undo(taskId: task.id, userConfirmedExternalEdit: false) {
        case .removed:
            banner = "已撤销这条任务。"
        case let .needsConfirmation(reason):
            pendingUndo = (task.id, reason)
        case let .failed(message):
            banner = message
        }
        reload()
    }

    func confirmUndo() async {
        guard let container, let pending = pendingUndo else { return }
        pendingUndo = nil
        busyTaskId = pending.taskId
        defer { busyTaskId = nil }
        switch await container.writer.undo(taskId: pending.taskId, userConfirmedExternalEdit: true) {
        case let .removed(externalDeleted):
            banner = externalDeleted ? "已删除苹果提醒事项并移除本地任务。" : "已解除绑定，苹果提醒事项保持原样。"
        case let .needsConfirmation(reason):
            banner = reason
        case let .failed(message):
            banner = message
        }
        reload()
    }

    func cancelUndo() {
        pendingUndo = nil
    }

    /// 外部变更后做一次保守对账。只标记待对账，不猜字段。
    func reconcileFromExternalChanges() async {
        guard let container else { return }
        let bound = ((try? container.store.tasks(status: .open)) ?? []).filter { task in
            ((try? container.store.externalBinding(taskId: task.id)) ?? nil) != nil
        }
        for task in bound {
            await container.writer.reconcile(taskId: task.id)
        }
        reload()
    }

    private static func horizonLocalDate() -> String {
        let date = Calendar.current.date(byAdding: .day, value: horizonDays, to: Date()) ?? Date()
        return RFC3339.localDateString(from: date)
    }

    /// 任务"什么时候该做"的日期部分：优先提醒时刻，其次截止时间。
    /// 两者都没有时返回 nil，由调用方把任务仍放进今天页。
    private static func plannedDate(of task: TaskRecord) -> String? {
        let raw = task.remindLocal ?? task.dueLocal
        guard let raw, raw.count >= 10 else { return nil }
        return String(raw.prefix(10))
    }
}
