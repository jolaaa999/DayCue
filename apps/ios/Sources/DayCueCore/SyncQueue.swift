import Foundation

// 云同步的「待推送队列」（sync_change）与「待裁决冲突」（sync_conflict）落库层。
//
// 为什么新增 sync_change 而不是复用 outbox_operation：
//   outbox_operation 是「写入苹果提醒事项」的状态机（create_reminder / delete_reminder，
//   UNIQUE(idempotency_key)），与云同步「同一实体多次修改合并成一条、还要带服务端
//   base_version」的语义不同。混用会让提醒事项的重试把云同步的条目一起带走。
//
// 复用的既有同步语义（都在 DayCueStore+Sync.swift）：
//   - 删除墓碑：sync_tombstone 表与 SyncTombstoneRecord（用户点名要求复用）；
//   - 拉取游标：sync_cursor 表与 setSyncCursor / syncCursor。
// 服务端的 sync_record 是 Go 侧的表（services/api/internal/store/postgres.go），
// 客户端本来就没有对应表；sync_change 只承担「本地变更待推送」，不另造墓碑与游标。
//
// sync_change 同时充当「最后一次成功同步的基线」：
//   state = synced 且 content_hash 与本地一致时，采集器就不会重复入队；
//   它同时保存 base_version，下一次修改推给服务端时用得上。
// 因此队列条目在同步成功后**不删除**——删掉的话，下一轮采集会把「已同步的内容」
// 当成新变更再推一次，形成无限回推。

/// 参与云同步的实体类型。rawValue 必须与服务端 store.EntityType 完全一致，
/// 改了这里就等于改协议。
public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case task
    case note
    case capture
    case course
    case memory

    public var displayName: String {
        switch self {
        case .task: return "任务"
        case .note: return "笔记"
        case .capture: return "记录"
        case .course: return "课程"
        case .memory: return "记忆"
        }
    }

    /// 实体在本地的表名。采集器直接按表名读，避免再写一层按类型分发的仓储。
    public var tableName: String {
        switch self {
        case .task: return "task"
        case .note: return "note"
        case .capture: return "capture_item"
        case .course: return "course"
        case .memory: return "memory_item"
        }
    }

    /// 这张表是否用 deleted_at 做软删除。capture 是硬删除，删除只能从行消失来推断。
    public var usesSoftDelete: Bool {
        self != .capture
    }
}

/// 一条待推送变更的操作类型。删除只推墓碑，不推内容。
public enum SyncChangeOperation: String, Codable, Sendable {
    case upsert
    case delete
}

/// 队列条目的状态。
///
/// 刻意没有 in_flight：推送是「一次请求 + 逐条结算」，只有拿到响应才会改状态，
/// 进程被杀在中间时条目仍然是 pending，下一轮照常重推，不会卡死。
public enum SyncChangeState: String, Codable, Sendable {
    /// 待推送。next_retry_at 未到之前不推（退避）。
    case pending
    /// 已成功同步。保留作为基线，不再重复推送。
    case synced
    /// 服务端版本冲突，等用户逐字段裁决。绝不自动选边。
    case conflict
    /// 服务端明确拒绝（请求本身不合法）。重复推送没有意义，等用户处理后才会重排。
    case blocked
}

/// sync_change 的一行。
public struct SyncChangeRecord: Equatable, Sendable {
    public var entityType: SyncEntityType
    public var entityId: String
    public var operation: SyncChangeOperation
    /// 推送时的实体内容。删除为 nil。
    public var payloadJSON: String?
    /// 内容指纹。与本地当前内容一致且 state = synced 时说明无需再推。
    public var contentHash: String
    /// 本地变更所基于的服务端版本；0 表示「我认为这是新增」。
    public var baseVersion: Int64
    public var state: SyncChangeState
    public var attempt: Int
    public var nextRetryAt: String?
    public var lastError: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        entityType: SyncEntityType,
        entityId: String,
        operation: SyncChangeOperation,
        payloadJSON: String?,
        contentHash: String,
        baseVersion: Int64 = 0,
        state: SyncChangeState = .pending,
        attempt: Int = 0,
        nextRetryAt: String? = nil,
        lastError: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.operation = operation
        self.payloadJSON = payloadJSON
        self.contentHash = contentHash
        self.baseVersion = baseVersion
        self.state = state
        self.attempt = attempt
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 稳定标识，仅用于界面分组与日志。与 ReconciliationView 的行 id 同构。
    public var id: String { entityType.rawValue + "|" + entityId }

    /// 已经处理完、不需要再推的状态。blocked 需要用户先处理。
    public var isSettled: Bool { state == .synced }
}

/// sync_conflict 的一行：一条需要用户逐字段裁决的冲突。
public struct SyncConflictRecord: Equatable, Sendable {
    public var entityType: SyncEntityType
    public var entityId: String
    /// 冲突时服务端的版本号。
    public var serverVersion: Int64
    /// 本地变更所基于的版本号。
    public var baseVersion: Int64
    /// 服务端这条已经是墓碑（被删除）。
    public var serverDeleted: Bool
    public var serverPayloadJSON: String?
    /// 工作副本：初始是本地内容，用户每裁决一个字段就覆写这一份。
    /// 这样做是为了让「逐字段提交」能累积，而不是每提交一个字段就丢掉上一个。
    public var localPayloadJSON: String?
    /// 冲突发生时判定为「双方都改过」的字段。
    public var conflictingFields: [ReconciliationField]
    /// 用户已经裁决过的字段。
    public var resolvedFields: [ReconciliationField]
    /// 用户是否至少有一次选了本地。服务端墓碑 + 全部选服务端 = 同意删除本地。
    public var choseLocal: Bool
    public var detectedAt: String

    public init(
        entityType: SyncEntityType,
        entityId: String,
        serverVersion: Int64,
        baseVersion: Int64,
        serverDeleted: Bool,
        serverPayloadJSON: String?,
        localPayloadJSON: String?,
        conflictingFields: [ReconciliationField],
        resolvedFields: [ReconciliationField] = [],
        choseLocal: Bool = false,
        detectedAt: String
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.serverVersion = serverVersion
        self.baseVersion = baseVersion
        self.serverDeleted = serverDeleted
        self.serverPayloadJSON = serverPayloadJSON
        self.localPayloadJSON = localPayloadJSON
        self.conflictingFields = conflictingFields
        self.resolvedFields = resolvedFields
        self.choseLocal = choseLocal
        self.detectedAt = detectedAt
    }

    public var id: String { entityType.rawValue + "|" + entityId }

    /// 所有冲突字段都裁决过了。只有这时才允许落到本地。
    public var isFullyResolved: Bool {
        Set(conflictingFields).isSubset(of: Set(resolvedFields))
    }
}

/// 队列与冲突表的建表脚本。
///
/// 刻意不塞进 Schema.swift 的迁移链：那个文件归主会话维护，而这两张表是云同步
/// 独有的。用 CREATE TABLE IF NOT EXISTS，可以在任意时刻重复调用。
public enum CloudSyncSchema {

    public static func install(_ database: SQLiteDatabase) throws {
        try database.execute(script)
    }

    static let script = """
    -- 待推送队列 + 最近一次成功同步的基线。
    CREATE TABLE IF NOT EXISTS sync_change (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      op TEXT NOT NULL CHECK (op IN ('upsert','delete')),
      payload_json TEXT,
      content_hash TEXT NOT NULL DEFAULT '',
      base_version INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL CHECK (state IN ('pending','synced','conflict','blocked')),
      attempt INTEGER NOT NULL DEFAULT 0,
      next_retry_at TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (entity_type, entity_id)
    );
    CREATE INDEX IF NOT EXISTS idx_sync_change_state ON sync_change(state, next_retry_at);

    -- 待用户裁决的冲突。
    CREATE TABLE IF NOT EXISTS sync_conflict (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      server_version INTEGER NOT NULL DEFAULT 0,
      base_version INTEGER NOT NULL DEFAULT 0,
      server_deleted INTEGER NOT NULL DEFAULT 0,
      server_payload_json TEXT,
      local_payload_json TEXT,
      conflicting_fields TEXT NOT NULL DEFAULT '',
      resolved_fields TEXT NOT NULL DEFAULT '',
      chose_local INTEGER NOT NULL DEFAULT 0,
      detected_at TEXT NOT NULL,
      PRIMARY KEY (entity_type, entity_id)
    );
    """
}

public extension DayCueStore {

    /// 确保云同步的两张表存在。所有队列读写都先调它，避免依赖调用顺序。
    func installCloudSyncSchema() throws {
        try CloudSyncSchema.install(database)
    }

    // MARK: - 入队（幂等 + 合并）

    /// 把一条本地变更记入队列。
    ///
    /// 合并规则：同一个 (entity_type, entity_id) 只有一行，后写的覆盖先写的，
    /// 所以「同一实体改十次」最终只会推一次最新内容。
    ///
    /// 幂等规则：内容指纹与上次一致且已经同步过时直接返回旧记录，不产生新条目。
    /// 冲突未裁决的条目一律不覆盖 —— 用户还没裁决，覆盖等于把服务端那版弄丢。
    ///
    /// - Returns: changed 为 true 表示队列真的被新建或改写了。
    @discardableResult
    func enqueueSyncChange(
        entityType: SyncEntityType,
        entityId: String,
        operation: SyncChangeOperation,
        payloadJSON: String?,
        baseVersion: Int64,
        at: Date
    ) throws -> (record: SyncChangeRecord, changed: Bool) {
        try installCloudSyncSchema()
        let now = DayCueClock.nowUTCString(date: at)
        let hash = SyncPayloadCodec.changeHash(operation: operation, payloadJSON: payloadJSON)

        if let existing = try syncChange(entityType: entityType, entityId: entityId) {
            // 内容与操作都没变：无论当前是什么状态都不重写。
            // 这一条同时保证三件事：幂等、退避排期不被下一轮采集重置、
            // 被服务端拒绝的条目不会因为重复采集而反复重排。
            if existing.operation == operation, existing.contentHash == hash {
                return (existing, false)
            }
            // 内容确实变了，但冲突还没裁决：绝不覆盖，否则会把服务端那版弄丢。
            if existing.state == .conflict { return (existing, false) }

            let statement = try database.prepare(
                """
                UPDATE sync_change
                SET op = ?, payload_json = ?, content_hash = ?, base_version = ?,
                    state = 'pending', attempt = 0, next_retry_at = NULL, last_error = NULL, updated_at = ?
                WHERE entity_type = ? AND entity_id = ?;
                """
            )
            try statement.bind([
                .text(operation.rawValue),
                .optionalText(payloadJSON),
                .text(hash),
                .integer(baseVersion),
                .text(now),
                .text(entityType.rawValue),
                .text(entityId)
            ])
            try statement.run()
            let updated = SyncChangeRecord(
                entityType: entityType,
                entityId: entityId,
                operation: operation,
                payloadJSON: payloadJSON,
                contentHash: hash,
                baseVersion: baseVersion,
                state: .pending,
                attempt: 0,
                nextRetryAt: nil,
                lastError: nil,
                createdAt: existing.createdAt,
                updatedAt: now
            )
            return (updated, true)
        }

        let record = SyncChangeRecord(
            entityType: entityType,
            entityId: entityId,
            operation: operation,
            payloadJSON: payloadJSON,
            contentHash: hash,
            baseVersion: baseVersion,
            state: .pending,
            attempt: 0,
            nextRetryAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            try insertSyncChange(record)
            return (record, true)
        } catch let error as SQLiteError where error.isUniqueConstraintViolation {
            // 并发下另一个执行者先插入了同一实体；读回即可，不算错误。
            if let existing = try syncChange(entityType: entityType, entityId: entityId) {
                return (existing, false)
            }
            throw error
        }
    }

    // MARK: - 队列读取

    func syncChange(entityType: SyncEntityType, entityId: String) throws -> SyncChangeRecord? {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            "SELECT \(syncChangeColumns) FROM sync_change WHERE entity_type = ? AND entity_id = ? LIMIT 1;"
        )
        try statement.bind([.text(entityType.rawValue), .text(entityId)])
        guard try statement.step() else { return nil }
        return Self.makeSyncChange(statement)
    }

    func syncChanges(entityType: SyncEntityType) throws -> [SyncChangeRecord] {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            "SELECT \(syncChangeColumns) FROM sync_change WHERE entity_type = ? ORDER BY entity_id ASC;"
        )
        try statement.bind([.text(entityType.rawValue)])
        return try Self.collectSyncChanges(statement)
    }

    func syncChanges(state: SyncChangeState, limit: Int = 500) throws -> [SyncChangeRecord] {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            "SELECT \(syncChangeColumns) FROM sync_change WHERE state = ? ORDER BY updated_at ASC LIMIT ?;"
        )
        try statement.bind([.text(state.rawValue), .integer(Int64(limit))])
        return try Self.collectSyncChanges(statement)
    }

    /// 到了重试时刻的待推送条目。退避用 next_retry_at 表达，绝不紧密重试。
    func dueSyncChanges(now: Date, limit: Int = 200) throws -> [SyncChangeRecord] {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            """
            SELECT \(syncChangeColumns) FROM sync_change
            WHERE state = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= ?)
            ORDER BY updated_at ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(DayCueClock.nowUTCString(date: now)), .integer(Int64(limit))])
        return try Self.collectSyncChanges(statement)
    }

    func syncChangeCount(state: SyncChangeState) throws -> Int {
        try installCloudSyncSchema()
        let statement = try database.prepare("SELECT COUNT(*) FROM sync_change WHERE state = ?;")
        try statement.bind([.text(state.rawValue)])
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    // MARK: - 队列状态迁移

    /// 推送成功：记为已同步，并保存服务端版本作为下一次的 base_version。
    func markSyncChangeSynced(
        entityType: SyncEntityType,
        entityId: String,
        serverVersion: Int64,
        contentHash: String,
        at: Date
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE sync_change
            SET state = 'synced', base_version = ?, content_hash = ?, attempt = 0,
                next_retry_at = NULL, last_error = NULL, updated_at = ?
            WHERE entity_type = ? AND entity_id = ?;
            """
        )
        try statement.bind([
            .integer(serverVersion),
            .text(contentHash),
            .text(DayCueClock.nowUTCString(date: at)),
            .text(entityType.rawValue),
            .text(entityId)
        ])
        try statement.run()
    }

    /// 网络类失败：保留 pending，写退避时刻。重试不会丢内容。
    func scheduleSyncChangeRetry(
        entityType: SyncEntityType,
        entityId: String,
        attempt: Int,
        nextRetryAt: String,
        error: String?
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE sync_change
            SET state = 'pending', attempt = ?, next_retry_at = ?, last_error = ?, updated_at = ?
            WHERE entity_type = ? AND entity_id = ?;
            """
        )
        try statement.bind([
            .integer(Int64(attempt)),
            .text(nextRetryAt),
            .optionalText(error),
            .text(DayCueClock.nowUTCString()),
            .text(entityType.rawValue),
            .text(entityId)
        ])
        try statement.run()
    }

    /// 服务端拒绝：不再自动重试，等用户在冲突页处理。
    func markSyncChangeBlocked(
        entityType: SyncEntityType,
        entityId: String,
        reason: String?
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE sync_change
            SET state = 'blocked', next_retry_at = NULL, last_error = ?, updated_at = ?
            WHERE entity_type = ? AND entity_id = ?;
            """
        )
        try statement.bind([
            .optionalText(reason),
            .text(DayCueClock.nowUTCString()),
            .text(entityType.rawValue),
            .text(entityId)
        ])
        try statement.run()
    }

    /// 把冲突条目重新排回待推送（用户裁决完之后调用）。
    ///
    /// 必须先把状态从 conflict 挪走再调 enqueueSyncChange：后者对冲突条目
    /// 刻意不做覆盖，否则会把服务端那版内容弄丢。
    func requeueSyncChange(entityType: SyncEntityType, entityId: String, at: Date) throws {
        let statement = try database.prepare(
            """
            UPDATE sync_change
            SET state = 'pending', attempt = 0, next_retry_at = NULL, last_error = NULL, updated_at = ?
            WHERE entity_type = ? AND entity_id = ?;
            """
        )
        try statement.bind([
            .text(DayCueClock.nowUTCString(date: at)),
            .text(entityType.rawValue),
            .text(entityId)
        ])
        try statement.run()
    }

    /// 删除队列条目。只在「整账号数据被清空」这类场景使用。
    func deleteSyncChange(entityType: SyncEntityType, entityId: String) throws {
        let statement = try database.prepare(
            "DELETE FROM sync_change WHERE entity_type = ? AND entity_id = ?;"
        )
        try statement.bind([.text(entityType.rawValue), .text(entityId)])
        try statement.run()
    }

    // MARK: - 冲突

    /// 写入（或覆盖）一条待裁决冲突，并把队列条目标成 conflict。
    func upsertSyncConflict(_ record: SyncConflictRecord) throws {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            """
            INSERT INTO sync_conflict
              (entity_type, entity_id, server_version, base_version, server_deleted,
               server_payload_json, local_payload_json, conflicting_fields, resolved_fields,
               chose_local, detected_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
              server_version = excluded.server_version,
              base_version = excluded.base_version,
              server_deleted = excluded.server_deleted,
              server_payload_json = excluded.server_payload_json,
              local_payload_json = excluded.local_payload_json,
              conflicting_fields = excluded.conflicting_fields,
              resolved_fields = excluded.resolved_fields,
              chose_local = excluded.chose_local,
              detected_at = excluded.detected_at;
            """
        )
        try statement.bind([
            .text(record.entityType.rawValue),
            .text(record.entityId),
            .integer(record.serverVersion),
            .integer(record.baseVersion),
            .bool(record.serverDeleted),
            .optionalText(record.serverPayloadJSON),
            .optionalText(record.localPayloadJSON),
            .text(Self.encodeReconciliationFields(record.conflictingFields)),
            .text(Self.encodeReconciliationFields(record.resolvedFields)),
            .bool(record.choseLocal),
            .text(record.detectedAt)
        ])
        try statement.run()

        let queue = try database.prepare(
            "UPDATE sync_change SET state = 'conflict', next_retry_at = NULL, updated_at = ? WHERE entity_type = ? AND entity_id = ?;"
        )
        try queue.bind([
            .text(record.detectedAt),
            .text(record.entityType.rawValue),
            .text(record.entityId)
        ])
        try queue.run()
    }

    func syncConflict(entityType: SyncEntityType, entityId: String) throws -> SyncConflictRecord? {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            "SELECT \(syncConflictColumns) FROM sync_conflict WHERE entity_type = ? AND entity_id = ? LIMIT 1;"
        )
        try statement.bind([.text(entityType.rawValue), .text(entityId)])
        guard try statement.step() else { return nil }
        return Self.makeSyncConflict(statement)
    }

    func syncConflicts() throws -> [SyncConflictRecord] {
        try installCloudSyncSchema()
        let statement = try database.prepare(
            "SELECT \(syncConflictColumns) FROM sync_conflict ORDER BY detected_at ASC, entity_id ASC;"
        )
        var result: [SyncConflictRecord] = []
        while try statement.step() {
            result.append(Self.makeSyncConflict(statement))
        }
        return result
    }

    func syncConflictCount() throws -> Int {
        try installCloudSyncSchema()
        let statement = try database.prepare("SELECT COUNT(*) FROM sync_conflict;")
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    func deleteSyncConflict(entityType: SyncEntityType, entityId: String) throws {
        let statement = try database.prepare(
            "DELETE FROM sync_conflict WHERE entity_type = ? AND entity_id = ?;"
        )
        try statement.bind([.text(entityType.rawValue), .text(entityId)])
        try statement.run()
    }

    /// 清空云同步的本地状态（队列 + 冲突）。切换账号或清空数据时用。
    func clearCloudSyncState() throws {
        try database.execute("DELETE FROM sync_change;")
        try database.execute("DELETE FROM sync_conflict;")
    }

    // MARK: - 行映射

    @discardableResult
    func insertSyncChange(_ record: SyncChangeRecord) throws -> SyncChangeRecord {
        let statement = try database.prepare(
            """
            INSERT INTO sync_change
              (entity_type, entity_id, op, payload_json, content_hash, base_version,
               state, attempt, next_retry_at, last_error, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.entityType.rawValue),
            .text(record.entityId),
            .text(record.operation.rawValue),
            .optionalText(record.payloadJSON),
            .text(record.contentHash),
            .integer(record.baseVersion),
            .text(record.state.rawValue),
            .integer(Int64(record.attempt)),
            .optionalText(record.nextRetryAt),
            .optionalText(record.lastError),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()
        return record
    }

    static func collectSyncChanges(_ statement: SQLiteStatement) throws -> [SyncChangeRecord] {
        var result: [SyncChangeRecord] = []
        while try statement.step() {
            result.append(Self.makeSyncChange(statement))
        }
        return result
    }

    static func makeSyncChange(_ statement: SQLiteStatement) -> SyncChangeRecord {
        SyncChangeRecord(
            entityType: SyncEntityType(rawValue: statement.string(0) ?? "") ?? .task,
            entityId: statement.string(1) ?? "",
            operation: SyncChangeOperation(rawValue: statement.string(2) ?? "upsert") ?? .upsert,
            payloadJSON: statement.string(3),
            contentHash: statement.string(4) ?? "",
            baseVersion: statement.int64(5),
            state: SyncChangeState(rawValue: statement.string(6) ?? "pending") ?? .pending,
            attempt: statement.int(7),
            nextRetryAt: statement.string(8),
            lastError: statement.string(9),
            createdAt: statement.string(10) ?? "",
            updatedAt: statement.string(11) ?? ""
        )
    }

    static func makeSyncConflict(_ statement: SQLiteStatement) -> SyncConflictRecord {
        SyncConflictRecord(
            entityType: SyncEntityType(rawValue: statement.string(0) ?? "") ?? .task,
            entityId: statement.string(1) ?? "",
            serverVersion: statement.int64(2),
            baseVersion: statement.int64(3),
            serverDeleted: statement.bool(4),
            serverPayloadJSON: statement.string(5),
            localPayloadJSON: statement.string(6),
            conflictingFields: decodeReconciliationFields(statement.string(7)),
            resolvedFields: decodeReconciliationFields(statement.string(8)),
            choseLocal: statement.bool(9),
            detectedAt: statement.string(10) ?? ""
        )
    }

    /// 字段列表用逗号分隔存库。ReconciliationField 是有限枚举，不会出现分隔符。
    static func encodeReconciliationFields(_ fields: [ReconciliationField]) -> String {
        fields.map(\.rawValue).joined(separator: ",")
    }

    static func decodeReconciliationFields(_ raw: String?) -> [ReconciliationField] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { ReconciliationField(rawValue: String($0)) }
    }
}

let syncChangeColumns = "entity_type, entity_id, op, payload_json, content_hash, base_version, state, attempt, next_retry_at, last_error, created_at, updated_at"
let syncConflictColumns = "entity_type, entity_id, server_version, base_version, server_deleted, server_payload_json, local_payload_json, conflicting_fields, resolved_fields, chose_local, detected_at"
