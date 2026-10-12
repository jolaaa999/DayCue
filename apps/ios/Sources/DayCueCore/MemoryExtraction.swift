import Foundation

// 记忆候选的抽取。
//
// 为什么先把「抽取」抽成协议：本机没有真实模型，默认实现必须是**确定性**的，
// 否则任何测试都无法断言「每次结果一样」；将来接入后端模型时只换一个 provider，
// 「开关检查 / 去重 / 冲突 / 落库」那条链路一行都不用动。
//
// 三条产品底线写进类型而不是只写在文档里：
// 1. 未配置提供方时抛明确的未配置错误，**绝不**返回空数组冒充「没有记忆」——
//    空数组的语义是「这段文字里确实没有可记的东西」，两者不能混。
// 2. 模型推断出来的一律 sourceKind = .inferred，由策略层压成 candidate，永不自动 confirmed。
// 3. 用户原话（「我习惯…」）仍然先落 candidate，只有用户在界面上确认之后才算事实。

/// 候选来自哪一类记录。
public enum MemoryCandidateOrigin: String, Codable, CaseIterable, Sendable {
    case note
    case followUpReply = "follow_up_reply"

    public var displayName: String {
        switch self {
        case .note: return "笔记"
        case .followUpReply: return "课后回复"
        }
    }
}

/// 抽取阶段可能出现的错误。
///
/// 单独区分「未配置」与「没有结果」：前者是配置问题，必须让用户看见；
/// 后者是正常业务结果。
public enum MemoryExtractionError: Error, Equatable {
    case providerNotConfigured
}

extension MemoryExtractionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "还没有配置记忆抽取，DayCue 不会凭空生成任何记忆。"
        }
    }
}

/// 抽取上下文。时间与内容分开放：抽取器不读系统时钟，测试与后台任务才能得到确定结果。
public struct MemoryExtractionContext: Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date, timeZone: TimeZone = MemorySearchEngine.defaultTimeZone) {
        self.now = now
        self.timeZone = timeZone
    }
}

/// 一条抽取结果：说法 + 它从哪条记录来。
///
/// originRecordId 必须留着：用户在候选列表里点「这条不对」时，
/// 界面要能回到那篇笔记或那条回复，而不是只给一个孤零零的句子。
public struct MemoryCandidate: Equatable, Sendable, Identifiable {

    public var id: String
    public var draft: MemoryDraft
    public var origin: MemoryCandidateOrigin
    public var originRecordId: String
    public var evidenceText: String
    public var extractedAt: String

    public init(
        id: String = DayCueID.new(),
        draft: MemoryDraft,
        origin: MemoryCandidateOrigin,
        originRecordId: String,
        evidenceText: String,
        extractedAt: String
    ) {
        self.id = id
        self.draft = draft
        self.origin = origin
        self.originRecordId = originRecordId
        self.evidenceText = evidenceText
        self.extractedAt = extractedAt
    }

    /// 候选 id 由「来源 + 记录 id + 归一化后的说法」确定性推导。
    ///
    /// 为什么不用随机 UUID：同一条笔记重试一次抽取，不应该在库里留下两条一模一样的候选；
    /// 确定性 id 让重复抽取直接命中同一条记录，天然幂等。
    public static func stableId(
        origin: MemoryCandidateOrigin,
        originRecordId: String,
        statement: String
    ) -> String {
        let normalized = MemoryConflictDetector.normalizedText(statement)
        let material = "memory_candidate:\(origin.rawValue):\(originRecordId):\(normalized)"
        return "memcand_" + String(SHA256Hex.digest(material).prefix(24))
    }
}

/// 抽取提供方。
public protocol MemoryExtractionProvider: Sendable {

    /// 未配置时必须是 false。抽取主流程据此决定要不要调用 extract。
    var isConfigured: Bool { get }

    /// 只读抽取。实现方不得写库、不得读系统时钟（时间从 context 取）。
    func extract(
        notes: [NoteRecord],
        replies: [FollowUpReplyRecord],
        context: MemoryExtractionContext
    ) throws -> [MemoryCandidate]
}

/// 默认实现：没有配置任何供应商。
///
/// 它的存在就是产品承诺本身——宁可明确报告「未配置」，也不返回空数组假装
/// 「这段文字里没有可记的」，更不生成任何假记忆。
public struct UnconfiguredExtractor: MemoryExtractionProvider {

    public init() {}

    public var isConfigured: Bool { false }

    public func extract(
        notes: [NoteRecord],
        replies: [FollowUpReplyRecord],
        context: MemoryExtractionContext
    ) throws -> [MemoryCandidate] {
        throw MemoryExtractionError.providerNotConfigured
    }
}

/// 确定性规则抽取器：本机没有真实模型时的默认实现。
///
/// 规则只用「是否出现某个固定短语」判断，不用分词、不用统计、不读时钟，
/// 所以同一份输入在任何设备、任何时间都得到同一份候选。
public struct DefaultRuleBasedExtractor: MemoryExtractionProvider {

    public init() {}

    public var isConfigured: Bool { true }

    /// 每条记录最多产出多少条候选。
    ///
    /// 一条长笔记能命中十几个短语，全放出去用户根本看不过来，候选列表就废了；
    /// 取前 N 条至少保证顺序是确定的、可预期的。
    public static let maxCandidatesPerRecord = 5

    /// 推断置信度。固定一个小值，表示「这只是线索，不是事实」，
    /// 界面可以据此决定展示优先级，但状态一律由策略层压成 candidate。
    public static let inferredConfidence: Double = 0.4

    /// 显式用户表述规则。命中即 sourceKind = .userStatement（用户原话），
    /// 但落库时仍然先落 candidate，等用户在界面上确认。
    ///
    /// 长的短语放前面：先匹配到更具体的类别，避免「我住在…」被更泛的规则抢走。
    public static let explicitRules: [(category: MemoryCategory, markers: [String])] = [
        (.place, ["我住在", "我家在", "我常在", "我一般在", "我通常去", "我住"]),
        (.person, ["我的室友", "我的同学", "我的老师", "我的朋友", "我朋友", "我和"]),
        (.preference, ["我习惯", "我通常", "我不喜欢", "我喜欢", "我偏好", "我讨厌", "我更愿意", "我更喜欢"]),
        (.goal, ["我的目标是", "我打算", "我计划", "我准备", "我想", "我要"]),
        (.phase, ["我这学期", "我这个学期", "我目前", "我最近在", "我现在"]),
        (.experience, ["我经历过", "我去过", "我学过", "我做过", "我对"])
    ]

    /// 推断规则。只有一句话完全没有命中显式表述时才用，且 sourceKind 固定为 .inferred。
    ///
    /// 这些词只是「看起来像长期习惯」的确定性线索，不是语义理解；
    /// 宁可少推断，也不要从一句话里脑补出用户没说过的事。
    public static let inferredRules: [(category: MemoryCategory, markers: [String])] = [
        (.preference, ["每天", "总是", "经常", "每次都", "习惯"]),
        (.goal, ["准备考", "打算考", "想要"]),
        (.phase, ["这学期", "目前"]),
        (.place, ["经常去", "常去"])
    ]

    public func extract(
        notes: [NoteRecord],
        replies: [FollowUpReplyRecord],
        context: MemoryExtractionContext
    ) throws -> [MemoryCandidate] {
        var result: [MemoryCandidate] = []
        var seen = Set<String>()

        func append(_ candidate: MemoryCandidate) {
            guard seen.insert(candidate.id).inserted else { return }
            result.append(candidate)
        }

        // 先笔记后回复，顺序固定：同一批输入每次产出的候选顺序一致，
        // 测试与界面预览都不会因为遍历顺序抖动。
        for note in notes where note.deletedAt == nil {
            let text = Self.noteText(note)
            for candidate in Self.candidates(
                in: text,
                origin: .note,
                originRecordId: note.id,
                context: context
            ) {
                append(candidate)
            }
        }

        for reply in replies {
            let text = Self.replyText(reply)
            guard !text.isEmpty else { continue }
            for candidate in Self.candidates(
                in: text,
                origin: .followUpReply,
                originRecordId: reply.id,
                context: context
            ) {
                append(candidate)
            }
        }

        return result
    }

    // MARK: - 文本来源

    /// 笔记：标题与正文一起进入抽取。标题里经常就是那句「我习惯…」。
    static func noteText(_ note: NoteRecord) -> String {
        [note.title, note.body].joined(separator: "\n")
    }

    /// 回复：用户写的字优先，没有字才用转写结果。
    static func replyText(_ reply: FollowUpReplyRecord) -> String {
        if let text = reply.text, !isBlank(text) { return text }
        if let transcript = reply.transcript, !isBlank(transcript) { return transcript }
        return ""
    }

    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 切句与规则

    /// 句子切分。
    ///
    /// 不切句的话一整段话只会命中第一条规则，一句话会被当成整篇笔记的记忆。
    /// 刻意不把 ASCII 句点当分隔符：版本号、小数、「3.5 号楼」都会被切坏。
    public static func sentences(in text: String) -> [String] {
        let separators: Set<Character> = ["\n", "。", "！", "？", "；", "!", "?", ";", "，", ","]
        var pieces: [String] = []
        var current = ""
        for character in text {
            if separators.contains(character) {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func candidates(
        in text: String,
        origin: MemoryCandidateOrigin,
        originRecordId: String,
        context: MemoryExtractionContext
    ) -> [MemoryCandidate] {
        let timestamp = RFC3339.utcString(from: context.now)
        var produced: [MemoryCandidate] = []

        for sentence in sentences(in: text) {
            if produced.count >= maxCandidatesPerRecord { break }

            // 显式表述优先：同一句话里既有「我习惯」又有「每天」时，
            // 它应当被记成用户原话，而不是被降级成推断。
            if let rule = explicitRules.first(where: { rule in
                rule.markers.contains { sentence.contains($0) }
            }) {
                produced.append(MemoryCandidate(
                    id: MemoryCandidate.stableId(
                        origin: origin,
                        originRecordId: originRecordId,
                        statement: sentence
                    ),
                    draft: MemoryDraft(
                        category: rule.category,
                        statement: sentence,
                        sourceKind: .userStatement
                    ),
                    origin: origin,
                    originRecordId: originRecordId,
                    evidenceText: String(sentence.prefix(80)),
                    extractedAt: timestamp
                ))
                continue
            }

            if let rule = inferredRules.first(where: { rule in
                rule.markers.contains { sentence.contains($0) }
            }) {
                produced.append(MemoryCandidate(
                    id: MemoryCandidate.stableId(
                        origin: origin,
                        originRecordId: originRecordId,
                        statement: sentence
                    ),
                    draft: MemoryDraft(
                        category: rule.category,
                        statement: sentence,
                        sourceKind: .inferred,
                        confidence: inferredConfidence
                    ),
                    origin: origin,
                    originRecordId: originRecordId,
                    evidenceText: String(sentence.prefix(80)),
                    extractedAt: timestamp
                ))
            }
        }

        return produced
    }
}

/// 抽取门面。
///
/// 把「未配置就不产出」这件事钉在唯一入口上：调用方只要走这里，
/// 就不可能拿到「没有配置却看起来成功」的空结果。
public struct MemoryExtraction: Sendable {

    public let provider: MemoryExtractionProvider

    public init(provider: MemoryExtractionProvider = UnconfiguredExtractor()) {
        self.provider = provider
    }

    public var isConfigured: Bool { provider.isConfigured }

    /// 抽取候选。未配置时抛 providerNotConfigured，**不返回空数组**。
    public func candidates(
        notes: [NoteRecord] = [],
        replies: [FollowUpReplyRecord] = [],
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone
    ) throws -> [MemoryCandidate] {
        guard provider.isConfigured else { throw MemoryExtractionError.providerNotConfigured }
        let context = MemoryExtractionContext(now: now, timeZone: timeZone)
        return try provider.extract(notes: notes, replies: replies, context: context)
    }
}
