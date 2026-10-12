import Foundation

// 记忆 -> 助手回答。
//
// 三条前提写进类型而不是只写在文档里：
// 1. 回答必须有依据：只有 confirmed 的记忆才能被当作事实引用，候选/冲突只能提示。
// 2. 没有任何可用记忆时必须如实说「没有相关记忆」，**不得编造**；
//    这条底线不外包给可注入的 composer —— 一条事实都没有时根本不调用它。
// 3. 回答必须带引用（记忆 id + 来源 + 状态），用户能自己核对这句话是从哪来的。

/// 回答里引用到的一条记忆。
///
/// 把 status/sourceKind 一起带给界面，而不是只给一句正文：
/// 用户要能自己判断「这是我自己说过被确认的」还是「这只是推断」。
public struct MemoryCitation: Equatable, Sendable, Identifiable {

    public var memoryId: String
    public var statement: String
    public var category: MemoryCategory
    public var sourceKind: MemorySourceKind
    public var status: MemoryStatus
    public var score: Double
    /// 只来自 MemoryStatus.isUsableAsFact，界面不允许另起一套判断。
    public var isUsableAsFact: Bool

    public var id: String { memoryId }

    public init(
        memoryId: String,
        statement: String,
        category: MemoryCategory,
        sourceKind: MemorySourceKind,
        status: MemoryStatus,
        score: Double,
        isUsableAsFact: Bool
    ) {
        self.memoryId = memoryId
        self.statement = statement
        self.category = category
        self.sourceKind = sourceKind
        self.status = status
        self.score = score
        self.isUsableAsFact = isUsableAsFact
    }

    public init(hit: MemorySearchHit) {
        self.memoryId = hit.item.id
        self.statement = hit.item.statement
        self.category = hit.item.category
        self.sourceKind = hit.item.sourceKind
        self.status = hit.item.status
        self.score = hit.score
        self.isUsableAsFact = hit.item.status.isUsableAsFact
    }
}

/// 回答正文生成器。
///
/// 定义成协议是为了让「措辞」可替换（接入模型改写、多语言、个性化语气），
/// 而「有没有依据、能不能编」这条规则仍然留在检索器那一层，换措辞换不掉底线。
public protocol MemoryAnswerComposer: Sendable {
    func compose(question: String, citations: [MemoryCitation]) -> String
}

/// 确定性拼接：本机没有真实模型时的默认实现。
public struct RuleBasedAnswerComposer: MemoryAnswerComposer {

    public init() {}

    public func compose(question: String, citations: [MemoryCitation]) -> String {
        guard !citations.isEmpty else {
            return MemoryGroundedAnswer.noMemoryAnswer(referenceCount: 0)
        }

        // 逐条带上来源与状态：把候选混进事实里，用户就会以为它已经被确认过了。
        var lines: [String] = []
        for citation in citations {
            let source = citation.sourceKind.displayName
            if citation.isUsableAsFact {
                lines.append("- \(citation.statement)（来源：\(source)）")
            } else {
                lines.append("- \(citation.statement)（\(citation.status.displayName)，来源：\(source)，仅供参考）")
            }
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmedQuestion.isEmpty
            ? "根据已确认的记忆："
            : "关于「\(trimmedQuestion)」，已确认的记忆是："
        return prefix + "\n" + lines.joined(separator: "\n")
    }
}

/// 一条有依据的回答。
public struct MemoryGroundedAnswer: Equatable, Sendable {

    public var question: String
    public var text: String
    /// 被当作事实引用的记忆。这里每一条都满足 MemoryStatus.isUsableAsFact。
    public var citations: [MemoryCitation]
    /// 检索到、但不能当事实用的记忆（候选/冲突）。只提示，不引用。
    public var references: [MemoryCitation]
    /// 检索器的降级说明（例如未配置向量检索），如实透给界面。
    public var notes: [String]

    public var citedMemoryIds: [String] { citations.map(\.memoryId) }
    public var isGrounded: Bool { !citations.isEmpty }

    public init(
        question: String,
        text: String,
        citations: [MemoryCitation] = [],
        references: [MemoryCitation] = [],
        notes: [String] = []
    ) {
        self.question = question
        self.text = text
        self.citations = citations
        self.references = references
        self.notes = notes
    }

    /// 没有任何可当事实用的记忆时的固定回答。
    ///
    /// 候选只提示数量、不引用内容：用户还没确认过的东西不能被助手说成「我记得」。
    public static func noMemoryAnswer(referenceCount: Int) -> String {
        if referenceCount > 0 {
            return "没有相关记忆可以当作事实回答你。还有 \(referenceCount) 条候选记忆没有确认，确认之后我才会用它们回答。"
        }
        return "没有相关记忆。我不会凭猜测回答。"
    }
}

/// 检索 + 组织回答。
///
/// 单独成一个类型而不是往检索器里塞：检索器负责「找到什么」，
/// 这里负责「怎么据实回答」，两件事的测试关注点完全不同。
public struct MemoryGroundedAnswerer {

    public let engine: MemorySearchEngine
    public let composer: MemoryAnswerComposer

    public init(
        engine: MemorySearchEngine,
        composer: MemoryAnswerComposer = RuleBasedAnswerComposer()
    ) {
        self.engine = engine
        self.composer = composer
    }

    /// 这里**真的调用检索**，而不是拿调用方传来的现成条目：
    /// 检索里的类别/状态/有效期筛选必须每一问都重新走一遍。
    public func answer(
        question: String,
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone,
        limit: Int = 5
    ) throws -> MemoryGroundedAnswer {
        let result = try engine.search(MemorySearchQuery(
            text: question,
            now: now,
            timeZone: timeZone,
            limit: limit
        ))

        let citations = result.facts.map(MemoryCitation.init(hit:))
        let references = result.references.map(MemoryCitation.init(hit:))

        // 没有任何可用事实时**不调用 composer**：
        // 「没有依据就不许编」是产品底线，不能外包给一个可替换的实现。
        let text: String
        if citations.isEmpty {
            text = MemoryGroundedAnswer.noMemoryAnswer(referenceCount: references.count)
        } else {
            text = composer.compose(question: question, citations: citations)
        }

        return MemoryGroundedAnswer(
            question: question,
            text: text,
            citations: citations,
            references: references,
            notes: result.notes
        )
    }
}
