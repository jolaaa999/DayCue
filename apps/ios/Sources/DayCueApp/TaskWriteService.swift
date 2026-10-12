import Foundation
import EventKit
import DayCueCore

/// 撤销结果。区分"删了外部对象"和"只解除绑定"很重要：
/// 用户可能在苹果侧改过时间，这时候删掉外部提醒等于抹掉用户自己的修改。
enum UndoOutcome: Equatable {
    case removed(externalDeleted: Bool)
    case needsConfirmation(reason: String)
    case failed(String)
}

/// 任务写入编排。
///
/// 执行链固定为 validate -> authorize -> enqueue -> execute -> reconcile -> receipt。
/// 之所以把所有系统写操作收在这一个类里，是因为设计文档要求"程序验证权限、模型只生成候选"：
/// 任何 LLM 输出都必须先变成 TaskRecord 才能走到这里。
@MainActor
final class TaskWriteService {

    private let store: DayCueStore
    private let settings: AppSettings
    private let reminders: ReminderService
    private let notifications: NotificationService

    /// 同一个任务的写入互斥。见 InFlightWriteGuard 的注释：
    /// 幂等键只能保证「同一个 key 只有一行 outbox」，防不住两次并发执行都去创建外部提醒。
    private let writeGuard = InFlightWriteGuard()

    struct Outcome {
        let task: TaskRecord?
        let note: String?
    }

    init(
        store: DayCueStore,
        settings: AppSettings,
        reminders: ReminderService,
        notifications: NotificationService
    ) {
        self.store = store
        self.settings = settings
        self.reminders = reminders
        self.notifications = notifications
    }

    // MARK: - 创建

    /// 用户确认后创建任务。本地先落库，再决定要不要写外部。
    func createTask(from draft: ReviewDraft, captureId: String) async -> Outcome {
        var task = draft.makeTask(captureId: captureId)
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 标题是唯一必需字段；留空时退回原文依据，而不是写一个空标题进系统提醒。
        task.title = title.isEmpty
            ? (draft.sourceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名任务" : draft.sourceEvidence)
            : title

        do {
            try store.insertTask(task)
        } catch {
            return Outcome(task: nil, note: "保存到本机失败：\(error)")
        }

        return await applyExternalWrite(taskId: task.id, forcedNote: nil)
    }

    /// 后端不可用时的手动创建：用户自己选日期。
    func createManualTask(
        title: String,
        detail: String?,
        dueKind: DueKind,
        dueDate: Date?,
        remindDate: Date?,
        timeZone: TimeZone,
        captureId: String?
    ) async -> Outcome {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Outcome(task: nil, note: "请先填写任务标题。")
        }

        var task = TaskRecord(
            title: trimmed,
            detail: detail,
            dueKind: dueKind,
            timezone: timeZone.identifier,
            originCaptureId: captureId
        )
        if let dueDate {
            switch dueKind {
            case .none:
                task.dueLocal = nil
                task.dueUTC = nil
            case .date:
                task.dueLocal = RFC3339.localDateString(from: dueDate, timeZone: timeZone)
                // 日期型只写墙上日期，不写 UTC。
            case .datetime:
                task.dueLocal = RFC3339.localString(from: dueDate, timeZone: timeZone)
                task.dueUTC = RFC3339.utcString(from: dueDate)
            }
        }
        if let remindDate {
            task.remindLocal = RFC3339.localString(from: remindDate, timeZone: timeZone)
            task.remindUTC = RFC3339.utcString(from: remindDate)
        }

        do {
            try store.insertTask(task)
        } catch {
            return Outcome(task: nil, note: "保存到本机失败：\(error)")
        }
        return await applyExternalWrite(taskId: task.id, forcedNote: nil)
    }

    // MARK: - 重试写入

    func retryWrite(taskId: String) async -> Outcome {
        guard let task = try? store.task(id: taskId) else {
            return Outcome(task: nil, note: "找不到这条任务。")
        }
        // 已经写入过的不再重试，避免产生第二条外部提醒。
        guard task.externalWriteState != .written else {
            return Outcome(task: task, note: "这条任务已经写入苹果提醒事项。")
        }
        return await applyExternalWrite(taskId: taskId, forcedNote: nil)
    }

    // MARK: - 完成

    /// 标记完成。
    ///
    /// 只改本地状态并取消本地通知，不主动去改苹果侧对象：
    /// 外部完成状态的读取属于双向同步（P1），第一阶段不假装已经同步。
    func markDone(taskId: String) async -> Outcome {
        do {
            try store.markTaskDone(id: taskId)
        } catch {
            return Outcome(task: nil, note: "更新失败：\(error)")
        }
        notifications.cancelReminder(taskId: taskId)
        return Outcome(task: try? store.task(id: taskId), note: nil)
    }

    func reopen(taskId: String) async -> Outcome {
        do {
            try store.reopenTask(id: taskId)
        } catch {
            return Outcome(task: nil, note: "更新失败：\(error)")
        }
        return Outcome(task: try? store.task(id: taskId), note: nil)
    }

    // MARK: - 撤销

    /// 撤销自动创建。
    ///
    /// 外部对象被用户在苹果侧改过时，必须用户再确认才允许删除；
    /// 未确认时只解除绑定，外部提醒原样保留。
    func undo(taskId: String, userConfirmedExternalEdit: Bool) async -> UndoOutcome {
        // 撤销同样是系统写入入口，必须和创建共用同一把闸门：
        // 否则用户可能在写入进行中删掉外部对象，形成"创建与删除交错"的中间态。
        let acquired = await writeGuard.begin(taskId)
        guard acquired else {
            return .failed("这条任务正在写入苹果提醒事项，请稍候再试。")
        }
        let outcome = await performUndo(taskId: taskId, userConfirmedExternalEdit: userConfirmedExternalEdit)
        await writeGuard.end(taskId)
        return outcome
    }

    private func performUndo(taskId: String, userConfirmedExternalEdit: Bool) async -> UndoOutcome {
        let binding = (try? store.externalBinding(taskId: taskId)) ?? nil

        if let binding, let externalId = binding.externalId, !externalId.isEmpty {
            guard let reminder = reminders.reminder(withIdentifier: externalId) else {
                // 外部对象已经不存在（用户删了、或换了账号），只需要清理本地。
                return removeLocalTask(taskId: taskId, externalDeleted: true, note: nil)
            }

            if reminders.isExternallyModified(binding: binding), !userConfirmedExternalEdit {
                return .needsConfirmation(
                    reason: "这条提醒在苹果提醒事项里被改过（\(reminder.title ?? "无标题")）。" +
                        "继续撤销只会解除绑定，不会删除你改过的提醒。"
                )
            }

            if !reminders.isExternallyModified(binding: binding) {
                do {
                    try reminders.deleteReminder(withIdentifier: externalId)
                    return removeLocalTask(taskId: taskId, externalDeleted: true, note: nil)
                } catch {
                    return .failed(error.localizedDescription)
                }
            } else {
                // 用户确认过：只解绑，不删外部项目。
                return removeLocalTask(
                    taskId: taskId,
                    externalDeleted: false,
                    note: "已解除绑定，苹果提醒事项里的那一条保持原样。"
                )
            }
        }

        return removeLocalTask(taskId: taskId, externalDeleted: false, note: nil)
    }

    private func removeLocalTask(taskId: String, externalDeleted: Bool, note: String?) -> UndoOutcome {
        notifications.cancelReminder(taskId: taskId)
        do {
            try store.deleteExternalBinding(taskId: taskId)
            try store.softDeleteTask(id: taskId)
        } catch {
            return .failed("清理本地数据失败：\(error)")
        }
        return .removed(externalDeleted: externalDeleted)
    }

    // MARK: - 对账

    /// 外部变化后的保守对账：只判断"外部对象还在不在、快照还对不对得上"，
    /// 不做字段级猜测，也不自动覆盖用户的手工修改。
    func reconcile(taskId: String) async {
        guard let binding = (try? store.externalBinding(taskId: taskId)) ?? nil else { return }
        guard let task = try? store.task(id: taskId), !task.isDeleted else { return }

        guard let externalId = binding.externalId, !externalId.isEmpty else {
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .needsReconciliation)
            return
        }

        guard reminders.reminder(withIdentifier: externalId) != nil else {
            // 外部项目消失：不立即删除本地记录，只标记待对账让用户决定。
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .needsReconciliation)
            return
        }

        if reminders.isExternallyModified(binding: binding) {
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .needsReconciliation)
        }
    }

    // MARK: - 启动恢复

    /// 启动与回到前台时调用。
    ///
    /// 处理的是「进程被杀在写入中途」留下的两种残留：
    /// 1. 任务停在 `pending`——外部可能已经写成功、只是本地回执没落库。
    ///    重试是**安全**的，因为写入前会按稳定标识查重（见 ReminderService.lookupReminder），
///    而查重只有在「查询成功且范围完整」时才允许创建。
    /// 2. 任务停在 `unknown`——连"写没写"都不知道。这类**绝不自动重写**，
    ///    只降级为「需要对账」，交给用户在今天页的同步异常分区里处理。
    ///
    /// 返回值仅用于日志与验收观察，界面不依赖它。
    @discardableResult
    func recoverInterruptedWrites() async -> (recovered: Int, flagged: Int) {
        // 先把进程中断残留的 running 记录放回队列，否则它们永远不会被看到。
        try? store.requeueStaleOutboxOperations()

        // 状态未知的先标记出来，让用户至少能在界面上看见，而不是默默停在中间态。
        let flagged = (try? store.markUnknownWritesForReconciliation()) ?? 0

        // 待重试的任务有两个来源，取并集：
        // 1. outbox 里可执行的操作——这是持久化的调度依据，即使任务状态被改坏也还在；
        // 2. 任务自身停在 pending——覆盖"入队前就崩了"的情况（此时还没有 outbox 行）。
        var taskIds = Set((try? store.pendingExternalWriteTasks())?.map(\.id) ?? [])
        let runnable = (try? store.runnableOutboxOperations()) ?? []
        for op in runnable where op.op == .createReminder {
            taskIds.insert(op.entityId)
        }

        var recovered = 0
        for taskId in taskIds.sorted() {
            let outcome = await applyExternalWrite(taskId: taskId, forcedNote: nil)
            if outcome.task?.externalWriteState == .written {
                recovered += 1
            }
        }
        return (recovered, flagged)
    }

    // MARK: - 内部：写入链

    /// 外部写入的**唯一入口**：先抢闸门，抢不到就明确告诉用户"正在写入"。
    ///
    /// 这一段单独存在是为了保证闸门在任何路径上都会被释放，
    /// 而真正干活的 performExternalWrite 可以随意提前 return。
    private func applyExternalWrite(taskId: String, forcedNote: String?) async -> Outcome {
        let acquired = await writeGuard.begin(taskId)
        guard acquired else {
            // 不是错误：用户连点了两次，第二次直接被挡下，不会产生第二条外部提醒。
            return Outcome(task: try? store.task(id: taskId), note: "这条任务正在写入苹果提醒事项，请稍候。")
        }
        let outcome = await performExternalWrite(taskId: taskId, forcedNote: forcedNote)
        await writeGuard.end(taskId)
        return outcome
    }

    private func performExternalWrite(taskId: String, forcedNote: String?) async -> Outcome {
        guard let task = try? store.task(id: taskId) else {
            return Outcome(task: nil, note: "找不到这条任务。")
        }

        // authorize：权限与清单在执行时再检查一次，而不是只在设置页检查。
        guard reminders.isAuthorized else {
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .waitingForPermission)
            await scheduleLocalReminder(taskId: taskId)
            let refreshed = try? store.task(id: taskId)
            return Outcome(
                task: refreshed,
                note: forcedNote ?? "尚未获得提醒事项权限，任务已保存在 App，可在今天页重试写入。"
            )
        }

        guard let list = defaultWritableList() else {
            // 有权限但没有可写的选中清单：保留 App 待办，不静默改写到别的清单。
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .notRequested)
            await scheduleLocalReminder(taskId: taskId)
            let refreshed = try? store.task(id: taskId)
            return Outcome(
                task: refreshed,
                note: "还没有选择可写的提醒清单，任务只保存在 App。"
            )
        }

        // enqueue：幂等键由程序确定性生成，重复点按不会产生第二条外部提醒。
        let key = IdempotencyKey.createReminder(taskId: taskId, listId: list.id)
        let payload = try? DayCueJSON.encodeToString([
            "task_id": taskId,
            "list_id": list.id,
            "list_title": list.title
        ])
        _ = try? store.enqueueOutboxOperation(
            entityType: .task,
            entityId: taskId,
            op: .createReminder,
            idempotencyKey: key,
            payloadJSON: payload
        )

        _ = try? store.setTaskExternalWriteState(id: taskId, to: .pending)
        // 记录「正在执行」。进程若在下面被打断，这一行会留在库里，
        // 启动恢复据此知道有写入中途被打断，而不是永远看不到它。
        markOutbox(key: key, state: .running, error: nil)

        // execute
        do {
            let binding = try await reminders.createReminder(for: task, listId: list.id, listTitle: list.title)
            #if DEBUG
            // 仅 Debug：把「外部已写入、本地回执未落库」这个几十毫秒的窗口变成可重复测试。
            DebugWriteFaultInjection.haltIfEnabled()
            #endif
            try store.upsertExternalBinding(binding)
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .written)
            markOutbox(key: key, state: .succeeded, error: nil)

            // 苹果提醒事项已经在管这条任务的到点提醒，取消 App 可能安排过的本地通知。
            notifications.cancelReminder(taskId: taskId)

            return Outcome(task: try? store.task(id: taskId), note: nil)
        } catch let error as ReminderServiceError {
            let resolved = await resolveFailure(error, taskId: taskId, list: list)
            markOutbox(key: key, state: resolved.outboxState, error: resolved.message)
            await scheduleLocalReminderIfNeeded(taskId: taskId)
            return Outcome(task: try? store.task(id: taskId), note: resolved.message)
        } catch {
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .failed)
            markOutbox(key: key, state: .failed, error: error.localizedDescription)
            await scheduleLocalReminderIfNeeded(taskId: taskId)
            return Outcome(
                task: try? store.task(id: taskId),
                note: "写入苹果提醒事项失败：\(error.localizedDescription)"
            )
        }
    }

    /// 失败分类。
    ///
    /// save 之前失败的（没权限、清单不可写、清单不存在）可以确定"没有写入"；
    /// save 抛错时无法确定系统是否已经落盘，所以先标 unknown 并立刻按稳定标识回查一次，
    /// 查到就补记回执，查不到才降级为 failed。这就是设计文档里的 reconcile 步骤。
    private func resolveFailure(
        _ error: ReminderServiceError,
        taskId: String,
        list: ReminderList
    ) async -> (outboxState: OutboxState, message: String) {
        switch error {
        case .notAuthorized:
            // 权限在写入过程中被撤销：这不是"失败"，是"等授权"，任务留在 App。
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .waitingForPermission)
            return (.failed, "提醒事项权限已失效，任务仍保存在 App，授权后可重试写入。")
        case .listNotWritable, .listNotFound:
            // 这两类在 save 之前就失败了，可以确定"外部没有写入"。
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .failed)
            return (.failed, error.localizedDescription)
        case .saveFailed, .deleteFailed, .lookupInconclusive:
            _ = try? store.setTaskExternalWriteState(id: taskId, to: .unknown)

            // 回查一次：确认外部到底有没有落盘。这里的结论同样只能是三分的。
            let lookup = await reminders.lookupReminder(forTaskId: taskId)
            switch lookup.outcome {
            case .found:
                guard let existing = lookup.reminder else {
                    _ = try? store.setTaskExternalWriteState(id: taskId, to: .needsReconciliation)
                    return (.unknown, "写入结果无法确认，已标记为需要对账。")
                }
                let binding = ExternalBindingRecord(
                    taskId: taskId,
                    provider: ReminderService.providerName,
                    listId: existing.calendar?.calendarIdentifier ?? list.id,
                    listTitle: existing.calendar?.title ?? list.title,
                    externalId: existing.calendarItemIdentifier,
                    externalLastModified: existing.lastModifiedDate.map { RFC3339.utcString(from: $0) },
                    snapshotJSON: nil,
                    createdAt: DayCueClock.nowUTCString()
                )
                try? store.upsertExternalBinding(binding)
                _ = try? store.setTaskExternalWriteState(id: taskId, to: .written)
                notifications.cancelReminder(taskId: taskId)
                return (.succeeded, "首次写入报错，但回查确认提醒已存在，已补记绑定。")
            case .notFound:
                // 两段查询都成功且都没命中，才能确定"确实没写进去"。
                _ = try? store.setTaskExternalWriteState(id: taskId, to: .failed)
                return (.failed, error.localizedDescription)
            default:
                // 查不了：既不能说写了，也不能说没写。停止自动重写，交给对账。
                _ = try? store.setTaskExternalWriteState(id: taskId, to: .needsReconciliation)
                return (
                    .unknown,
                    "写入结果无法确认（\(lookup.outcome.diagnosticName)），已标记为需要对账，不会自动重写。"
                )
            }
        }
    }

    private func markOutbox(key: String, state: OutboxState, error: String?) {
        guard let record = try? store.outboxOperation(idempotencyKey: key) else { return }
        let nextRetry = state == .failed
            ? RFC3339.utcString(from: Date().addingTimeInterval(60))
            : nil
        try? store.updateOutboxOperation(
            id: record.id,
            state: state,
            attempt: record.attempt + 1,
            lastError: error,
            nextRetryAt: nextRetry
        )
    }

    // MARK: - 内部：本地通知兜底

    /// 只有在任务确实没有交给苹果提醒事项时才安排本地通知，避免双重提醒。
    private func scheduleLocalReminderIfNeeded(taskId: String) async {
        guard let task = try? store.task(id: taskId), task.externalWriteState != .written else { return }
        await scheduleLocalReminder(taskId: taskId)
    }

    private func scheduleLocalReminder(taskId: String) async {
        guard let task = try? store.task(id: taskId) else { return }
        await notifications.scheduleReminder(for: task)
    }

    /// 只返回"用户选中并且可写"的清单。
    /// 选中的清单不可写时返回 nil，由调用方保留 App 待办并提示，而不是静默改写其他清单。
    private func defaultWritableList() -> ReminderList? {
        guard let id = settings.defaultListId else { return nil }
        return reminders.reminderLists().first { $0.id == id && $0.isWritable }
    }
}
