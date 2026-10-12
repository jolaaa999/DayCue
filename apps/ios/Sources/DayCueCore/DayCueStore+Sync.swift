import Foundation

// 同步快照 / 游标 / 墓碑的仓储。
//
// 这三张表在 v2 schema 里已经建好，这里补上唯一的读写入口。
// 记录模型没有放进 DomainModels.swift（那个文件已冻结），放在本文件是为了让
// 「表结构」和「读写代码」在同一屏里，改列名时不至于漏掉一处。

// MARK: - 记录模型

/// sync_snapshot 的一行：某个实体在某个外部系统里的上次已知状态。
public struct SyncSnapshotRecord: Equatable, Sendable {
    public var entityType: String
    public var entityId: String
    public var provider: String
    public var payloadJSON: String
    public var contentHash: String
    public var capturedAt: String

    public init(
        entityType: String,
        entityId: String,
        provider: String,
        payloadJSON: String,
        contentHash: String,
        capturedAt: String
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.provider = provider
        self.payloadJSON = payloadJSON
        self.contentHash = contentHash
        self.capturedAt = capturedAt
    }
}

/// sync_cursor 的一行：增量拉取的游标。scope 由调用方约定（例如 "apple_reminders.incremental"）。
public struct SyncCursorRecord: Equatable, Sendable {
    public var scope: String
    public var cursor: String
    public var updatedAt: String

    public init(scope: String, cursor: String, updatedAt: String) {
        self.scope = scope
        self.cursor = cursor
        self.updatedAt = updatedAt
    }
}

/// sync_tombstone 的一行：删除传播用的墓碑。
public struct SyncTombstoneRecord: Equatable, Sendable {
    public var entityType: String
    public var entityId: String
    public var deletedAt: String
    public var remoteVersion: Int?

    public init(entityType: String, entityId: String, deletedAt: String, remoteVersion: Int? = nil) {
        self.entityType = entityType
        self.entityId = entityId
        self.deletedAt = deletedAt
        self.remoteVersion = remoteVersion
    }
}

public extension DayCueStore {

    // MARK: - 同步快照

    /// 无条件写整行。PUT 语义，同一个 (entity_type, entity_id, provider) 直接覆盖。
    func upsertSyncSnapshot(_ record: SyncSnapshotRecord) throws {
        let statement = try database.prepare(
            """
            INSERT INTO sync_snapshot (entity_type, entity_id, provider, payload_json, content_hash, captured_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id, provider) DO UPDATE SET
              payload_json = excluded.payload_json,
              content_hash = excluded.content_hash,
              captured_at = excluded.captured_at;
            """
        )
        try statement.bind([
            .text(record.entityType),
            .text(record.entityId),
            .text(record.provider),
            .text(record.payloadJSON),
            .text(record.contentHash),
            .text(record.capturedAt)
        ])
        try statement.run()
    }

    func syncSnapshot(entityType: String, entityId: String, provider: String) throws -> SyncSnapshotRecord? {
        let statement = try database.prepare(
            "SELECT \(syncSnapshotColumns) FROM sync_snapshot WHERE entity_type = ? AND entity_id = ? AND provider = ? LIMIT 1;"
        )
        try statement.bind([.text(entityType), .text(entityId), .text(provider)])
        guard try statement.step() else { return nil }
        return Self.makeSyncSnapshot(statement)
    }

    func syncSnapshots(entityType: String, provider: String) throws -> [SyncSnapshotRecord] {
        let statement = try database.prepare(
            "SELECT \(syncSnapshotColumns) FROM sync_snapshot WHERE entity_type = ? AND provider = ? ORDER BY entity_id ASC;"
        )
        try statement.bind([.text(entityType), .text(provider)])
        var result: [SyncSnapshotRecord] = []
        while try statement.step() {
            result.append(Self.makeSyncSnapshot(statement))
        }
        return result
    }

    func deleteSyncSnapshot(entityType: String, entityId: String, provider: String) throws {
        let statement = try database.prepare(
            "DELETE FROM sync_snapshot WHERE entity_type = ? AND entity_id = ? AND provider = ?;"
        )
        try statement.bind([.text(entityType), .text(entityId), .text(provider)])
        try statement.run()
    }

    /// 内容哈希没变就不需要重写。返回 true 表示「应该跳过这次写入」。
    ///
    /// provider 给了默认值，这样最常见的三参数调用不必每次都传。
    func shouldSkipWrite(
        entityType: String,
        entityId: String,
        payloadHash: String,
        provider: String = ReconciliationEngine.defaultProvider
    ) throws -> Bool {
        guard let existing = try syncSnapshot(entityType: entityType, entityId: entityId, provider: provider) else {
            return false
        }
        return existing.contentHash == payloadHash
    }

    /// 快照写入的唯一入口：自己算 content_hash，内容没变就整条跳过。
    ///
    /// 返回值表示「确实写了」(true) 还是「内容没变而跳过」(false)。
    /// 返回值有意义而不是 Void：跳过时不能刷新 captured_at，
    /// 否则「上次对账时间」会被一次空转的对账不断推后，看不出真实变化。
    @discardableResult
    func writeSyncSnapshot(
        entityType: String,
        entityId: String,
        provider: String,
        payloadJSON: String,
        capturedAt: String = DayCueClock.nowUTCString()
    ) throws -> Bool {
        let hash = SHA256Hex.digest(payloadJSON)
        if try shouldSkipWrite(entityType: entityType, entityId: entityId, payloadHash: hash, provider: provider) {
            return false
        }
        try upsertSyncSnapshot(SyncSnapshotRecord(
            entityType: entityType,
            entityId: entityId,
            provider: provider,
            payloadJSON: payloadJSON,
            contentHash: hash,
            capturedAt: capturedAt
        ))
        return true
    }

    /// 把一条任务的可比状态写成对账基线。
    @discardableResult
    func writeReconciliationBaseline(
        _ state: ReminderComparableState,
        entityId: String,
        provider: String = ReconciliationEngine.defaultProvider,
        capturedAt: String = DayCueClock.nowUTCString()
    ) throws -> Bool {
        let payload = try DayCueJSON.encodeToString(state)
        return try writeSyncSnapshot(
            entityType: ReconciliationEngine.defaultEntityType,
            entityId: entityId,
            provider: provider,
            payloadJSON: payload,
            capturedAt: capturedAt
        )
    }

    /// 读回三方比较要用的基线。
    ///
    /// payload 解析不了的快照直接跳过：一条坏快照不该让整轮对账崩掉；
    /// 而「没有基线」只会让引擎更保守（当冲突处理），不会更激进。
    func reconciliationBaselines(
        provider: String = ReconciliationEngine.defaultProvider,
        entityType: String = ReconciliationEngine.defaultEntityType
    ) throws -> [ReconciliationBaseline] {
        let rows = try syncSnapshots(entityType: entityType, provider: provider)
        return rows.compactMap { row in
            guard let state = try? DayCueJSON.decode(ReminderComparableState.self, from: row.payloadJSON) else {
                return nil
            }
            return ReconciliationBaseline(
                entityId: row.entityId,
                provider: row.provider,
                state: state,
                capturedAt: row.capturedAt
            )
        }
    }

    // MARK: - 同步游标

    func setSyncCursor(scope: String, cursor: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO sync_cursor (scope, cursor, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at;
            """
        )
        try statement.bind([.text(scope), .text(cursor), .text(DayCueClock.nowUTCString())])
        try statement.run()
    }

    func syncCursor(scope: String) throws -> String? {
        let statement = try database.prepare("SELECT cursor FROM sync_cursor WHERE scope = ? LIMIT 1;")
        try statement.bind([.text(scope)])
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    func allSyncCursors() throws -> [SyncCursorRecord] {
        let statement = try database.prepare(
            "SELECT \(syncCursorColumns) FROM sync_cursor ORDER BY scope ASC;"
        )
        var result: [SyncCursorRecord] = []
        while try statement.step() {
            result.append(Self.makeSyncCursor(statement))
        }
        return result
    }

    func deleteSyncCursor(scope: String) throws {
        let statement = try database.prepare("DELETE FROM sync_cursor WHERE scope = ?;")
        try statement.bind([.text(scope)])
        try statement.run()
    }

    // MARK: - 同步墓碑

    func upsertSyncTombstone(_ record: SyncTombstoneRecord) throws {
        let statement = try database.prepare(
            """
            INSERT INTO sync_tombstone (entity_type, entity_id, deleted_at, remote_version)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
              deleted_at = excluded.deleted_at,
              remote_version = excluded.remote_version;
            """
        )
        try statement.bind([
            .text(record.entityType),
            .text(record.entityId),
            .text(record.deletedAt),
            record.remoteVersion.map { SQLiteValue.integer(Int64($0)) } ?? .null
        ])
        try statement.run()
    }

    func syncTombstone(entityType: String, entityId: String) throws -> SyncTombstoneRecord? {
        let statement = try database.prepare(
            "SELECT \(syncTombstoneColumns) FROM sync_tombstone WHERE entity_type = ? AND entity_id = ? LIMIT 1;"
        )
        try statement.bind([.text(entityType), .text(entityId)])
        guard try statement.step() else { return nil }
        return Self.makeSyncTombstone(statement)
    }

    /// entityType 为 nil 时返回全部墓碑。
    func syncTombstones(entityType: String? = nil) throws -> [SyncTombstoneRecord] {
        var sql = "SELECT \(syncTombstoneColumns) FROM sync_tombstone"
        var values: [SQLiteValue] = []
        if let entityType {
            sql += " WHERE entity_type = ?"
            values.append(.text(entityType))
        }
        sql += " ORDER BY deleted_at ASC;"

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [SyncTombstoneRecord] = []
        while try statement.step() {
            result.append(Self.makeSyncTombstone(statement))
        }
        return result
    }

    func deleteSyncTombstone(entityType: String, entityId: String) throws {
        let statement = try database.prepare(
            "DELETE FROM sync_tombstone WHERE entity_type = ? AND entity_id = ?;"
        )
        try statement.bind([.text(entityType), .text(entityId)])
        try statement.run()
    }

    func clearSyncTombstones() throws {
        try database.execute("DELETE FROM sync_tombstone;")
    }

    // MARK: - 行映射

    static func makeSyncSnapshot(_ statement: SQLiteStatement) -> SyncSnapshotRecord {
        SyncSnapshotRecord(
            entityType: statement.string(0) ?? "",
            entityId: statement.string(1) ?? "",
            provider: statement.string(2) ?? "",
            payloadJSON: statement.string(3) ?? "",
            contentHash: statement.string(4) ?? "",
            capturedAt: statement.string(5) ?? ""
        )
    }

    static func makeSyncCursor(_ statement: SQLiteStatement) -> SyncCursorRecord {
        SyncCursorRecord(
            scope: statement.string(0) ?? "",
            cursor: statement.string(1) ?? "",
            updatedAt: statement.string(2) ?? ""
        )
    }

    static func makeSyncTombstone(_ statement: SQLiteStatement) -> SyncTombstoneRecord {
        SyncTombstoneRecord(
            entityType: statement.string(0) ?? "",
            entityId: statement.string(1) ?? "",
            deletedAt: statement.string(2) ?? "",
            remoteVersion: statement.isNull(3) ? nil : statement.int(3)
        )
    }
}

let syncSnapshotColumns = "entity_type, entity_id, provider, payload_json, content_hash, captured_at"
let syncCursorColumns = "scope, cursor, updated_at"
let syncTombstoneColumns = "entity_type, entity_id, deleted_at, remote_version"
