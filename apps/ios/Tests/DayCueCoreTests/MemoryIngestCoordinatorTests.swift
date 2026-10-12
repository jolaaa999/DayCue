import Foundation
import XCTest
@testable import DayCueCore

/// 记忆链路端到端测试：抽取 -> 开关 -> 去重与冲突 -> 候选落库 -> 用户确认 -> 检索回答。
///
/// 所有时间基准都显式传入（fixedDate），不读系统时钟；库建在临时目录里，用例之间互不影响。
/// 状态声明：本文件**已编写、未运行**（当前机器没有 Swift 工具链）。
final class MemoryIngestCoordinatorTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    private let base = "2026-10-12T09:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-memory-ingest-tests-" + UUID().uuidString
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

    private func makeCoordinator(
        provider: MemoryExtractionProvider = DefaultRuleBasedExtractor()
    ) -> MemoryIngestCoordinator {
        MemoryIngestCoordinator(store: store, extraction: MemoryExtraction(provider: provider))
    }

    private func makeNote(
        id: String = DayCueID.new(),
        title: String = "",
        body: String
    ) -> NoteRecord {
        NoteRecord(
            id: id,
            title: title,
            body: body,
            tags: [],
            originKind: .manual,
            createdAt: base,
            updatedAt: base
        )
    }

    private func makeReply(
        id: String = DayCueID.new(),
        text: String
    ) -> FollowUpReplyRecord {
        FollowUpReplyRecord(
            id: id,
            followUpId: "fu_1",
            courseId: "course_1",
            kind: .text,
            text: text,
            createdAt: base
        )
    }

    /// 只在有事实时才会被调用的 composer，用来证明「没有依据时不会走到它」。
    private struct FixedComposer: MemoryAnswerComposer {
        func compose(question: String, citations: [MemoryCitation]) -> String {
            "自定义回答：" + citations.map(\.memoryId).joined(separator: ",")
        }
    }

    // MARK: - 未配置

    func testUnconfiguredExtractorThrowsAndWritesNothing() throws {
        let coordinator = makeCoordinator(provider: UnconfiguredExtractor())
        let note = makeNote(body: "我习惯晚上学习")

        XCTAssertThrowsError(try coordinator.ingest(notes: [note], now: fixedDate(base))) { error in
            XCTAssertEqual(error as? MemoryExtractionError, .providerNotConfigured)
        }

        XCTAssertEqual(try store.memoryCount(), 0, "未配置抽取时不允许产生任何记忆条目")
        XCTAssertNil(coordinator.lastAuditRecord(), "一次都没抽取过就不该有审计记录")
    }

    // MARK: - 抽取

    func testExplicitUserStatementLandsAsCandidateAwaitingConfirmation() throws {
        let coordinator = makeCoordinator()

        let outcome = try coordinator.ingest(
            notes: [makeNote(body: "我习惯晚上学习")],
            now: fixedDate("2026-10-12T10:00:00Z")
        )

        XCTAssertEqual(outcome.stored.count, 1)
        let item = try XCTUnwrap(outcome.stored.first)
        XCTAssertEqual(item.status, .candidate, "抽取不等于用户确认，落库只能是候选")
        XCTAssertEqual(item.sourceKind, .userStatement, "用户原话的来源要如实保留")
        XCTAssertEqual(item.category, .preference)
        XCTAssertFalse(item.status.isUsableAsFact)
        XCTAssertEqual(try store.memoryCount(), 1)
    }

    func testModelInferenceIsAlwaysCandidateAndNeverFact() throws {
        let coordinator = makeCoordinator()
        // 这句话没有任何「我…」的显式表述，只会走推断规则。
        let note = makeNote(body: "每天都去图书馆复习")

        let outcome = try coordinator.ingest(notes: [note], now: fixedDate(base))
        let item = try XCTUnwrap(outcome.stored.first)

        XCTAssertEqual(item.sourceKind, .inferred)
        XCTAssertEqual(item.status, .candidate)
        XCTAssertFalse(item.sourceKind.isUserAsserted)
        XCTAssertFalse(item.status.isUsableAsFact)

        // 再抽取一次也不会把它确认掉。
        _ = try coordinator.ingest(notes: [note], now: fixedDate("2026-10-12T11:00:00Z"))
        XCTAssertEqual(try store.memory(id: item.id)?.status, .candidate)
    }

    func testReplyExtractionProducesCandidateFromFollowUpReply() throws {
        let coordinator = makeCoordinator()
        let reply = makeReply(text: "我对花生过敏")

        let candidates = try coordinator.extractCandidates(replies: [reply], now: fixedDate(base))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.origin, .followUpReply)
        XCTAssertEqual(candidate.originRecordId, reply.id)
        XCTAssertEqual(candidate.draft.category, .experience)
        XCTAssertEqual(candidate.draft.sourceKind, .userStatement)
    }

    // MARK: - 记录开关

    func testDisabledCategoryIsNotWrittenAndLeavesExplainableRecord() throws {
        let coordinator = makeCoordinator()
        try store.setRecordingEnabled(category: .preference, enabled: false, at: fixedDate(base))

        let outcome = try coordinator.ingest(
            notes: [makeNote(body: "我习惯在凌晨三点喝酸奶")],
            now: fixedDate("2026-10-12T10:00:00Z")
        )

        XCTAssertTrue(outcome.stored.isEmpty, "关闭类别后不允许写入")
        XCTAssertEqual(try store.memoryCount(), 0)
        XCTAssertEqual(outcome.discards.count, 1)
        let discard = try XCTUnwrap(outcome.discards.first)
        XCTAssertEqual(discard.stage, .recordingDisabled)
        XCTAssertEqual(discard.category, .preference)
        XCTAssertFalse(discard.reason.isEmpty, "丢弃必须留下可解释的原因")

        // 审计记录里也不能出现用户原文——关掉记录之后不能再把内容写到别处。
        let auditJSON = try XCTUnwrap(store.setting(MemoryIngestCoordinator.auditSettingKey))
        XCTAssertFalse(auditJSON.contains("酸奶"), "审计记录不得保存候选原文")
        XCTAssertEqual(coordinator.lastAuditRecord()?.discards.count, 1)
    }

    func testLateResponseIsBlockedWhenCategoryIsDisabledAfterExtraction() throws {
        let coordinator = makeCoordinator()
        let note = makeNote(body: "我习惯晚上学习")

        // 提取时开关是开的，候选正常产出。
        let candidates = try coordinator.extractCandidates(notes: [note], now: fixedDate(base))
        XCTAssertEqual(candidates.count, 1)

        // 落库之前用户关掉了类别：模拟迟到的解析响应。
        try store.setRecordingEnabled(category: .preference, enabled: false, at: fixedDate("2026-10-12T09:30:00Z"))

        let outcome = try coordinator.ingest(candidates: candidates, now: fixedDate("2026-10-12T10:00:00Z"))

        XCTAssertTrue(outcome.stored.isEmpty, "落库那一刻要再查一次开关，迟到响应必须被拦住")
        XCTAssertEqual(try store.memoryCount(), 0)
        XCTAssertEqual(outcome.discards.first?.stage, .recordingDisabled)
    }

    func testDisabledCategoryDoesNotBlockOtherCategories() throws {
        let coordinator = makeCoordinator()
        try store.setRecordingEnabled(category: .preference, enabled: false, at: fixedDate(base))

        let outcome = try coordinator.ingest(
            notes: [makeNote(body: "我习惯晚上学习。我这个学期大四。")],
            now: fixedDate(base)
        )

        XCTAssertEqual(outcome.stored.count, 1)
        XCTAssertEqual(outcome.stored.first?.category, .phase)
        XCTAssertEqual(outcome.discards.count, 1)
        XCTAssertEqual(try store.memoryCount(), 1)
    }

    func testReenablingCategoryAllowsSubsequentWrite() throws {
        let coordinator = makeCoordinator()
        let note = makeNote(body: "我习惯晚上学习")

        try store.setRecordingEnabled(category: .preference, enabled: false, at: fixedDate(base))
        let blocked = try coordinator.ingest(notes: [note], now: fixedDate(base))
        XCTAssertTrue(blocked.stored.isEmpty)

        try store.setRecordingEnabled(category: .preference, enabled: true, at: fixedDate("2026-10-12T10:00:00Z"))
        let allowed = try coordinator.ingest(notes: [note], now: fixedDate("2026-10-12T10:10:00Z"))

        XCTAssertEqual(allowed.stored.count, 1)
        XCTAssertEqual(try store.memoryCount(), 1)
    }

    // MARK: - 去重与冲突

    func testDuplicateExtractionDoesNotCreateSecondRow() throws {
        let coordinator = makeCoordinator()
        let note = makeNote(body: "我习惯晚上学习")

        let first = try coordinator.ingest(notes: [note], now: fixedDate(base))
        XCTAssertEqual(first.stored.count, 1)

        let second = try coordinator.ingest(notes: [note], now: fixedDate("2026-10-12T10:00:00Z"))

        XCTAssertTrue(second.stored.isEmpty)
        XCTAssertEqual(second.duplicates.count, 1)
        XCTAssertEqual(try store.memoryCount(), 1, "同一条笔记重复抽取不允许造出第二条")
    }

    func testSingleValuedConflictLandsAsConflictAndKeepsOldStatement() throws {
        let coordinator = makeCoordinator()
        let first = try coordinator.ingest(
            notes: [makeNote(id: "note_live_a", body: "我住在学校东门")],
            now: fixedDate(base)
        )
        let firstItem = try XCTUnwrap(first.stored.first)
        guard case .confirmed = try coordinator.confirm(
            candidateId: firstItem.id,
            now: fixedDate("2026-10-12T09:10:00Z")
        ) else {
            return XCTFail("第一条应当能被确认")
        }

        let second = try coordinator.ingest(
            notes: [makeNote(id: "note_live_b", body: "我住在家里")],
            now: fixedDate("2026-10-12T10:00:00Z")
        )

        let conflictItem = try XCTUnwrap(second.stored.first)
        XCTAssertEqual(conflictItem.status, .conflict, "单值类别出现第二种说法要进 conflict")
        XCTAssertEqual(conflictItem.category, .place)
        XCTAssertEqual(try store.memory(id: firstItem.id)?.statement, "我住在学校东门", "旧说法不得被静默覆盖")
        XCTAssertEqual(try store.memory(id: firstItem.id)?.status, .confirmed)
    }

    func testConfirmBlockedByExistingConfirmedConflictDoesNotOverwrite() throws {
        let coordinator = makeCoordinator()
        let first = try coordinator.ingest(
            notes: [makeNote(id: "note_a", body: "我住在学校东门")],
            now: fixedDate(base)
        )
        let firstItem = try XCTUnwrap(first.stored.first)
        _ = try coordinator.confirm(candidateId: firstItem.id, now: fixedDate("2026-10-12T09:10:00Z"))

        let second = try coordinator.ingest(
            notes: [makeNote(id: "note_b", body: "我住在家里")],
            now: fixedDate("2026-10-12T10:00:00Z")
        )
        let conflictItem = try XCTUnwrap(second.stored.first)

        let result = try coordinator.confirm(
            candidateId: conflictItem.id,
            now: fixedDate("2026-10-12T10:10:00Z")
        )

        guard case .blockedByConflict(let candidate, let conflicts) = result else {
            return XCTFail("与已确认记忆冲突时必须拦下来交用户裁决")
        }
        XCTAssertEqual(candidate.id, conflictItem.id)
        XCTAssertEqual(conflicts.map(\.id), [firstItem.id])
        XCTAssertEqual(try store.memory(id: conflictItem.id)?.status, .conflict, "被拦下时状态不得改变")
        XCTAssertEqual(try store.memory(id: firstItem.id)?.status, .confirmed)
    }

    func testEmptyStatementCandidateIsDiscarded() throws {
        let coordinator = makeCoordinator()
        let candidate = MemoryCandidate(
            id: "cand_empty",
            draft: MemoryDraft(category: .preference, statement: "   ", sourceKind: .inferred),
            origin: .note,
            originRecordId: "note_empty",
            evidenceText: "",
            extractedAt: base
        )

        let outcome = try coordinator.ingest(candidates: [candidate], now: fixedDate(base))

        XCTAssertTrue(outcome.stored.isEmpty)
        XCTAssertEqual(outcome.discards.first?.stage, .emptyStatement)
        XCTAssertEqual(try store.memoryCount(), 0)
    }

    // MARK: - 用户确认

    func testConfirmUpgradesStatusAndSourceKindAndProvidesCitations() throws {
        let coordinator = makeCoordinator()
        let outcome = try coordinator.ingest(notes: [makeNote(body: "我习惯晚上学习")], now: fixedDate(base))
        let candidate = try XCTUnwrap(outcome.stored.first)

        // 确认之前：检索不到任何可用事实。
        let before = try coordinator.answer(question: "我晚上怎么学习", now: fixedDate("2026-10-12T09:30:00Z"))
        XCTAssertFalse(before.isGrounded)

        guard case .confirmed(let confirmed) = try coordinator.confirm(
            candidateId: candidate.id,
            now: fixedDate("2026-10-12T10:00:00Z")
        ) else {
            return XCTFail("候选应当能被确认")
        }
        XCTAssertEqual(confirmed.status, .confirmed)
        XCTAssertEqual(confirmed.sourceKind, .userStatement)
        XCTAssertTrue(confirmed.status.isUsableAsFact)
        XCTAssertEqual(try store.latestRevision(memoryId: candidate.id)?.status, .confirmed, "最新修订要同步镜像")

        let after = try coordinator.answer(question: "我晚上怎么学习", now: fixedDate("2026-10-12T10:05:00Z"))
        XCTAssertTrue(after.isGrounded)
        XCTAssertEqual(after.citedMemoryIds, [candidate.id])
        XCTAssertEqual(after.citations.first?.sourceKind, .userStatement)
        XCTAssertTrue(after.text.contains("我习惯晚上学习"))
    }

    func testConfirmAlreadyConfirmedIsIdempotent() throws {
        let coordinator = makeCoordinator()
        let outcome = try coordinator.ingest(notes: [makeNote(body: "我习惯晚上学习")], now: fixedDate(base))
        let item = try XCTUnwrap(outcome.stored.first)

        _ = try coordinator.confirm(candidateId: item.id, now: fixedDate("2026-10-12T09:10:00Z"))
        let second = try coordinator.confirm(candidateId: item.id, now: fixedDate("2026-10-12T09:20:00Z"))

        guard case .alreadyConfirmed = second else {
            return XCTFail("重复确认应当是幂等的")
        }
        XCTAssertEqual(try store.revisions(memoryId: item.id).count, 2, "重复确认不允许再写一版修订")
    }

    func testConfirmOfRetiredIsRefused() throws {
        let coordinator = makeCoordinator()
        let outcome = try coordinator.ingest(notes: [makeNote(body: "我习惯晚上学习")], now: fixedDate(base))
        let item = try XCTUnwrap(outcome.stored.first)
        try store.setMemoryStatus(id: item.id, status: .retired, at: fixedDate("2026-10-12T09:10:00Z"))

        let result = try coordinator.confirm(candidateId: item.id, now: fixedDate("2026-10-12T09:20:00Z"))

        guard case .notConfirmable(let status) = result else {
            return XCTFail("已作废的说法不允许被确认复活")
        }
        XCTAssertEqual(status, .retired)
        XCTAssertEqual(try store.memory(id: item.id)?.status, .retired)
    }

    // MARK: - 检索回答

    func testAnswerWithoutAnyMemorySaysNoRelevantMemory() throws {
        let coordinator = makeCoordinator()

        let answer = try coordinator.answer(question: "我晚上在哪学习", now: fixedDate(base))

        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertFalse(answer.isGrounded)
        XCTAssertTrue(answer.text.contains("没有相关记忆"), "没有可用记忆时必须如实回答")
        XCTAssertTrue(answer.references.isEmpty)
    }

    func testAnswerWithOnlyCandidatesDoesNotFabricate() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(notes: [makeNote(body: "每天都去图书馆复习")], now: fixedDate(base))

        let answer = try coordinator.answer(question: "我平时在哪复习", now: fixedDate("2026-10-12T10:00:00Z"))

        XCTAssertTrue(answer.citations.isEmpty, "候选不能被当作事实引用")
        XCTAssertFalse(answer.isGrounded)
        XCTAssertEqual(answer.references.count, 1)
        XCTAssertTrue(answer.text.contains("没有相关记忆"))
        XCTAssertFalse(answer.text.contains("每天都去图书馆复习"), "没有确认过的内容不得写进回答正文")
    }

    func testCustomComposerIsUsedOnlyWhenFactsExist() throws {
        let coordinator = MemoryIngestCoordinator(
            store: store,
            extraction: MemoryExtraction(provider: DefaultRuleBasedExtractor()),
            composer: FixedComposer()
        )

        let empty = try coordinator.answer(question: "我晚上怎么学习", now: fixedDate(base))
        XCTAssertFalse(empty.text.contains("自定义回答"), "没有事实时不许调用 composer，避免它编造")

        let outcome = try coordinator.ingest(notes: [makeNote(body: "我习惯晚上学习")], now: fixedDate(base))
        let item = try XCTUnwrap(outcome.stored.first)
        _ = try coordinator.confirm(candidateId: item.id, now: fixedDate("2026-10-12T09:10:00Z"))

        let grounded = try coordinator.answer(question: "我晚上怎么学习", now: fixedDate("2026-10-12T09:20:00Z"))
        XCTAssertEqual(grounded.text, "自定义回答：" + item.id)
    }

    func testDeletedMemoryIsNoLongerRetrievableAndIndexIsCleared() throws {
        let coordinator = makeCoordinator()
        let outcome = try coordinator.ingest(notes: [makeNote(body: "我习惯晚上学习")], now: fixedDate(base))
        let item = try XCTUnwrap(outcome.stored.first)
        _ = try coordinator.confirm(candidateId: item.id, now: fixedDate("2026-10-12T09:10:00Z"))

        let before = try coordinator.answer(question: "我晚上怎么学习", now: fixedDate("2026-10-12T09:20:00Z"))
        XCTAssertTrue(before.isGrounded)

        try store.softDeleteMemory(id: item.id, at: fixedDate("2026-10-12T09:30:00Z"))

        XCTAssertEqual(try store.indexedTokenCount(memoryId: item.id), 0, "删除记忆必须同时清掉派生索引")
        let after = try coordinator.answer(question: "我晚上怎么学习", now: fixedDate("2026-10-12T09:40:00Z"))
        XCTAssertFalse(after.isGrounded)
        XCTAssertTrue(after.text.contains("没有相关记忆"))
    }

    // MARK: - 审计

    func testAuditSummarizesStoredAndDiscardedCounts() throws {
        let coordinator = makeCoordinator()
        try store.setRecordingEnabled(category: .preference, enabled: false, at: fixedDate(base))

        _ = try coordinator.ingest(
            notes: [makeNote(body: "我习惯晚上学习。我这个学期大四。")],
            now: fixedDate(base)
        )

        let audit = try XCTUnwrap(coordinator.lastAuditRecord())
        XCTAssertEqual(audit.storedCount, 1)
        XCTAssertEqual(audit.conflictCount, 0)
        XCTAssertEqual(audit.discards.count, 1)
        XCTAssertEqual(audit.discards.first?.category, .preference)
        XCTAssertEqual(audit.at, base)
    }
}
