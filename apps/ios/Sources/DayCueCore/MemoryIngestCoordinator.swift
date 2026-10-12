import Foundation

// 长期记忆从「有类没调用方」到真正跑起来的入口。
//
// 这条链路把散落在各处的能力按顺序串起来：
//   笔记 / 课后回复 -> 抽取候选 -> 类别开关（落库那一刻再查一次）-> 去重与冲突
//   -> 候选落库 -> 用户确认 -> 检索 -> 助手回答
//
// 用注入而不是单例：DayCueStore 是单连接、单写者的，同一进程里出现两份互不知情的
// 协调器会直接制造锁冲突；测试也需要换成临时目录里的库。
//
// 这条链路里没有一步读系统时钟：now 一律由调用方传入（界面传 Date()，
// 后台任务传它自己的时间基点），测试才能得到确定结果。

/// 一条候选被丢弃的原因。
///
/// **刻意不保存候选原文**：用户关掉某个类别的记录之后，我们不能再把他的内容写进别的地方，
/// 否则「停止记录」就成了一句空话。留下的是「哪一类、哪一步、为什么」，足够解释。
public struct MemoryIngestDiscard: Codable, Equatable, Sendable {

    public enum Stage: String, Codable, Sendable {
        /// 落库时发现该类别已被用户关闭。
        case recordingDisabled = "recording_disabled"
        /// 候选内容为空，写进去只会变成一条空事实。
        case emptyStatement = "empty_statement"
    }

    public var stage: Stage
    public var category: MemoryCategory?
    public var sourceKind: MemorySourceKind?
    public var originRecordId: String?
    public var reason: String

    public init(
        stage: Stage,
        category: MemoryCategory? = nil,
        sourceKind: MemorySourceKind? = nil,
        originRecordId: String? = nil,
        reason: String
    ) {
        self.stage = stage
        self.category = category
        self.sourceKind = sourceKind
        self.originRecordId = originRecordId
        self.reason = reason
    }
}

/// 因为「同类里已经有一模一样的说法」而跳过的候选。
public struct MemoryDuplicateSkip: Equatable, Sendable {

    public var candidateId: String
    public var existingMemoryId: String
    public var category: MemoryCategory
    public var reason: String

    public init(candidateId: String, existingMemoryId: String, category: MemoryCategory, reason: String) {
        self.candidateId = candidateId
        self.existingMemoryId = existingMemoryId
        self.category = category
        self.reason = reason
    }
}

/// 一次落库的结果。
///
/// 所有「没写进去」的情况都必须在这里出现，界面才能如实告诉用户发生了什么，
/// 而不是只给一个「成功」让用户以为全都记下了。
public struct MemoryIngestOutcome: Equatable, Sendable {

    /// 真正写进 memory_item 的记忆。状态只可能是 candidate 或 conflict。
    public var stored: [MemoryItem]
    public var duplicates: [MemoryDuplicateSkip]
    public var discards: [MemoryIngestDiscard]

    public var storedCandidates: [MemoryItem] { stored.filter { $0.status == .candidate } }
    public var storedConflicts: [MemoryItem] { stored.filter { $0.status == .conflict } }
    public var isEmpty: Bool { stored.isEmpty && duplicates.isEmpty && discards.isEmpty }

    public init(
        stored: [MemoryItem] = [],
        duplicates: [MemoryDuplicateSkip] = [],
        discards: [MemoryIngestDiscard] = []
    ) {
        self.stored = stored
        self.duplicates = duplicates
        self.discards = discards
    }

    /// 给用户看的一句话。
    ///
    /// 刻意不写成「成功 / 失败」的二选一：这段话要能解释为什么某几条没有写进去。
    public var summaryText: String {
        var parts: [String] = []
        if !storedCandidates.isEmpty { parts.append("记下 \(storedCandidates.count) 条候选记忆") }
        if !storedConflicts.isEmpty { parts.append("\(storedConflicts.count) 条需要你裁决的冲突") }
        if !duplicates.isEmpty { parts.append("跳过 \(duplicates.count) 条已经记过的") }
        let disabled = discards.filter { $0.stage == .recordingDisabled }.count
        if disabled > 0 { parts.append("按你的设置丢弃 \(disabled) 条") }
        let invalid = discards.filter { $0.stage == .emptyStatement }.count
        if invalid > 0 { parts.append("忽略 \(invalid) 条空内容") }
        guard !parts.isEmpty else { return "这次没有产生记忆。" }
        return parts.joined(separator: "，") + "。"
    }
}

/// 落库审计。注意这里同样**不含候选原文**，只记录数量与丢弃原因。
public struct MemoryIngestAudit: Codable, Equatable, Sendable {

    public var at: String
    public var storedCount: Int
    public var conflictCount: Int
    public var duplicateCount: Int
    public var discards: [MemoryIngestDiscard]

    public init(
        at: String,
        storedCount: Int,
        conflictCount: Int,
        duplicateCount: Int,
        discards: [MemoryIngestDiscard]
    ) {
        self.at = at
        self.storedCount = storedCount
        self.conflictCount = conflictCount
        self.duplicateCount = duplicateCount
        self.discards = discards
    }
}

/// 用户确认的结果。
public enum MemoryConfirmOutcome: Equatable, Sendable {

    case confirmed(MemoryItem)
    case alreadyConfirmed(MemoryItem)
    /// 与已确认的记忆互相矛盾。**不静默覆盖**，等用户先裁决旧的那条。
    case blockedByConflict(candidate: MemoryItem, conflicts: [MemoryItem])
    case notFound(String)
    /// 例如已经 retired 的说法不允许被「确认」复活。
    case notConfirmable(status: MemoryStatus)
}

/// 记忆链路的协调器。
///
/// 纯 struct：这条链路全是同步的本地库读写，没有并发状态要维护，
/// 做成 ObservableObject 反而会引入「谁是真相」的问题。
public struct MemoryIngestCoordinator {

    /// 审计记录写在 app_setting 里的键。抽成常量，读写两侧不会写错。
    public static let auditSettingKey = "memory.ingest.last_audit"

    public let store: DayCueStore
    public let extraction: MemoryExtraction
    public let answerer: MemoryGroundedAnswerer

    public init(
        store: DayCueStore,
        extraction: MemoryExtraction = MemoryExtraction(provider: UnconfiguredExtractor()),
        composer: MemoryAnswerComposer = RuleBasedAnswerComposer()
    ) {
        self.store = store
        self.extraction = extraction
        self.answerer = MemoryGroundedAnswerer(
            engine: MemorySearchEngine(store: store),
            composer: composer
        )
    }

    // MARK: - 抽取

    /// 只抽取、不检查开关、不写库。
    ///
    /// 为什么把它单独暴露出来：
    /// 1. 能显式构造「迟到响应」场景（提取时开着、落库时已关闭）；
    /// 2. 界面可以先预览候选，再让用户逐条确认，而不是抽完就写。
    public func extractCandidates(
        notes: [NoteRecord] = [],
        replies: [FollowUpReplyRecord] = [],
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone
    ) throws -> [MemoryCandidate] {
        try extraction.candidates(notes: notes, replies: replies, now: now, timeZone: timeZone)
    }

    // MARK: - 落库

    /// 便捷入口：抽取 + 落库。
    @discardableResult
    public func ingest(
        notes: [NoteRecord] = [],
        replies: [FollowUpReplyRecord] = [],
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone
    ) throws -> MemoryIngestOutcome {
        // 抽取失败（例如未配置）时这里直接抛出，一条记忆都不会写。
        let candidates = try extractCandidates(notes: notes, replies: replies, now: now, timeZone: timeZone)
        return try ingest(candidates: candidates, now: now, timeZone: timeZone)
    }

    /// 真正写库的一步。所有候选都要在这里再过一次开关。
    @discardableResult
    public func ingest(
        candidates: [MemoryCandidate],
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone
    ) throws -> MemoryIngestOutcome {
        var outcome = MemoryIngestOutcome()

        for candidate in candidates {
            let category = candidate.draft.category
            let trimmed = candidate.draft.statement.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else {
                outcome.discards.append(MemoryIngestDiscard(
                    stage: .emptyStatement,
                    category: category,
                    sourceKind: candidate.draft.sourceKind,
                    originRecordId: candidate.originRecordId,
                    reason: "候选内容是空的，没有写入。"
                ))
                continue
            }

            // 关键一步：**在落库这一刻再查一次**类别开关。
            //
            // 抽取可能发生在几秒甚至几分钟之前（后台任务、迟到的解析响应），
            // 只在提取时查一次的话，用户中途关掉开关之后内容照样会被写进来，
            // 「按类别停止记录」就形同虚设。
            guard try store.isRecordingEnabled(category: category) else {
                outcome.discards.append(MemoryIngestDiscard(
                    stage: .recordingDisabled,
                    category: category,
                    sourceKind: candidate.draft.sourceKind,
                    originRecordId: candidate.originRecordId,
                    reason: "你已关闭「\(category.displayName)」的记录开关，这条候选没有写入。"
                ))
                continue
            }

            // 幂等：候选 id 是确定性的，同一个候选重复落库会命中已存在的行。
            if let existing = try store.memory(id: candidate.id) {
                outcome.duplicates.append(MemoryDuplicateSkip(
                    candidateId: candidate.id,
                    existingMemoryId: existing.id,
                    category: category,
                    reason: "这条候选已经写过了。"
                ))
                continue
            }

            // 每次都重新读一遍现有记忆：同一批候选里前面的条目也要参与后面的去重与冲突判断。
            let existingItems = try store.memories(includeDeleted: false, limit: 5000)
            let admission = MemoryCandidatePolicy.admit(candidate.draft, among: existingItems)

            if let duplicateId = admission.duplicateOfMemoryId {
                outcome.duplicates.append(MemoryDuplicateSkip(
                    candidateId: candidate.id,
                    existingMemoryId: duplicateId,
                    category: category,
                    reason: "同类里已经有一模一样的说法，没有重复写入。"
                ))
                continue
            }

            // 抽取不是用户确认：除了明确冲突之外，落库一律是 candidate。
            // 这样「推断永不自动 confirmed」就不依赖具体抽取器是否守规矩。
            let status: MemoryStatus = admission.status == .conflict ? .conflict : .candidate

            var item = MemoryCandidatePolicy.makeItem(
                candidate.draft,
                admission: admission,
                id: candidate.id,
                createdAt: candidate.extractedAt,
                updatedAt: candidate.extractedAt
            )
            item.status = status
            try store.insertMemory(item, at: now)
            outcome.stored.append(item)
        }

        persistAudit(for: outcome, at: now)
        return outcome
    }

    // MARK: - 用户确认

    /// 用户确认一条候选。
    ///
    /// 只有这里才允许把 sourceKind 升级为 userStatement（= 用户断言），
    /// 也只有这里才允许把状态改成 confirmed；两者必须在同一处发生，
    /// 否则会出现「confirmed 但来源仍是 inferred」这种会污染检索的事实。
    @discardableResult
    public func confirm(candidateId: String, now: Date) throws -> MemoryConfirmOutcome {
        guard let existing = try store.memory(id: candidateId) else {
            return .notFound(candidateId)
        }

        switch existing.status {
        case .confirmed:
            return .alreadyConfirmed(existing)
        case .retired:
            // 已作废的说法不允许被「确认」复活：用户想恢复应该改说法或重新添加。
            return .notConfirmable(status: .retired)
        case .candidate, .conflict:
            break
        }

        // 确认之前先看它会不会和已确认的记忆互相矛盾。
        // 单值类别（阶段状态 / 地点）任何第二种说法都是矛盾，非单值类别要看否定。
        let others = try store.memories(includeDeleted: false, limit: 5000)
            .filter { $0.id != candidateId }
        let draft = MemoryDraft(
            category: existing.category,
            statement: existing.statement,
            sourceKind: .userStatement
        )
        let confirmedConflicts = MemoryConflictDetector.conflicts(of: draft, among: others)
            .filter { $0.status == .confirmed }

        guard confirmedConflicts.isEmpty else {
            return .blockedByConflict(candidate: existing, conflicts: confirmedConflicts)
        }

        // 顺序不能反：先把状态改成 confirmed，再写一条新修订。
        // 否则 updateMemoryStatement 会按**旧状态**镜像出一条 candidate 的最新修订，
        // 出现「主记录 confirmed、最新修订 candidate」的自相矛盾。
        try store.setMemoryStatus(id: candidateId, status: .confirmed, at: now)
        _ = try store.updateMemoryStatement(
            id: candidateId,
            statement: existing.statement,
            sourceKind: .userStatement,
            at: now
        )

        guard let updated = try store.memory(id: candidateId) else {
            throw MemoryStoreError.memoryNotFound(candidateId)
        }
        return .confirmed(updated)
    }

    // MARK: - 检索回答

    /// 用检索到的**已确认**记忆回答问题。没有可用记忆时如实说「没有相关记忆」，不编。
    public func answer(
        question: String,
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone,
        limit: Int = 5
    ) throws -> MemoryGroundedAnswer {
        try answerer.answer(question: question, now: now, timeZone: timeZone, limit: limit)
    }

    // MARK: - 审计

    /// 读回最近一次落库审计。从未抽取过时返回 nil，不猜一个空记录。
    public func lastAuditRecord() -> MemoryIngestAudit? {
        guard let json = store.setting(Self.auditSettingKey), !json.isEmpty else { return nil }
        return try? DayCueJSON.decode(MemoryIngestAudit.self, from: json)
    }

    /// 把这次落库的结论写进 app_setting，供设置页与排障查看。
    ///
    /// 审计写失败不影响已经完成的写入，所以这里只吞掉错误：
    /// 一次设置写入失败不能让用户以为「记忆没保存」。
    private func persistAudit(for outcome: MemoryIngestOutcome, at now: Date) {
        let audit = MemoryIngestAudit(
            at: RFC3339.utcString(from: now),
            storedCount: outcome.storedCandidates.count,
            conflictCount: outcome.storedConflicts.count,
            duplicateCount: outcome.duplicates.count,
            discards: outcome.discards
        )
        guard let json = try? DayCueJSON.encodeToString(audit) else { return }
        try? store.setSetting(Self.auditSettingKey, value: json)
    }
}
