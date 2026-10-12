import Foundation

// 本地变更采集器：把「本地和上次同步基线不一样」的实体写进 sync_change 队列。
//
// 为什么用「扫描 + 与基线比对」而不是在写入路径上挂钩子：
//   仓储的写入方法（insertTask / updateNote / ...）分布在多个已冻结的文件里，
//   在它们中间插入入队调用既要改既有文件，也漏不掉「别处直接改表」的路径。
//   扫描方式只需要读表，能在不改任何既有写入代码的前提下拿到完整变更集。
//
// 语义保证：
//   - 同一实体的多次修改合并成一行（sync_change 的主键）；
//   - 删除产生 op = delete 的条目，并写一条 sync_tombstone（复用既有表与类型）；
//   - 内容指纹与基线一致时什么都不做，因此重复采集是幂等的；
//   - 冲突未裁决的实体不会被采集覆盖（否则会把服务端那版弄丢）。

public struct CloudChangeCollector {

    private let store: DayCueStore

    public init(store: DayCueStore) {
        self.store = store
    }

    /// 扫描全部参与同步的实体类型。
    /// - Returns: 本次真正新建或改写的队列条目数。
    @discardableResult
    public func collect(at: Date, limit: Int = 1000) throws -> Int {
        var changed = 0
        for type in SyncEntityType.allCases {
            changed += try collect(entityType: type, at: at, limit: limit)
        }
        return changed
    }

    /// 单类型采集，便于测试与局部诊断。
    @discardableResult
    public func collect(entityType: SyncEntityType, at: Date, limit: Int = 1000) throws -> Int {
        try store.installCloudSyncSchema()

        let entities = try store.cloudLocalEntities(entityType: entityType, limit: limit)
        let existing = try store.syncChanges(entityType: entityType)
        var existingById: [String: SyncChangeRecord] = [:]
        for row in existing { existingById[row.entityId] = row }

        var seen: Set<String> = []
        var changed = 0

        for entity in entities {
            seen.insert(entity.entityId)
            let operation: SyncChangeOperation = entity.isDeleted ? .delete : .upsert
            // 删除只推墓碑、不推内容，所以载荷只在 upsert 时携带。
            let payloadJSON = operation == .upsert ? try SyncPayloadCodec.json(entity.payload) : nil
            let baseVersion = existingById[entity.entityId]?.baseVersion ?? 0

            let result = try store.enqueueSyncChange(
                entityType: entityType,
                entityId: entity.entityId,
                operation: operation,
                payloadJSON: payloadJSON,
                baseVersion: baseVersion,
                at: at
            )
            if result.changed { changed += 1 }

            if operation == .delete {
                try store.upsertSyncTombstone(SyncTombstoneRecord(
                    entityType: entityType.rawValue,
                    entityId: entity.entityId,
                    deletedAt: entity.updatedAt.isEmpty ? DayCueClock.nowUTCString(date: at) : entity.updatedAt,
                    remoteVersion: Int(baseVersion)
                ))
            }
        }

        // 本地行整个消失：capture 是硬删除，软删除表也可能被硬删（例如清库后重建）。
        // 只有「曾经同步过或曾经入过队」的实体才需要把删除传播出去；
        // 从未同步过的实体消失对服务端没有任何意义。
        for row in existing where !seen.contains(row.entityId) {
            // 冲突未裁决时不动队列，等用户在冲突页处理。
            if row.state == .conflict { continue }
            // 已经在删除流程里的条目不必重复入队。
            if row.operation == .delete { continue }

            let result = try store.enqueueSyncChange(
                entityType: entityType,
                entityId: row.entityId,
                operation: .delete,
                payloadJSON: nil,
                baseVersion: row.baseVersion,
                at: at
            )
            if result.changed { changed += 1 }

            try store.upsertSyncTombstone(SyncTombstoneRecord(
                entityType: entityType.rawValue,
                entityId: row.entityId,
                deletedAt: DayCueClock.nowUTCString(date: at),
                remoteVersion: Int(row.baseVersion)
            ))
        }

        return changed
    }
}
