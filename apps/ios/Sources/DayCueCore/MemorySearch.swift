import Foundation

// 记忆检索。
//
// 三条产品前提，写进类型而不是只写在文档里：
// 1. 只有 MemoryStatus.isUsableAsFact（== .confirmed）才能作为**事实**返回；
//    candidate / conflict / retired 只能作为「参考」返回，并且必须带着状态让人看见。
// 2. 关键词检索完全本地、离线可用：memory_index 倒排 + 简单可解释的打分，不依赖任何向量服务。
// 3. 向量检索只是**可选增强**：适配器未配置时关键词结果照常返回，不报错、不返回空。

/// 关键词切分。
///
/// 中文没有空格，所以这里按字符类别切：连续 CJK 段落产出「单字 + 相邻二元组」，
/// 连续 ASCII 字母数字产出整个词。选二元组而不是词典分词，是因为分词器需要词典和版本升级，
/// 而二元组规则简单、结果确定、离线可用，召回也够。
public enum MemoryTokenizer {

    /// 中文停用词。单字命中噪音太大，先用一份很小的表压住最常见的虚词。
    /// 刻意不放「不 / 没 / 未」：它们承载否定语义，交给冲突检测而不是检索过滤。
    public static let stopwords: Set<String> = [
        "的", "了", "是", "在", "有", "和", "与", "我", "你", "他", "她", "它",
        "们", "就", "都", "也", "很", "会", "要", "这", "那", "个", "吗", "呢",
        "吧", "啊", "呀", "及", "或", "把", "被", "给", "对", "从", "到", "而"
    ]

    public static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 切成检索词，按首次出现顺序去重。
    public static func tokens(in text: String) -> [String] {
        let raw = normalized(text)
        var result: [String] = []
        var seen = Set<String>()

        func append(_ token: String) {
            guard !token.isEmpty, !stopwords.contains(token) else { return }
            guard seen.insert(token).inserted else { return }
            result.append(token)
        }

        var cjkRun: [Character] = []
        var asciiRun = ""

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count == 1 {
                append(String(cjkRun[0]))
            } else {
                for character in cjkRun { append(String(character)) }
                for index in 0..<(cjkRun.count - 1) {
                    append(String(cjkRun[index]) + String(cjkRun[index + 1]))
                }
            }
            cjkRun.removeAll()
        }

        func flushASCII() {
            // 单个 ASCII 字符（例如 "a"）信息量太低，直接丢掉；两个以上才当作词。
            if asciiRun.count >= 2 { append(asciiRun) }
            asciiRun = ""
        }

        for character in raw {
            if isCJK(character) {
                flushASCII()
                cjkRun.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                asciiRun.append(character)
            } else {
                flushCJK()
                flushASCII()
            }
        }
        flushCJK()
        flushASCII()
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

/// 有效期的解析。
///
/// 「到某天为止」在中文语义里是**包含当天**的，所以纯日期形式的 effective_to
/// 要补到当天 23:59:59，而不是当天 00:00——否则用户写的「有效到 10-16」会在 10-16 当天就失效。
public enum MemoryEffectiveWindow {

    /// 纯日期（YYYY-MM-DD）按给定时区的当天 00:00 解析；isEndBoundary 为 true 时落到当天末尾。
    /// 带时刻的按 UTC 解析。解析不出来返回 nil，调用方改用字符串比较兜底。
    public static func boundary(_ raw: String, timeZone: TimeZone, isEndBoundary: Bool = false) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 10 {
            guard let start = RFC3339.date(fromLocal: trimmed + "T00:00:00", timeZone: timeZone) else {
                return nil
            }
            return isEndBoundary ? start.addingTimeInterval(86_399) : start
        }
        return RFC3339.date(fromUTC: trimmed)
    }
}

/// 一条检索命中。
public struct MemorySearchHit: Equatable, Sendable, Identifiable {

    public var item: MemoryItem
    /// 0...1 的分数。空查询时的纯结构化筛选一律为 0。
    public var score: Double
    public var matchedTokens: [String]
    public var matchedByVector: Bool

    public var id: String { item.id }

    /// 能不能当事实用。这个值只来自 MemoryStatus.isUsableAsFact，界面不允许另起一套判断。
    public var isUsableAsFact: Bool { item.status.isUsableAsFact }

    public init(item: MemoryItem, score: Double, matchedTokens: [String], matchedByVector: Bool) {
        self.item = item
        self.score = score
        self.matchedTokens = matchedTokens
        self.matchedByVector = matchedByVector
    }
}

public struct MemorySearchQuery: Equatable, Sendable {

    public var text: String
    /// nil 表示不按类别筛选。
    public var categories: Set<MemoryCategory>?
    /// nil 表示不按状态筛选。
    public var statuses: Set<MemoryStatus>?
    /// 显式传入的「现在」。检索器不读系统时钟，测试与后台任务才能得到确定结果。
    public var now: Date
    public var timeZone: TimeZone
    public var limit: Int

    public init(
        text: String = "",
        categories: Set<MemoryCategory>? = nil,
        statuses: Set<MemoryStatus>? = nil,
        now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone,
        limit: Int = 50
    ) {
        self.text = text
        self.categories = categories
        self.statuses = statuses
        self.now = now
        self.timeZone = timeZone
        self.limit = limit
    }
}

public struct MemorySearchResult: Equatable, Sendable {

    /// 只有 confirmed 才会出现在这里。
    public var facts: [MemorySearchHit]
    /// 候选 / 冲突 / 已失效。可以展示给用户看，但**不能**当作事实引用。
    public var references: [MemorySearchHit]
    public var keywordHitCount: Int
    public var vectorIndexConfigured: Bool
    /// 降级说明。未配置向量、向量报错都会写在这里，而不是抛错。
    public var notes: [String]

    public var allHits: [MemorySearchHit] { facts + references }
    public var isEmpty: Bool { facts.isEmpty && references.isEmpty }

    public init(
        facts: [MemorySearchHit] = [],
        references: [MemorySearchHit] = [],
        keywordHitCount: Int = 0,
        vectorIndexConfigured: Bool = false,
        notes: [String] = []
    ) {
        self.facts = facts
        self.references = references
        self.keywordHitCount = keywordHitCount
        self.vectorIndexConfigured = vectorIndexConfigured
        self.notes = notes
    }
}

/// 向量检索适配器。
///
/// 定义成协议而不是直接依赖某个向量库：DayCue 的默认形态是「没有向量服务也能用」，
/// 以后接入本地 embedding 也只是换一个实现，不动检索主流程。
public struct MemoryVectorMatch: Equatable, Sendable {
    public var memoryId: String
    public var score: Double

    public init(memoryId: String, score: Double) {
        self.memoryId = memoryId
        self.score = score
    }
}

public protocol MemoryVectorIndex: Sendable {
    /// 未配置时必须是 false。检索主流程据此决定要不要调用 search。
    var isConfigured: Bool { get }
    /// candidateIds 已经过结构化筛选，实现方只需要在候选内排序，不需要自己再读库。
    func search(query: String, candidateIds: [String], limit: Int) throws -> [MemoryVectorMatch]
}

/// 默认实现：没有配置向量检索。
///
/// 它的存在就是产品承诺本身——未配置时关键词检索照常返回结果，
/// 不报错、不返回空，也绝不假装自己有语义理解能力。
public struct UnconfiguredMemoryVectorIndex: MemoryVectorIndex {

    public init() {}

    public var isConfigured: Bool { false }

    public func search(query: String, candidateIds: [String], limit: Int) throws -> [MemoryVectorMatch] {
        []
    }
}

/// 检索器。
///
/// 单独做成一个类型而不是往 DayCueStore 上再挂方法：检索是「读 + 打分 + 合并」，
/// 与按表写入的仓储职责不同，分开之后测试可以直接注入假的向量索引。
public struct MemorySearchEngine {

    /// 默认 UTC。不取系统时区，保证同一份数据在任何设备、任何 CI 上得到同一结论。
    public static let defaultTimeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

    public let store: DayCueStore
    public let vectorIndex: MemoryVectorIndex

    public init(store: DayCueStore, vectorIndex: MemoryVectorIndex = UnconfiguredMemoryVectorIndex()) {
        self.store = store
        self.vectorIndex = vectorIndex
    }

    /// 只返回可当事实使用的命中。
    public func searchFacts(_ query: MemorySearchQuery) throws -> [MemorySearchHit] {
        try search(query).facts
    }

    public func search(_ query: MemorySearchQuery) throws -> MemorySearchResult {
        // 全量取回再由纯逻辑筛选：记忆是「用户手工确认过的小集合」，
        // 量级远小于捕获与任务，换取的是筛选规则只有一处实现，SQL 与逻辑不会各说各话。
        let all = try store.memories(includeDeleted: false, limit: 5000)
        let filtered = all.filter { item in
            if let categories = query.categories, !categories.contains(item.category) { return false }
            if let statuses = query.statuses, !statuses.contains(item.status) { return false }
            return MemorySearchEngine.isEffective(item, at: query.now, timeZone: query.timeZone)
        }

        let keywordTokens = MemoryTokenizer.tokens(in: query.text)
        var hits: [String: MemorySearchHit] = [:]
        var notes: [String] = []

        if keywordTokens.isEmpty {
            // 空查询等于「纯结构化筛选」：按创建时间倒序给全量，不打分。
            for item in filtered.sorted(by: MemorySearchEngine.recencyOrder) {
                hits[item.id] = MemorySearchHit(item: item, score: 0, matchedTokens: [], matchedByVector: false)
            }
        } else {
            let scores = try keywordScores(tokens: keywordTokens)
            for item in filtered {
                guard let entry = scores[item.id] else { continue }
                hits[item.id] = MemorySearchHit(
                    item: item,
                    score: min(max(entry.score, 0), 1),
                    matchedTokens: entry.matchedTokens,
                    matchedByVector: false
                )
            }
        }

        let keywordHitCount = hits.count

        if vectorIndex.isConfigured, !keywordTokens.isEmpty {
            let candidateIds = filtered.map(\.id)
            do {
                let matches = try vectorIndex.search(
                    query: query.text,
                    candidateIds: candidateIds,
                    limit: max(query.limit, 1)
                )
                for match in matches {
                    // 向量命中也必须落在结构化筛选后的集合里：向量库不许绕开类别、状态与有效期。
                    guard let item = filtered.first(where: { $0.id == match.memoryId }) else { continue }
                    let clamped = min(max(match.score, 0), 1)
                    if var existing = hits[item.id] {
                        existing.score = min(1, existing.score + clamped)
                        existing.matchedByVector = true
                        hits[item.id] = existing
                    } else {
                        hits[item.id] = MemorySearchHit(
                            item: item,
                            score: clamped,
                            matchedTokens: [],
                            matchedByVector: true
                        )
                    }
                }
            } catch {
                // 向量检索失败必须降级成「只用关键词」，而不是让整个检索失败。
                notes.append("向量检索暂时不可用，本次结果全部来自本机关键词索引：\(error)")
            }
        } else if !vectorIndex.isConfigured {
            notes.append("未配置向量检索，本次结果全部来自本机关键词索引。")
        }

        let ordered = Array(hits.values.sorted(by: MemorySearchEngine.hitOrder).prefix(max(query.limit, 0)))
        return MemorySearchResult(
            facts: ordered.filter { $0.item.status.isUsableAsFact },
            references: ordered.filter { !$0.item.status.isUsableAsFact },
            keywordHitCount: keywordHitCount,
            vectorIndexConfigured: vectorIndex.isConfigured,
            notes: notes
        )
    }

    // MARK: - 有效性

    /// 判断一条记忆在传入的「现在」是否处于有效期。
    ///
    /// effective_from 晚于 now 表示「还没生效」，effective_to 早于 now 表示「已经失效」，
    /// 两者都是排除条件。日期串解析不出来时退回字符串比较，绝不因为解析失败就把过期的记忆当有效。
    public static func isEffective(
        _ item: MemoryItem,
        at now: Date,
        timeZone: TimeZone = MemorySearchEngine.defaultTimeZone
    ) -> Bool {
        if let from = nonEmpty(item.effectiveFrom) {
            if let start = MemoryEffectiveWindow.boundary(from, timeZone: timeZone) {
                if start > now { return false }
            } else if from > RFC3339.utcString(from: now) {
                return false
            }
        }
        if let to = nonEmpty(item.effectiveTo) {
            if let end = MemoryEffectiveWindow.boundary(to, timeZone: timeZone, isEndBoundary: true) {
                if end < now { return false }
            } else if to < RFC3339.utcString(from: now) {
                return false
            }
        }
        return true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    // MARK: - 打分

    private struct IndexEntry {
        var score: Double
        var matchedTokens: [String]
    }

    /// 基于 memory_index 的打分。
    ///
    /// 分数 = 命中词的权重之和 / 查询词总数，落在 0...1，含义就是「查询词被覆盖了几成」。
    /// 没被索引命中的记忆直接不返回，不做模糊兜底——宁可少给，也不要给用户看一条不相关的记忆。
    ///
    /// 声明为 private：它返回下标实现细节 IndexEntry，不能出现在对外接口里。
    private func keywordScores(tokens: [String]) throws -> [String: IndexEntry] {
        guard !tokens.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: tokens.count).joined(separator: ", ")
        let statement = try store.database.prepare(
            "SELECT memory_id, token, weight FROM memory_index WHERE token IN (\(placeholders));"
        )
        try statement.bind(tokens.map { .text($0) })

        var perMemory: [String: (weight: Double, matched: [String])] = [:]
        while try statement.step() {
            let memoryId = statement.string(0) ?? ""
            let token = statement.string(1) ?? ""
            var current = perMemory[memoryId] ?? (weight: 0, matched: [])
            current.weight += statement.double(2)
            current.matched.append(token)
            perMemory[memoryId] = current
        }

        let divisor = Double(tokens.count)
        var result: [String: IndexEntry] = [:]
        for (memoryId, value) in perMemory {
            result[memoryId] = IndexEntry(
                score: divisor > 0 ? value.weight / divisor : 0,
                matchedTokens: value.matched.sorted()
            )
        }
        return result
    }

    // MARK: - 排序

    static func recencyOrder(_ lhs: MemoryItem, _ rhs: MemoryItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    static func hitOrder(_ lhs: MemorySearchHit, _ rhs: MemorySearchHit) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        // 同分时事实排在参考前面：界面默认展示的就是「你能当真的那些」。
        if lhs.isUsableAsFact != rhs.isUsableAsFact { return lhs.isUsableAsFact }
        if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt > rhs.item.createdAt }
        return lhs.item.id < rhs.item.id
    }
}
