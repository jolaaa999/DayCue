import Foundation
import XCTest
@testable import DayCueCore

/// 关键词检索测试。
///
/// 重点证明三件事：只有 confirmed 能当事实、有效期用传入的「现在」判断、
/// 没有配置向量索引时关键词检索照常返回结果。
final class MemorySearchTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    private let utcZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-memory-search-tests-" + UUID().uuidString
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = try DayCueStore(baseDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 辅助

    private func fixedDate(_ string: String) -> Date {
        guard let date = RFC3339.date(fromUTC: string) else {
            fatalError("测试用的固定时间写错了：\(string)")
        }
        return date
    }

    @discardableResult
    private func insert(
        _ id: String,
        _ statement: String,
        category: MemoryCategory = .preference,
        status: MemoryStatus = .confirmed,
        sourceKind: MemorySourceKind = .userStatement,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil,
        createdAt: String = "2026-10-12T09:00:00Z"
    ) throws -> MemoryItem {
        let item = MemoryItem(
            id: id,
            category: category,
            statement: statement,
            status: status,
            sourceKind: sourceKind,
            revision: 1,
            effectiveFrom: effectiveFrom,
            effectiveTo: effectiveTo,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try store.insertMemory(item, at: fixedDate("2026-10-12T09:00:00Z"))
        return item
    }

    /// 一个固定的向量索引替身：只在候选范围内返回预先给好的匹配。
    private struct FixedVectorIndex: MemoryVectorIndex {
        var matches: [MemoryVectorMatch] = []
        var isConfigured: Bool { true }
        func search(query: String, candidateIds: [String], limit: Int) throws -> [MemoryVectorMatch] {
            matches.filter { candidateIds.contains($0.memoryId) }
        }
    }

    /// 一个总是失败的向量索引替身：用来验证「增强能力挂掉不影响关键词检索」。
    private struct FailingVectorIndex: MemoryVectorIndex {
        struct Failure: Error {}
        var isConfigured: Bool { true }
        func search(query: String, candidateIds: [String], limit: Int) throws -> [MemoryVectorMatch] {
            throw Failure()
        }
    }

    // MARK: - 事实与参考

    func testOnlyConfirmedMemoriesAreReturnedAsFacts() throws {
        try insert("mem_fact", "我习惯在图书馆复习", status: .confirmed)
        try insert("mem_candidate", "图书馆三楼有一间自习室", status: .candidate, sourceKind: .inferred)
        try insert("mem_conflict", "图书馆周末不开放", status: .conflict)
        try insert("mem_retired", "图书馆周一闭馆", status: .retired)

        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "图书馆",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertEqual(Set(result.facts.map(\.id)), ["mem_fact"])
        XCTAssertEqual(
            Set(result.references.map(\.id)),
            ["mem_candidate", "mem_conflict", "mem_retired"]
        )
        XCTAssertTrue(result.facts.allSatisfy { $0.isUsableAsFact })
        XCTAssertTrue(result.references.allSatisfy { !$0.isUsableAsFact })
    }

    func testKeywordSearchReturnsResultsWithoutVectorIndex() throws {
        try insert("mem_confirmed", "我习惯在图书馆复习", status: .confirmed)
        try insert("mem_candidate", "图书馆三楼有一间自习室", status: .candidate, sourceKind: .inferred)

        // 默认就是「未配置向量索引」。
        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "图书馆",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertFalse(result.vectorIndexConfigured)
        XCTAssertFalse(result.isEmpty, "未配置向量索引时关键词检索必须照常返回结果，不报错、不返回空")
        XCTAssertEqual(result.keywordHitCount, 2)
        XCTAssertEqual(result.facts.map(\.id), ["mem_confirmed"])
        XCTAssertEqual(result.references.map(\.id), ["mem_candidate"])
        XCTAssertTrue(result.notes.contains { $0.contains("未配置向量检索") })
    }

    func testVectorIndexIsOptionalAndItsFailureDegradesGracefully() throws {
        try insert("mem_kw", "我习惯在图书馆复习")

        let engine = MemorySearchEngine(store: store, vectorIndex: FailingVectorIndex())
        let result = try engine.search(MemorySearchQuery(
            text: "图书馆",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertEqual(result.facts.map(\.id), ["mem_kw"], "向量检索报错不能把关键词结果也弄丢")
        XCTAssertTrue(result.notes.contains { $0.contains("向量检索暂时不可用") })
    }

    func testConfiguredVectorIndexAddsHitsInsideStructuredFilter() throws {
        try insert("mem_vector", "我习惯早起")
        try insert("mem_other", "我习惯晚睡")

        let index = FixedVectorIndex(matches: [
            MemoryVectorMatch(memoryId: "mem_vector", score: 0.9),
            // 不在候选里的 id（例如已被类别筛选掉）必须被忽略。
            MemoryVectorMatch(memoryId: "mem_not_candidate", score: 1.0)
        ])
        let engine = MemorySearchEngine(store: store, vectorIndex: index)
        let result = try engine.search(MemorySearchQuery(
            text: "咖啡",
            categories: [.preference],
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertTrue(result.vectorIndexConfigured)
        XCTAssertEqual(result.facts.map(\.id), ["mem_vector"])
        XCTAssertEqual(result.facts.first?.matchedByVector, true)
        XCTAssertEqual(result.facts.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    // MARK: - 结构化筛选

    func testEffectiveWindowUsesPassedNowNotExecutionDate() throws {
        try insert("mem_current", "这个学期在准备考研", effectiveFrom: "2026-09-01", effectiveTo: "2026-12-31")
        try insert("mem_future", "明年夏天要去交换", effectiveFrom: "2027-01-01")
        try insert("mem_past", "上学期在准备考研", effectiveTo: "2026-06-30")

        let engine = MemorySearchEngine(store: store)
        let now = try engine.search(MemorySearchQuery(
            text: "考研",
            now: fixedDate("2026-10-12T00:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertEqual(now.allHits.map(\.id), ["mem_current"], "只有有效期覆盖「现在」的记忆能被检索到")

        let later = try engine.search(MemorySearchQuery(
            text: "交换",
            now: fixedDate("2027-02-01T00:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertEqual(later.allHits.map(\.id), ["mem_future"], "同一个库换一个「现在」，结论必须跟着变")

        // 反过来：在 2026-10 的时候，未来的记忆还不可用。
        let beforeFuture = try engine.search(MemorySearchQuery(
            text: "交换",
            now: fixedDate("2026-10-12T00:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertTrue(beforeFuture.allHits.isEmpty)
    }

    func testCategoryAndStatusFilters() throws {
        try insert("mem_pref", "我喜欢在图书馆坐窗边", category: .preference, status: .confirmed)
        try insert("mem_goal", "图书馆闭馆前背完单词", category: .goal, status: .confirmed)
        try insert("mem_goal_candidate", "图书馆里可能有考研自习区", category: .goal, status: .candidate, sourceKind: .inferred)

        let engine = MemorySearchEngine(store: store)
        let goals = try engine.search(MemorySearchQuery(
            text: "图书馆",
            categories: [.goal],
            statuses: [.confirmed],
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertEqual(goals.facts.map(\.id), ["mem_goal"])
        XCTAssertTrue(goals.references.isEmpty)
    }

    func testEmptyQueryFallsBackToStructuredListing() throws {
        try insert("mem_one", "我喜欢跑步", createdAt: "2026-10-12T09:00:00Z")
        try insert("mem_two", "我习惯早起", createdAt: "2026-10-12T10:00:00Z")

        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "   ",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertEqual(result.allHits.count, 2)
        XCTAssertTrue(result.allHits.allSatisfy { $0.score == 0 })
        XCTAssertEqual(result.allHits.map(\.id), ["mem_two", "mem_one"], "空查询按创建时间倒序")
    }

    func testScoringPrefersMoreQueryTokenCoverage() throws {
        try insert("mem_full", "图书馆自习室很安静", createdAt: "2026-10-12T09:00:00Z")
        try insert("mem_partial", "图书馆", createdAt: "2026-10-12T10:00:00Z")

        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "图书馆自习室",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertEqual(result.facts.count, 2)
        XCTAssertEqual(result.facts.first?.id, "mem_full", "查询词覆盖更全的记忆排在前面")
        let full = try XCTUnwrap(result.facts.first(where: { $0.id == "mem_full" }))
        let partial = try XCTUnwrap(result.facts.first(where: { $0.id == "mem_partial" }))
        XCTAssertGreaterThan(full.score, partial.score)
        XCTAssertLessThanOrEqual(full.score, 1.0)
        XCTAssertGreaterThanOrEqual(full.score, 0)
    }

    func testDeletedMemoryIsNotReturnedEvenIfAnIndexRowSurvives() throws {
        try insert("mem_stale", "我习惯在图书馆复习")
        try store.softDeleteMemory(id: "mem_stale", at: fixedDate("2026-10-12T10:00:00Z"))

        // 人为把该记忆的全部索引词塞回去，模拟「清理漏了」这种最坏情况：
        // 这时倒排索引确实能命中，唯一挡住它的只能是「记忆已删除」这条规则。
        let insertStale = try store.database.prepare(
            "INSERT INTO memory_index (memory_id, token, weight) VALUES (?, ?, ?);"
        )
        for token in MemoryTokenizer.tokens(in: "我习惯在图书馆复习") {
            try insertStale.bind([.text("mem_stale"), .text(token), .real(1.0)])
            try insertStale.run()
        }
        XCTAssertGreaterThan(try store.indexedTokenCount(memoryId: "mem_stale"), 0)

        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "图书馆",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))

        XCTAssertTrue(result.allHits.isEmpty, "检索结果必须以未删除的记忆为准，不能只信倒排索引")
    }

    func testTokenizerProducesCJKBigramsAndSkipsStopwords() {
        let tokens = MemoryTokenizer.tokens(in: "我喜欢喝咖啡")
        XCTAssertTrue(tokens.contains("咖啡"))
        XCTAssertTrue(tokens.contains("喜欢"))
        XCTAssertFalse(tokens.contains("我"), "常见虚词不进索引")
        XCTAssertTrue(MemoryTokenizer.tokens(in: "PV 操作").contains("pv"))
    }
}
