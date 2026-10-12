import Foundation

// 长期记忆的持久化层。
//
// 表结构由 Schema v2 冻结，这里只做映射，绝不改表：
// - memory_item：v1 就存在的窄表，只放「当前生效的那一行」。
//   为什么把类别写进 kind：v2 承诺「只新增表、不改既有列」，而 memory_item 没有 category 列，
//   所以类别复用 kind 这一列；读取时优先用最新 revision 的 kind，取不到才回退 memory_item.kind。
// - memory_revision：每一次「说法变更」都是一行，历史永不覆盖。
// - memory_control：按类别控制「是否记录」。
// - memory_index：本地关键词倒排。删记忆时必须同一事务清掉，否则已删除的记忆还能被检索到。
//
// DomainModels.swift 是冻结文件，所以 memory_revision 的表对应类型定义在本文件里，
// 与列一一对应，避免同一张表出现两份字段定义。

/// 一条记忆修订。与 memory_revision 表一一对应。revision 从 1 开始递增，历史永不删除。
public struct MemoryRevisionRecord: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var memoryId: String
    public var revision: Int
    public var category: MemoryCategory
    public var statement: String
    public var status: MemoryStatus
    public var confidence: Double?
    public var sourceKind: MemorySourceKind
    public var sourceRef: String?
    public var effectiveFrom: String?
    public var effectiveTo: String?
    public var createdAt: String

    public init(
        id: String = DayCueID.new(),
        memoryId: String,
        revision: Int,
        category: MemoryCategory,
        statement: String,
        status: MemoryStatus,
        confidence: Double? = nil,
        sourceKind: MemorySourceKind,
        sourceRef: String? = nil,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.memoryId = memoryId
        self.revision = revision
        self.category = category
        self.statement = statement
        self.status = status
        self.confidence = confidence
        self.sourceKind = sourceKind
        self.sourceRef = sourceRef
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.createdAt = createdAt
    }
}

public enum MemoryStoreError: Error, Equatable {
    case memoryNotFound(String)
}

/// 倒排索引里的权重常量。
///
/// 单独抽出来是为了让「以后想给不同来源不同权重」只改一处，
/// 而不是散落在插入与重建索引两条路径里各写一个字面量。
public enum MemoryIndexWeight {
    public static let statement = 1.0
}

public extension DayCueStore {

    // MARK: - 写入

    /// 新增一条记忆：memory_item（当前行）+ memory_revision（第 1 版）+ memory_index（倒排）三件事一个事务。
    ///
    /// 为什么索引必须在同一个事务里写：如果先落库再建索引，中途失败就会留下
    /// 「存在但搜不到」的记忆——用户会以为 App 把它弄丢了。
    @discardableResult
    func insertMemory(_ item: MemoryItem, at: Date? = nil) throws -> MemoryItem {
        var record = item
        let nowString = RFC3339.utcString(from: at ?? Date())
        if record.createdAt.isEmpty { record.createdAt = nowString }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }
        if record.revision <= 0 { record.revision = 1 }

        // 事务内不能提前 return 出去，所以用局部变量接住返回值再统一返回。
        let inserted: MemoryItem = try database.transaction {
            let itemStatement = try database.prepare(
                """
                INSERT INTO memory_item
                  (id, kind, statement, status, source_capture_id, review_at, created_at, deleted_at)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, ?);
                """
            )
            try itemStatement.bind([
                .text(record.id),
                .text(record.category.rawValue),
                .text(record.statement),
                .text(record.status.rawValue),
                .text(record.createdAt),
                .optionalText(record.deletedAt)
            ])
            try itemStatement.run()

            let revision = MemoryRevisionRecord(
                id: Self.memoryRevisionId(memoryId: record.id, revision: record.revision),
                memoryId: record.id,
                revision: record.revision,
                category: record.category,
                statement: record.statement,
                status: record.status,
                confidence: record.confidence,
                sourceKind: record.sourceKind,
                sourceRef: record.sourceRef,
                effectiveFrom: record.effectiveFrom,
                effectiveTo: record.effectiveTo,
                createdAt: record.updatedAt
            )
            try insertMemoryRevision(revision)

            try writeMemoryIndexTokens(memoryId: record.id, statement: record.statement)
            return record
        }
        return inserted
    }

    /// 新增一条修订。用固定列顺序插入，避免以后有人加列时静默错位。
    func insertMemoryRevision(_ revision: MemoryRevisionRecord) throws {
        let statement = try database.prepare(
            """
            INSERT INTO memory_revision
              (id, memory_id, revision, kind, statement, status, confidence, source_kind,
               source_ref, effective_from, effective_to, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(revision.id),
            .text(revision.memoryId),
            .integer(Int64(revision.revision)),
            .text(revision.category.rawValue),
            .text(revision.statement),
            .text(revision.status.rawValue),
            revision.confidence.map { SQLiteValue.real($0) } ?? SQLiteValue.null,
            .text(revision.sourceKind.rawValue),
            .optionalText(revision.sourceRef),
            .optionalText(revision.effectiveFrom),
            .optionalText(revision.effectiveTo),
            .text(revision.createdAt)
        ])
        try statement.run()
    }

    /// 用户改说法：写一条新修订并把 memory_item 的当前说法换掉，索引同步重建。
    ///
    /// 为什么不覆盖旧修订：用户改口之后「以前是这么说的」本身也是有用的信息，
    /// 而且界面要能回答「这条记忆是什么时候变成现在这样的」。
    @discardableResult
    func updateMemoryStatement(
        id: String,
        statement: String,
        sourceKind: MemorySourceKind? = nil,
        confidence: Double? = nil,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil,
        at: Date? = nil
    ) throws -> MemoryItem {
        guard let existing = try memory(id: id) else { throw MemoryStoreError.memoryNotFound(id) }

        let nowString = RFC3339.utcString(from: at ?? Date())
        let revisionNumber = try nextMemoryRevisionNumber(memoryId: id)
        let resolvedSource = sourceKind ?? existing.sourceKind

        try database.transaction {
            let update = try database.prepare("UPDATE memory_item SET statement = ?, kind = ? WHERE id = ?;")
            try update.bind([
                .text(statement),
                .text(existing.category.rawValue),
                .text(id)
            ])
            try update.run()

            let revision = MemoryRevisionRecord(
                id: Self.memoryRevisionId(memoryId: id, revision: revisionNumber),
                memoryId: id,
                revision: revisionNumber,
                category: existing.category,
                statement: statement,
                status: existing.status,
                confidence: confidence ?? existing.confidence,
                sourceKind: resolvedSource,
                sourceRef: existing.sourceRef,
                effectiveFrom: effectiveFrom ?? existing.effectiveFrom,
                effectiveTo: effectiveTo ?? existing.effectiveTo,
                createdAt: nowString
            )
            try insertMemoryRevision(revision)

            try writeMemoryIndexTokens(memoryId: id, statement: statement)
        }

        return try memory(id: id) ?? existing
    }

    /// 改状态（确认候选 / 标记有冲突 / 退役）。
    ///
    /// 状态不单独占一版修订：修订记录的是「说法怎么变的」，状态是记忆自身的属性。
    /// 但 memory_revision.status 是 NOT NULL，所以最新那条修订要同步镜像，
    /// 否则「最新修订说 candidate、主记录说 confirmed」会让人无从判断谁是真的。
    func setMemoryStatus(id: String, status: MemoryStatus, at: Date? = nil) throws {
        guard try memory(id: id) != nil else { throw MemoryStoreError.memoryNotFound(id) }
        let revisionNumber = try latestMemoryRevisionNumber(memoryId: id)

        try database.transaction {
            let updateItem = try database.prepare("UPDATE memory_item SET status = ? WHERE id = ?;")
            try updateItem.bind([.text(status.rawValue), .text(id)])
            try updateItem.run()

            // 只有存在修订行时才镜像；历史遗留的空记忆没有修订可改。
            if let revisionNumber {
                let updateRevision = try database.prepare(
                    "UPDATE memory_revision SET status = ? WHERE memory_id = ? AND revision = ?;"
                )
                try updateRevision.bind([
                    .text(status.rawValue),
                    .text(id),
                    .integer(Int64(revisionNumber))
                ])
                try updateRevision.run()
            }
        }
    }

    /// 软删除，并且**在同一个事务里删掉 memory_index 中该记忆的所有行**。
    ///
    /// 这一步不能省：memory_index 是独立表，没有外键级联，
    /// 少删一次就会让已删除的记忆继续出现在检索结果里——用户会认为删除没生效。
    func softDeleteMemory(id: String, at: Date? = nil) throws {
        let nowString = RFC3339.utcString(from: at ?? Date())
        try database.transaction {
            // deleted_at 用 COALESCE：重复删除不应该把删除时间往后推，否则对账会拿到不稳定的值。
            let update = try database.prepare(
                "UPDATE memory_item SET deleted_at = COALESCE(deleted_at, ?) WHERE id = ?;"
            )
            try update.bind([.text(nowString), .text(id)])
            try update.run()

            try deleteMemoryIndexTokens(memoryId: id)
        }
    }

    /// 一键清除：软删除全部记忆并清空整张倒排索引。返回受影响条数。
    @discardableResult
    func clearAllMemories(at: Date? = nil) throws -> Int {
        let nowString = RFC3339.utcString(from: at ?? Date())
        return try database.transaction {
            let countStatement = try database.prepare(
                "SELECT COUNT(*) FROM memory_item WHERE deleted_at IS NULL;"
            )
            guard try countStatement.step() else { return 0 }
            let count = countStatement.int(0)

            let update = try database.prepare(
                "UPDATE memory_item SET deleted_at = COALESCE(deleted_at, ?) WHERE deleted_at IS NULL;"
            )
            try update.bind([.text(nowString)])
            try update.run()

            try database.execute("DELETE FROM memory_index;")
            return count
        }
    }

    // MARK: - 查询

    /// 按 id 取回一条未删除的记忆，并带上最新修订里的来源与有效期。
    func memory(id: String) throws -> MemoryItem? {
        let statement = try database.prepare(
            "SELECT \(memoryJoinedColumns) FROM memory_item m \(memoryLatestRevisionJoin) WHERE m.id = ? AND m.deleted_at IS NULL LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeMemory(statement)
    }

    /// 列表查询。category / status 为 nil 表示不筛选；默认只看未删除的。
    func memories(
        category: MemoryCategory? = nil,
        status: MemoryStatus? = nil,
        includeDeleted: Bool = false,
        limit: Int = 500
    ) throws -> [MemoryItem] {
        var sql = "SELECT \(memoryJoinedColumns) FROM memory_item m \(memoryLatestRevisionJoin) WHERE 1 = 1"
        var values: [SQLiteValue] = []
        if let category {
            sql += " AND m.kind = ?"
            values.append(.text(category.rawValue))
        }
        if let status {
            sql += " AND m.status = ?"
            values.append(.text(status.rawValue))
        }
        if !includeDeleted {
            sql += " AND m.deleted_at IS NULL"
        }
        sql += " ORDER BY m.created_at DESC, m.id ASC LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [MemoryItem] = []
        while try statement.step() {
            result.append(Self.makeMemory(statement))
        }
        return result
    }

    /// 记忆条数。设置页「已保存 N 条」用它。
    func memoryCount(includeDeleted: Bool = false) throws -> Int {
        var sql = "SELECT COUNT(*) FROM memory_item"
        if !includeDeleted { sql += " WHERE deleted_at IS NULL" }
        sql += ";"
        let statement = try database.prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// 某条记忆的全部历史修订，按版本号正序。
    func revisions(memoryId: String) throws -> [MemoryRevisionRecord] {
        let statement = try database.prepare(
            """
            SELECT \(memoryRevisionColumns) FROM memory_revision
            WHERE memory_id = ?
            ORDER BY revision ASC, id ASC;
            """
        )
        try statement.bind([.text(memoryId)])
        var result: [MemoryRevisionRecord] = []
        while try statement.step() {
            result.append(Self.makeMemoryRevision(statement))
        }
        return result
    }

    /// 最新一条修订。没有修订行（历史遗留数据）时返回 nil，调用方必须能接受 nil。
    func latestRevision(memoryId: String) throws -> MemoryRevisionRecord? {
        guard let number = try latestMemoryRevisionNumber(memoryId: memoryId) else { return nil }
        let statement = try database.prepare(
            "SELECT \(memoryRevisionColumns) FROM memory_revision WHERE memory_id = ? AND revision = ? LIMIT 1;"
        )
        try statement.bind([.text(memoryId), .integer(Int64(number))])
        guard try statement.step() else { return nil }
        return Self.makeMemoryRevision(statement)
    }

    // MARK: - 记录开关

    /// 按类别开关「是否记录」。关掉之后推断流程不应该再为这个类别落库。
    func setRecordingEnabled(category: MemoryCategory, enabled: Bool, at: Date? = nil) throws {
        let statement = try database.prepare(
            """
            INSERT INTO memory_control (category, recording_enabled, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(category) DO UPDATE SET
              recording_enabled = excluded.recording_enabled,
              updated_at = excluded.updated_at;
            """
        )
        try statement.bind([
            .text(category.rawValue),
            .bool(enabled),
            .text(RFC3339.utcString(from: at ?? Date()))
        ])
        try statement.run()
    }

    /// 默认值是「开」：用户从没关过就等于允许记录。
    /// 把默认值定成「关」会更保守，但那样新用户会觉得记忆功能坏了。
    func isRecordingEnabled(category: MemoryCategory) throws -> Bool {
        let statement = try database.prepare(
            "SELECT recording_enabled FROM memory_control WHERE category = ? LIMIT 1;"
        )
        try statement.bind([.text(category.rawValue)])
        guard try statement.step() else { return true }
        return statement.bool(0)
    }

    /// 一次取回全部类别的开关状态，设置页只查一次库。
    func recordingControlSnapshot() throws -> [MemoryCategory: Bool] {
        var snapshot: [MemoryCategory: Bool] = [:]
        for category in MemoryCategory.allCases {
            snapshot[category] = try isRecordingEnabled(category: category)
        }
        return snapshot
    }

    // MARK: - 倒排索引

    /// 重建某条记忆的倒排索引。返回写入的词条数。
    ///
    /// 记忆不存在或已删除时把索引清空并返回 0：宁可少索引，也不能留下
    /// 指向不存在记忆的悬空索引行。
    @discardableResult
    func reindexMemory(id: String) throws -> Int {
        guard let item = try memory(id: id) else {
            try database.transaction {
                try deleteMemoryIndexTokens(memoryId: id)
            }
            return 0
        }
        return try database.transaction {
            try writeMemoryIndexTokens(memoryId: id, statement: item.statement)
        }
    }

    /// 整库重建。返回写入的词条总数。
    ///
    /// 用途是「分词规则升级」或「索引怀疑损坏」时的兜底：先整表清空再按当前说法重建，
    /// 不做增量猜测。
    @discardableResult
    func reindexAllMemories() throws -> Int {
        try database.transaction {
            try database.execute("DELETE FROM memory_index;")
            var total = 0
            for item in try memories(includeDeleted: false, limit: 10000) {
                total += try writeMemoryIndexTokens(memoryId: item.id, statement: item.statement)
            }
            return total
        }
    }

    /// 某条记忆当前的索引词条数。删除测试要用它证明「索引真的被清了」。
    func indexedTokenCount(memoryId: String) throws -> Int {
        let statement = try database.prepare("SELECT COUNT(*) FROM memory_index WHERE memory_id = ?;")
        try statement.bind([.text(memoryId)])
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    // MARK: - 内部：索引与修订号

    /// 删除某条记忆的全部倒排行。
    func deleteMemoryIndexTokens(memoryId: String) throws {
        let statement = try database.prepare("DELETE FROM memory_index WHERE memory_id = ?;")
        try statement.bind([.text(memoryId)])
        try statement.run()
    }

    /// 重建索引：先删后插，保证「改了说法之后旧词不会继续命中」。
    @discardableResult
    func writeMemoryIndexTokens(memoryId: String, statement: String) throws -> Int {
        try deleteMemoryIndexTokens(memoryId: memoryId)

        let insert = try database.prepare(
            """
            INSERT INTO memory_index (memory_id, token, weight) VALUES (?, ?, ?)
            ON CONFLICT(memory_id, token) DO UPDATE SET weight = excluded.weight;
            """
        )
        var written = 0
        for token in MemoryTokenizer.tokens(in: statement) {
            try insert.bind([
                .text(memoryId),
                .text(token),
                .real(MemoryIndexWeight.statement)
            ])
            try insert.run()
            written += 1
        }
        return written
    }

    /// 下一条修订号。用表里的最大值而不是本地计数，避免并发写入时两版撞号。
    private func nextMemoryRevisionNumber(memoryId: String) throws -> Int {
        (try latestMemoryRevisionNumber(memoryId: memoryId) ?? 0) + 1
    }

    private func latestMemoryRevisionNumber(memoryId: String) throws -> Int? {
        let statement = try database.prepare(
            "SELECT MAX(revision) FROM memory_revision WHERE memory_id = ?;"
        )
        try statement.bind([.text(memoryId)])
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return statement.int(0)
    }
}

// MARK: - 行映射

public extension DayCueStore {

    /// 记忆行映射。memory_item 是必需的一半，memory_revision 可能为空（历史遗留行）。
    static func makeMemory(_ statement: SQLiteStatement) -> MemoryItem {
        let baseId = statement.string(0) ?? ""
        let baseKind = statement.string(1) ?? MemoryCategory.preference.rawValue
        let baseStatement = statement.string(2) ?? ""
        let baseStatus = MemoryStatus(rawValue: statement.string(3) ?? "candidate") ?? .candidate
        let baseCreatedAt = statement.string(4) ?? ""
        let baseDeletedAt = statement.string(5)

        // 没有修订行只能说明这条记忆是旧版本写下的：按最小信息还原，
        // revision 记 0，来源按最保守的「推断」处理（绝不凭默认值冒充用户设置）。
        if statement.isNull(6) {
            return MemoryItem(
                id: baseId,
                category: MemoryCategory(rawValue: baseKind) ?? .preference,
                statement: baseStatement,
                status: baseStatus,
                sourceKind: .inferred,
                confidence: nil,
                sourceRef: nil,
                revision: 0,
                effectiveFrom: nil,
                effectiveTo: nil,
                createdAt: baseCreatedAt,
                updatedAt: baseCreatedAt,
                deletedAt: baseDeletedAt
            )
        }

        let revision = statement.int(7)
        let revisionKind = statement.string(8) ?? baseKind
        let revisionStatement = statement.string(9) ?? baseStatement
        let revisionStatus = MemoryStatus(rawValue: statement.string(10) ?? baseStatus.rawValue) ?? baseStatus
        let sourceKind = MemorySourceKind(rawValue: statement.string(12) ?? "inferred") ?? .inferred
        let revisionCreatedAt = statement.string(16) ?? baseCreatedAt

        return MemoryItem(
            id: baseId,
            category: MemoryCategory(rawValue: revisionKind) ?? .preference,
            statement: revisionStatement,
            status: revisionStatus,
            sourceKind: sourceKind,
            confidence: statement.isNull(11) ? nil : statement.double(11),
            sourceRef: statement.string(13),
            revision: revision,
            effectiveFrom: statement.string(14),
            effectiveTo: statement.string(15),
            createdAt: baseCreatedAt,
            updatedAt: revisionCreatedAt,
            deletedAt: baseDeletedAt
        )
    }

    static func makeMemoryRevision(_ statement: SQLiteStatement) -> MemoryRevisionRecord {
        MemoryRevisionRecord(
            id: statement.string(0) ?? "",
            memoryId: statement.string(1) ?? "",
            revision: statement.int(2),
            category: MemoryCategory(rawValue: statement.string(3) ?? "preference") ?? .preference,
            statement: statement.string(4) ?? "",
            status: MemoryStatus(rawValue: statement.string(5) ?? "candidate") ?? .candidate,
            // confidence 是 REAL 列：为 NULL 就是「没有置信度」，不猜一个默认值。
            confidence: statement.isNull(6) ? nil : statement.double(6),
            sourceKind: MemorySourceKind(rawValue: statement.string(7) ?? "inferred") ?? .inferred,
            sourceRef: statement.string(8),
            effectiveFrom: statement.string(9),
            effectiveTo: statement.string(10),
            createdAt: statement.string(11) ?? ""
        )
    }
}

extension DayCueStore {
    /// 修订 id 由「记忆 id + 版本号」确定性推导：重放同一次修订会命中主键，
    /// 而不是悄悄插出两条内容相同的修订。
    static func memoryRevisionId(memoryId: String, revision: Int) -> String {
        "memrev_" + String(SHA256Hex.digest("memory_revision:\(memoryId):\(revision)").prefix(24))
    }
}

/// 列顺序集中一处，取值下标才不会随查询改动而错位。
let memoryRevisionColumns = "id, memory_id, revision, kind, statement, status, confidence, source_kind, source_ref, effective_from, effective_to, created_at"

/// memory_item 与「最新一条修订」的联表列。前半段是主记录，后半段是修订（可能全为 NULL）。
let memoryJoinedColumns = "m.id, m.kind, m.statement, m.status, m.created_at, m.deleted_at, r.id, r.revision, r.kind, r.statement, r.status, r.confidence, r.source_kind, r.source_ref, r.effective_from, r.effective_to, r.created_at"

/// 只取最新一条修订的相关子查询。写成常量是为了让 memory(id:) 与 memories(...) 用同一份连接条件。
let memoryLatestRevisionJoin = "LEFT JOIN memory_revision r ON r.memory_id = m.id AND r.revision = (SELECT MAX(revision) FROM memory_revision WHERE memory_id = m.id)"
