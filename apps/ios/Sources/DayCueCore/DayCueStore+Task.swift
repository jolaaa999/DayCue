import Foundation

public extension DayCueStore {

    // MARK: - 任务

    @discardableResult
    func insertTask(_ task: TaskRecord) throws -> TaskRecord {
        var record = task
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO task
              (id, title, detail, status, due_kind, due_local, due_utc, timezone,
               remind_local, remind_utc, course_hint, origin_capture_id, origin_item_id,
               external_write_state, last_receipt_at, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(Self.taskValues(record))
        try statement.run()
        return record
    }

    /// 整行更新。用整行覆盖而不是动态拼 SQL，是为了让「哪些字段会被写」在调用点就完全可见。
    func updateTask(_ task: TaskRecord) throws {
        guard try self.task(id: task.id) != nil else { throw DayCueStoreError.taskNotFound(task.id) }
        var record = task
        record.updatedAt = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            """
            UPDATE task SET
              title = ?, detail = ?, status = ?, due_kind = ?, due_local = ?, due_utc = ?, timezone = ?,
              remind_local = ?, remind_utc = ?, course_hint = ?, origin_capture_id = ?, origin_item_id = ?,
              external_write_state = ?, last_receipt_at = ?, created_at = ?, updated_at = ?, deleted_at = ?
            WHERE id = ?;
            """
        )
        // VALUES 的顺序是 created_at 在前，UPDATE 里 created_at 排在 last_receipt_at 之后，
        // 所以这里显式列参数，不复用 taskValues 的顺序，避免以后改动列顺序时静默错位。
        try statement.bind([
            .text(record.title),
            .optionalText(record.detail),
            .text(record.status.rawValue),
            .text(record.dueKind.rawValue),
            .optionalText(record.dueLocal),
            .optionalText(record.dueUTC),
            .text(record.timezone),
            .optionalText(record.remindLocal),
            .optionalText(record.remindUTC),
            .optionalText(record.courseHint),
            .optionalText(record.originCaptureId),
            .optionalText(record.originItemId),
            .text(record.externalWriteState.rawValue),
            .optionalText(record.lastReceiptAt),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt),
            .text(record.id)
        ])
        try statement.run()
    }

    func task(id: String) throws -> TaskRecord? {
        let statement = try database.prepare("SELECT \(taskColumns) FROM task WHERE id = ? LIMIT 1;")
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeTask(statement)
    }

    func tasks(status: TaskStatus? = nil, includeDeleted: Bool = false, limit: Int = 500) throws -> [TaskRecord] {
        var sql = "SELECT \(taskColumns) FROM task WHERE 1 = 1"
        var values: [SQLiteValue] = []
        if let status {
            sql += " AND status = ?"
            values.append(.text(status.rawValue))
        }
        if !includeDeleted {
            sql += " AND deleted_at IS NULL"
        }
        sql += " LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [TaskRecord] = []
        while try statement.step() {
            result.append(Self.makeTask(statement))
        }
        return TaskOrdering.sorted(result)
    }

    func openTasks(includeDeleted: Bool = false) throws -> [TaskRecord] {
        try tasks(status: .open, includeDeleted: includeDeleted)
    }

    /// 今天页「同步异常」分区：写入失败、状态未知、需要对账的任务。
    func syncIssueTasks() throws -> [TaskRecord] {
        let statement = try database.prepare(
            """
            SELECT \(taskColumns) FROM task
            WHERE deleted_at IS NULL
              AND external_write_state IN ('failed', 'unknown', 'needs_reconciliation')
            LIMIT 200;
            """
        )
        var result: [TaskRecord] = []
        while try statement.step() {
            result.append(Self.makeTask(statement))
        }
        return TaskOrdering.sorted(result)
    }

    /// 同一条捕获项里的同一个候选只允许创建一个任务，重试解析不应该生成重复任务。
    func taskExists(originCaptureId: String, originItemId: String) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM task WHERE origin_capture_id = ? AND origin_item_id = ? AND deleted_at IS NULL LIMIT 1;"
        )
        try statement.bind([.text(originCaptureId), .text(originItemId)])
        return try statement.step()
    }

    func markTaskDone(id: String) throws {
        let statement = try database.prepare(
            "UPDATE task SET status = 'done', updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(DayCueClock.nowUTCString()), .text(id)])
        try statement.run()
    }

    func reopenTask(id: String) throws {
        let statement = try database.prepare(
            "UPDATE task SET status = 'open', updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(DayCueClock.nowUTCString()), .text(id)])
        try statement.run()
    }

    func softDeleteTask(id: String) throws {
        let now = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            "UPDATE task SET deleted_at = ?, updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(now), .text(now), .text(id)])
        try statement.run()
    }

    /// 通过状态机改写入状态。
    ///
    /// 返回 nil 表示该迁移不合法，任务状态保持不变。调用方要显式处理 nil
    /// （通常是打日志 + 把任务标成 needs_reconciliation），而不是当成成功。
    @discardableResult
    func setTaskExternalWriteState(id: String, to newState: ExternalWriteState) throws -> ExternalWriteState? {
        guard let existing = try task(id: id) else { throw DayCueStoreError.taskNotFound(id) }
        guard let applied = ExternalWriteStateMachine.transition(from: existing.externalWriteState, to: newState) else {
            return nil
        }
        let now = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            "UPDATE task SET external_write_state = ?, last_receipt_at = ?, updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(applied.rawValue), .text(now), .text(now), .text(id)])
        try statement.run()
        return applied
    }

    // MARK: - 外部绑定

    func upsertExternalBinding(_ binding: ExternalBindingRecord) throws {
        var record = binding
        if record.createdAt.isEmpty { record.createdAt = DayCueClock.nowUTCString() }
        let statement = try database.prepare(
            """
            INSERT INTO external_binding
              (task_id, provider, list_id, list_title, external_id, external_last_modified, snapshot_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(task_id, provider) DO UPDATE SET
              list_id = excluded.list_id,
              list_title = excluded.list_title,
              external_id = excluded.external_id,
              external_last_modified = excluded.external_last_modified,
              snapshot_json = excluded.snapshot_json;
            """
        )
        try statement.bind([
            .text(record.taskId),
            .text(record.provider),
            .optionalText(record.listId),
            .optionalText(record.listTitle),
            .optionalText(record.externalId),
            .optionalText(record.externalLastModified),
            .optionalText(record.snapshotJSON),
            .text(record.createdAt)
        ])
        try statement.run()
    }

    func externalBinding(taskId: String, provider: String = "apple_reminders") throws -> ExternalBindingRecord? {
        let statement = try database.prepare(
            """
            SELECT task_id, provider, list_id, list_title, external_id, external_last_modified, snapshot_json, created_at
            FROM external_binding WHERE task_id = ? AND provider = ? LIMIT 1;
            """
        )
        try statement.bind([.text(taskId), .text(provider)])
        guard try statement.step() else { return nil }
        return ExternalBindingRecord(
            taskId: statement.string(0) ?? "",
            provider: statement.string(1) ?? "",
            listId: statement.string(2),
            listTitle: statement.string(3),
            externalId: statement.string(4),
            externalLastModified: statement.string(5),
            snapshotJSON: statement.string(6),
            createdAt: statement.string(7) ?? ""
        )
    }

    func deleteExternalBinding(taskId: String, provider: String = "apple_reminders") throws {
        let statement = try database.prepare("DELETE FROM external_binding WHERE task_id = ? AND provider = ?;")
        try statement.bind([.text(taskId), .text(provider)])
        try statement.run()
    }

    // MARK: - 记忆（第一阶段只读，空表）

    @discardableResult
    func insertMemoryItem(_ item: MemoryRecord) throws -> MemoryRecord {
        var record = item
        if record.createdAt.isEmpty { record.createdAt = DayCueClock.nowUTCString() }
        let statement = try database.prepare(
            """
            INSERT INTO memory_item (id, kind, statement, status, source_capture_id, review_at, created_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.kind),
            .text(record.statement),
            .text(record.status),
            .optionalText(record.sourceCaptureId),
            .optionalText(record.reviewAt),
            .text(record.createdAt),
            .optionalText(record.deletedAt)
        ])
        try statement.run()
        return record
    }

    func memoryItems(includeDeleted: Bool = false) throws -> [MemoryRecord] {
        var sql = "SELECT id, kind, statement, status, source_capture_id, review_at, created_at, deleted_at FROM memory_item"
        if !includeDeleted {
            sql += " WHERE deleted_at IS NULL"
        }
        sql += " ORDER BY created_at DESC;"
        let statement = try database.prepare(sql)
        var result: [MemoryRecord] = []
        while try statement.step() {
            result.append(MemoryRecord(
                id: statement.string(0) ?? "",
                kind: statement.string(1) ?? "",
                statement: statement.string(2) ?? "",
                status: statement.string(3) ?? "",
                sourceCaptureId: statement.string(4),
                reviewAt: statement.string(5),
                createdAt: statement.string(6) ?? "",
                deletedAt: statement.string(7)
            ))
        }
        return result
    }

    // MARK: - 行映射

    static func makeTask(_ statement: SQLiteStatement) -> TaskRecord {
        TaskRecord(
            id: statement.string(0) ?? "",
            title: statement.string(1) ?? "",
            detail: statement.string(2),
            status: TaskStatus(rawValue: statement.string(3) ?? "open") ?? .open,
            dueKind: DueKind(rawValue: statement.string(4) ?? "none") ?? .none,
            dueLocal: statement.string(5),
            dueUTC: statement.string(6),
            timezone: statement.string(7) ?? TimeZone.current.identifier,
            remindLocal: statement.string(8),
            remindUTC: statement.string(9),
            courseHint: statement.string(10),
            originCaptureId: statement.string(11),
            originItemId: statement.string(12),
            externalWriteState: ExternalWriteState(rawValue: statement.string(13) ?? "not_requested") ?? .notRequested,
            lastReceiptAt: statement.string(14),
            createdAt: statement.string(15) ?? "",
            updatedAt: statement.string(16) ?? "",
            deletedAt: statement.string(17)
        )
    }

    /// INSERT 与 UPDATE 的参数顺序不同，所以只给 INSERT 用。
    private static func taskValues(_ record: TaskRecord) -> [SQLiteValue] {
        [
            .text(record.id),
            .text(record.title),
            .optionalText(record.detail),
            .text(record.status.rawValue),
            .text(record.dueKind.rawValue),
            .optionalText(record.dueLocal),
            .optionalText(record.dueUTC),
            .text(record.timezone),
            .optionalText(record.remindLocal),
            .optionalText(record.remindUTC),
            .optionalText(record.courseHint),
            .optionalText(record.originCaptureId),
            .optionalText(record.originItemId),
            .text(record.externalWriteState.rawValue),
            .optionalText(record.lastReceiptAt),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt)
        ]
    }
}

let taskColumns = "id, title, detail, status, due_kind, due_local, due_utc, timezone, remind_local, remind_utc, course_hint, origin_capture_id, origin_item_id, external_write_state, last_receipt_at, created_at, updated_at, deleted_at"

// MARK: - 启动恢复

public extension DayCueStore {

    /// 进程被杀在「外部已写入、本地回执未落库」的中间态时，任务会停在 `pending`。
    /// 这里把它们找出来交给上层重试；**重试是否安全由幂等键与写入前查重保证**，
    /// 而不是靠这里不重试。
    func pendingExternalWriteTasks(limit: Int = 50) throws -> [TaskRecord] {
        try tasksInExternalState(.pending, limit: limit)
    }

    /// 状态未知（save 抛错但无法确认系统是否落盘）的任务。
    ///
    /// 这类任务**绝不能**被当成失败重写，也绝不能显示成已写入，
    /// 只能交给对账流程按稳定标识回查。
    func unknownExternalWriteTasks(limit: Int = 50) throws -> [TaskRecord] {
        try tasksInExternalState(.unknown, limit: limit)
    }

    private func tasksInExternalState(_ state: ExternalWriteState, limit: Int) throws -> [TaskRecord] {
        let statement = try database.prepare(
            """
            SELECT \(taskColumns) FROM task
            WHERE deleted_at IS NULL AND status = 'open' AND external_write_state = ?
            ORDER BY created_at ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(state.rawValue), .integer(Int64(limit))])
        var result: [TaskRecord] = []
        while try statement.step() {
            result.append(Self.makeTask(statement))
        }
        return result
    }

    /// 把「状态未知」显式降级为「需要对账」，让今天页的同步异常分区能显示出来。
    ///
    /// 不直接改写成 failed：那等于替用户断言"没写成功"，而事实是我们不知道。
    /// 返回实际被标记的任务数，便于启动日志与测试断言。
    @discardableResult
    func markUnknownWritesForReconciliation() throws -> Int {
        let candidates = try unknownExternalWriteTasks(limit: 500)
        var marked = 0
        for task in candidates {
            if try setTaskExternalWriteState(id: task.id, to: .needsReconciliation) != nil {
                marked += 1
            }
        }
        return marked
    }
}
