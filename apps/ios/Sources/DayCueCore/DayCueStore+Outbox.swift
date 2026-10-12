import Foundation

public extension DayCueStore {

    // MARK: - Outbox

    /// 直接插入。同一个 idempotency_key 已存在时抛 SQLiteError.uniqueConstraintViolation。
    /// 之所以保留这个「会失败」的原始入口，是因为唯一索引才是幂等的最终保证，
    /// 调用方（enqueueOutboxOperation）负责把冲突翻译成「已经排队了」。
    @discardableResult
    func insertOutboxOperation(_ operation: OutboxOperationRecord) throws -> OutboxOperationRecord {
        var record = operation
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        record.updatedAt = now

        let statement = try database.prepare(
            """
            INSERT INTO outbox_operation
              (id, entity_type, entity_id, op, idempotency_key, payload_json, attempt, state, next_retry_at, last_error, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.entityType.rawValue),
            .text(record.entityId),
            .text(record.op.rawValue),
            .text(record.idempotencyKey),
            .optionalText(record.payloadJSON),
            .integer(Int64(record.attempt)),
            .text(record.state.rawValue),
            .optionalText(record.nextRetryAt),
            .optionalText(record.lastError),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()
        return record
    }

    func outboxOperation(idempotencyKey: String) throws -> OutboxOperationRecord? {
        let statement = try database.prepare(
            "SELECT \(outboxColumns) FROM outbox_operation WHERE idempotency_key = ? LIMIT 1;"
        )
        try statement.bind([.text(idempotencyKey)])
        guard try statement.step() else { return nil }
        return Self.makeOutbox(statement)
    }

    func outboxOperation(id: String) throws -> OutboxOperationRecord? {
        let statement = try database.prepare(
            "SELECT \(outboxColumns) FROM outbox_operation WHERE id = ? LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeOutbox(statement)
    }

    /// 幂等入队。已存在同 key 的操作时直接返回旧记录，不新建。
    /// 这是「重复点按不会创建第二条外部提醒」的第一道闸门。
    @discardableResult
    func enqueueOutboxOperation(
        entityType: OutboxEntityType,
        entityId: String,
        op: OutboxOperationKind,
        idempotencyKey: String,
        payloadJSON: String? = nil
    ) throws -> (record: OutboxOperationRecord, created: Bool) {
        if let existing = try outboxOperation(idempotencyKey: idempotencyKey) {
            return (existing, false)
        }
        let record = OutboxOperationRecord(
            entityType: entityType,
            entityId: entityId,
            op: op,
            idempotencyKey: idempotencyKey,
            payloadJSON: payloadJSON,
            createdAt: DayCueClock.nowUTCString(),
            updatedAt: DayCueClock.nowUTCString()
        )
        do {
            let inserted = try insertOutboxOperation(record)
            return (inserted, true)
        } catch let error as SQLiteError where error.isUniqueConstraintViolation {
            // 并发下另一个执行者先插入了同一个 key；读回已有的那一条即可，不算错误。
            if let existing = try outboxOperation(idempotencyKey: idempotencyKey) {
                return (existing, false)
            }
            throw error
        }
    }

    func outboxOperations(state: OutboxState? = nil, limit: Int = 100) throws -> [OutboxOperationRecord] {
        var sql = "SELECT \(outboxColumns) FROM outbox_operation"
        var values: [SQLiteValue] = []
        if let state {
            sql += " WHERE state = ?"
            values.append(.text(state.rawValue))
        }
        sql += " ORDER BY created_at ASC LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [OutboxOperationRecord] = []
        while try statement.step() {
            result.append(Self.makeOutbox(statement))
        }
        return result
    }

    /// 可以立刻执行的操作：pending，或到了 next_retry_at 的 failed。
    /// running 状态的记录故意不在里面——它可能是「进程被杀在写入中途」，必须走对账而不是重试。
    func runnableOutboxOperations(now: Date = Date(), limit: Int = 50) throws -> [OutboxOperationRecord] {
        let statement = try database.prepare(
            """
            SELECT \(outboxColumns) FROM outbox_operation
            WHERE state = 'pending'
               OR (state = 'failed' AND (next_retry_at IS NULL OR next_retry_at <= ?))
            ORDER BY created_at ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(DayCueClock.nowUTCString(date: now)), .integer(Int64(limit))])
        var result: [OutboxOperationRecord] = []
        while try statement.step() {
            result.append(Self.makeOutbox(statement))
        }
        return result
    }

    func updateOutboxOperation(
        id: String,
        state: OutboxState,
        attempt: Int? = nil,
        lastError: String? = nil,
        nextRetryAt: String? = nil
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE outbox_operation
            SET state = ?, attempt = COALESCE(?, attempt), last_error = ?, next_retry_at = ?, updated_at = ?
            WHERE id = ?;
            """
        )
        try statement.bind([
            .text(state.rawValue),
            attempt.map { SQLiteValue.integer(Int64($0)) } ?? .null,
            .optionalText(lastError),
            .optionalText(nextRetryAt),
            .text(DayCueClock.nowUTCString()),
            .text(id)
        ])
        try statement.run()
    }

    func countOutboxOperations(state: OutboxState) throws -> Int {
        let statement = try database.prepare("SELECT COUNT(*) FROM outbox_operation WHERE state = ?;")
        try statement.bind([.text(state.rawValue)])
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// 运维用：把 running 状态（进程中断残留）重新排队。只由对账流程调用。
    func requeueStaleOutboxOperations() throws {
        let statement = try database.prepare(
            "UPDATE outbox_operation SET state = 'pending', updated_at = ? WHERE state = 'running';"
        )
        try statement.bind([.text(DayCueClock.nowUTCString())])
        try statement.run()
    }

    static func makeOutbox(_ statement: SQLiteStatement) -> OutboxOperationRecord {
        OutboxOperationRecord(
            id: statement.string(0) ?? "",
            entityType: OutboxEntityType(rawValue: statement.string(1) ?? "task") ?? .task,
            entityId: statement.string(2) ?? "",
            op: OutboxOperationKind(rawValue: statement.string(3) ?? "create_reminder") ?? .createReminder,
            idempotencyKey: statement.string(4) ?? "",
            payloadJSON: statement.string(5),
            attempt: statement.int(6),
            state: OutboxState(rawValue: statement.string(7) ?? "pending") ?? .pending,
            nextRetryAt: statement.string(8),
            lastError: statement.string(9),
            createdAt: statement.string(10) ?? "",
            updatedAt: statement.string(11) ?? ""
        )
    }
}

let outboxColumns = "id, entity_type, entity_id, op, idempotency_key, payload_json, attempt, state, next_retry_at, last_error, created_at, updated_at"
