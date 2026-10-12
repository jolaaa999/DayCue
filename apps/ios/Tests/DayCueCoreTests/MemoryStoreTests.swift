import Foundation
import XCTest
@testable import DayCueCore

/// 记忆仓储测试。
///
/// 全部时间都显式传入（fixedDate 里的固定字符串），不依赖执行日期——
/// 否则这类测试会在某一天突然变红，而且没人知道为什么。
final class MemoryStoreTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    /// 固定时区，避免测试跟着机器时区漂。
    private let utcZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-memory-tests-" + UUID().uuidString
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

    /// 固定时刻。写错字符串就直接失败，避免测试悄悄用「现在」。
    private func fixedDate(_ string: String) -> Date {
        guard let date = RFC3339.date(fromUTC: string) else {
            fatalError("测试用的固定时间写错了：\(string)")
        }
        return date
    }

    private func makeMemory(
        id: String = DayCueID.new(),
        category: MemoryCategory = .preference,
        statement: String = "我习惯在图书馆复习",
        status: MemoryStatus = .confirmed,
        sourceKind: MemorySourceKind = .userStatement,
        confidence: Double? = nil,
        sourceRef: String? = nil,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil,
        createdAt: String,
        updatedAt: String? = nil,
        deletedAt: String? = nil
    ) -> MemoryItem {
        // revision 固定为 1：插入时的首版由仓储负责，这里不用传。
        MemoryItem(
            id: id,
            category: category,
            statement: statement,
            status: status,
            sourceKind: sourceKind,
            confidence: confidence,
            sourceRef: sourceRef,
            revision: 1,
            effectiveFrom: effectiveFrom,
            effectiveTo: effectiveTo,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt,
            deletedAt: deletedAt
        )
    }

    // MARK: - 删除与索引

    func testSoftDeleteClearsInvertedIndexInSameTransaction() throws {
        try store.insertMemory(
            makeMemory(id: "mem_index", statement: "我习惯在图书馆复习", createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )
        XCTAssertGreaterThan(try store.indexedTokenCount(memoryId: "mem_index"), 0, "插入记忆时必须同时建倒排索引")

        try store.softDeleteMemory(id: "mem_index", at: fixedDate("2026-10-12T10:00:00Z"))

        XCTAssertNil(try store.memory(id: "mem_index"), "软删除后不允许再按 id 取回")
        XCTAssertEqual(
            try store.indexedTokenCount(memoryId: "mem_index"),
            0,
            "删除必须在同一事务里清掉 memory_index，否则已删除的记忆还会被检索到"
        )

        // 直接查表再确认一次，不看封装方法的脸色。
        let rawCount = try store.database.prepare("SELECT COUNT(*) FROM memory_index WHERE memory_id = ?;")
        try rawCount.bind([.text("mem_index")])
        XCTAssertTrue(try rawCount.step())
        XCTAssertEqual(rawCount.int(0), 0)

        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "图书馆",
            now: fixedDate("2026-10-12T11:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertTrue(result.allHits.isEmpty, "已删除的记忆不能出现在检索结果里")
    }

    func testClearAllMemoriesSoftDeletesAndEmptiesIndex() throws {
        try store.insertMemory(
            makeMemory(id: "mem_a", statement: "我喜欢跑步", createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )
        try store.insertMemory(
            makeMemory(id: "mem_b", statement: "我住在东区宿舍", createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )

        let removed = try store.clearAllMemories(at: fixedDate("2026-10-12T10:00:00Z"))

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try store.memoryCount(), 0)
        XCTAssertEqual(try store.memoryCount(includeDeleted: true), 2, "清除是软删除：行还在，只是不再可见")
        XCTAssertEqual(try store.indexedTokenCount(memoryId: "mem_a"), 0)
        XCTAssertEqual(try store.indexedTokenCount(memoryId: "mem_b"), 0)
        XCTAssertEqual(try store.reindexAllMemories(), 0, "已删除的记忆不应该被重新索引")
    }

    func testReindexRebuildsTokensFromCurrentStatement() throws {
        try store.insertMemory(
            makeMemory(id: "mem_reindex", statement: "我早上七点起床", createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )
        // 人为把索引删掉，模拟「索引损坏」。
        try store.deleteMemoryIndexTokens(memoryId: "mem_reindex")
        XCTAssertEqual(try store.indexedTokenCount(memoryId: "mem_reindex"), 0)

        let rebuilt = try store.reindexMemory(id: "mem_reindex")

        XCTAssertGreaterThan(rebuilt, 0)
        XCTAssertEqual(try store.indexedTokenCount(memoryId: "mem_reindex"), rebuilt)

        let engine = MemorySearchEngine(store: store)
        let result = try engine.search(MemorySearchQuery(
            text: "起床",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertEqual(result.facts.map(\.id), ["mem_reindex"])
    }

    // MARK: - 修订历史

    func testUpdateStatementWritesNewRevisionAndKeepsHistory() throws {
        try store.insertMemory(
            makeMemory(id: "mem_rev", statement: "我喜欢喝咖啡", createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )

        _ = try store.updateMemoryStatement(
            id: "mem_rev",
            statement: "我改喝无咖啡因的咖啡了",
            at: fixedDate("2026-10-12T10:00:00Z")
        )
        let updated = try store.updateMemoryStatement(
            id: "mem_rev",
            statement: "我现在只喝手冲",
            at: fixedDate("2026-10-12T11:00:00Z")
        )

        XCTAssertEqual(updated.revision, 3, "每次改说法都要递增版本号")
        XCTAssertEqual(updated.statement, "我现在只喝手冲")

        let revisions = try store.revisions(memoryId: "mem_rev")
        XCTAssertEqual(revisions.map(\.revision), [1, 2, 3])
        XCTAssertEqual(revisions[0].statement, "我喜欢喝咖啡", "旧说法必须原样保留")
        XCTAssertEqual(revisions[1].statement, "我改喝无咖啡因的咖啡了")
        XCTAssertEqual(revisions[2].statement, "我现在只喝手冲")
        XCTAssertEqual(revisions[2].createdAt, "2026-10-12T11:00:00Z")
        XCTAssertEqual(try store.latestRevision(memoryId: "mem_rev")?.revision, 3)

        // 索引跟着新说法走：换了说法之后旧词不应该继续命中。
        let engine = MemorySearchEngine(store: store)
        let old = try engine.search(MemorySearchQuery(
            text: "无咖啡因",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertTrue(old.allHits.isEmpty, "旧说法的词不能继续命中")
        let current = try engine.search(MemorySearchQuery(
            text: "手冲",
            now: fixedDate("2026-10-12T12:00:00Z"),
            timeZone: utcZone
        ))
        XCTAssertEqual(current.facts.map(\.id), ["mem_rev"])
    }

    func testRevisionHistorySurvivesSoftDeleteAndUpdateRefusesDeletedMemory() throws {
        try store.insertMemory(
            makeMemory(id: "mem_hist", statement: "第一版说法", createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )
        _ = try store.updateMemoryStatement(
            id: "mem_hist",
            statement: "第二版说法",
            at: fixedDate("2026-10-12T10:00:00Z")
        )
        try store.softDeleteMemory(id: "mem_hist", at: fixedDate("2026-10-12T11:00:00Z"))

        XCTAssertEqual(
            try store.revisions(memoryId: "mem_hist").map(\.statement),
            ["第一版说法", "第二版说法"],
            "删除记忆不删除历史修订"
        )
        XCTAssertNil(try store.memory(id: "mem_hist"))

        XCTAssertThrowsError(try store.updateMemoryStatement(
            id: "mem_hist",
            statement: "第三版",
            at: fixedDate("2026-10-12T12:00:00Z")
        )) { error in
            XCTAssertEqual(error as? MemoryStoreError, .memoryNotFound("mem_hist"))
        }
    }

    func testSetMemoryStatusMirrorsLatestRevision() throws {
        try store.insertMemory(
            makeMemory(
                id: "mem_status",
                statement: "我可能在准备考研",
                status: .candidate,
                sourceKind: .inferred,
                createdAt: "2026-10-12T09:00:00Z"
            ),
            at: fixedDate("2026-10-12T09:00:00Z")
        )

        try store.setMemoryStatus(id: "mem_status", status: .confirmed, at: fixedDate("2026-10-12T10:00:00Z"))

        let loaded = try XCTUnwrap(try store.memory(id: "mem_status"))
        XCTAssertEqual(loaded.status, .confirmed)
        XCTAssertTrue(loaded.status.isUsableAsFact)
        XCTAssertEqual(try store.latestRevision(memoryId: "mem_status")?.status, .confirmed, "最新修订的状态要同步镜像")

        XCTAssertThrowsError(try store.setMemoryStatus(id: "mem_missing", status: .confirmed)) { error in
            XCTAssertEqual(error as? MemoryStoreError, .memoryNotFound("mem_missing"))
        }
    }

    // MARK: - 候选策略

    func testInferredMemoryNeverBecomesConfirmed() throws {
        let inferred = MemoryDraft(
            category: .preference,
            statement: "你可能喜欢喝咖啡",
            sourceKind: .inferred,
            confidence: 0.4
        )
        let admission = MemoryCandidatePolicy.admit(inferred)
        XCTAssertEqual(admission.status, .candidate)
        XCTAssertTrue(admission.requiresUserConfirmation)

        let item = MemoryCandidatePolicy.makeItem(
            inferred,
            admission: admission,
            id: "mem_inferred",
            createdAt: "2026-10-12T09:00:00Z"
        )
        try store.insertMemory(item, at: fixedDate("2026-10-12T09:00:00Z"))

        let loaded = try XCTUnwrap(try store.memory(id: "mem_inferred"))
        XCTAssertEqual(loaded.status, .candidate)
        XCTAssertFalse(loaded.status.isUsableAsFact, "候选不能当事实用")
        XCTAssertEqual(loaded.sourceKind, .inferred)

        // 即使同类里已有别的说法，推断也只能停在候选。
        let conflictingInference = MemoryDraft(
            category: .preference,
            statement: "你不喜欢喝咖啡",
            sourceKind: .inferred
        )
        XCTAssertEqual(
            MemoryCandidatePolicy.admit(conflictingInference, among: [loaded]).status,
            .candidate
        )
    }

    func testUserAssertedConflictIsMarkedInsteadOfOverwriting() throws {
        try store.insertMemory(
            makeMemory(id: "mem_fact", statement: "我喜欢喝咖啡", status: .confirmed, sourceKind: .userStatement, createdAt: "2026-10-12T09:00:00Z"),
            at: fixedDate("2026-10-12T09:00:00Z")
        )
        let existing = try XCTUnwrap(try store.memory(id: "mem_fact"))

        let conflictDraft = MemoryDraft(
            category: .preference,
            statement: "我不喜欢喝咖啡",
            sourceKind: .userStatement
        )
        let admission = MemoryCandidatePolicy.admit(conflictDraft, among: [existing])

        XCTAssertEqual(admission.status, .conflict, "互斥说法落 conflict，交用户处理")
        XCTAssertEqual(admission.conflictingMemoryIds, ["mem_fact"])

        // 用户设置可以直接确认。
        let settingDraft = MemoryDraft(category: .goal, statement: "我这个学期要过六级", sourceKind: .userSetting)
        XCTAssertEqual(MemoryCandidatePolicy.admit(settingDraft, among: [existing]).status, .confirmed)
    }

    func testSingleValuedCategoryConflictIsDetectedWithoutNegation() throws {
        // 「阶段状态」只可能有一个当前值，所以同类别里的第二种说法本身就是冲突，
        // 不依赖否定词检测。
        let existing = MemoryItem(
            id: "mem_phase",
            category: .phase,
            statement: "我这个学期大三",
            status: .confirmed,
            sourceKind: .userStatement,
            createdAt: "2026-10-12T09:00:00Z",
            updatedAt: "2026-10-12T09:00:00Z"
        )
        let draft = MemoryDraft(category: .phase, statement: "我这个学期大四", sourceKind: .userStatement)
        XCTAssertEqual(MemoryCandidatePolicy.admit(draft, among: [existing]).status, .conflict)

        // 不同类别不互相冲突。
        let otherCategory = MemoryDraft(category: .person, statement: "我这个学期大四", sourceKind: .userStatement)
        XCTAssertEqual(MemoryCandidatePolicy.admit(otherCategory, among: [existing]).status, .confirmed)
    }

    // MARK: - 记录开关

    func testRecordingControlDefaultsEnabledAndIsPerCategory() throws {
        XCTAssertTrue(try store.isRecordingEnabled(category: .person), "没设置过就是允许记录")

        try store.setRecordingEnabled(category: .person, enabled: false, at: fixedDate("2026-10-12T09:00:00Z"))

        XCTAssertFalse(try store.isRecordingEnabled(category: .person))
        XCTAssertTrue(try store.isRecordingEnabled(category: .goal), "关掉一类不影响其它类别")

        let snapshot = try store.recordingControlSnapshot()
        XCTAssertEqual(snapshot.count, MemoryCategory.allCases.count)
        XCTAssertEqual(snapshot[.person], false)
        XCTAssertEqual(snapshot[.goal], true)
    }
}
