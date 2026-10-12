import Foundation
import XCTest
@testable import DayCueCore

/// 「候选 -> 笔记录入」测试：来源绑定、幂等去重、以及「不覆盖用户编辑」的优先级。
final class NoteExtractionTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-note-extraction-tests-" + UUID().uuidString
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

    // MARK: - 构造

    private func insertCapture(id: String, recordedAt: String = "2026-10-12T08:30:00Z") throws {
        try store.insertCapture(CaptureRecord(
            id: id,
            kind: .text,
            rawText: "操作系统第三章讲了 PV 操作",
            recordedAt: recordedAt,
            recordedTimezone: "Asia/Shanghai"
        ))
    }

    private func noteItem(
        itemId: String = "itm_note_1",
        title: String = "操作系统第三章",
        detail: String? = "PV 操作与信号量",
        sourceEvidence: String = "操作系统第三章讲了 PV 操作",
        courseHint: String? = "操作系统"
    ) -> ContractExtractionItem {
        ContractExtractionItem(
            itemId: itemId,
            kind: .note,
            title: title,
            detail: detail,
            sourceEvidence: sourceEvidence,
            due: ContractDue(kind: .none),
            courseHint: courseHint
        )
    }

    private func taskItem(itemId: String = "itm_task_1") -> ContractExtractionItem {
        ContractExtractionItem(
            itemId: itemId,
            kind: .task,
            title: "交实验报告",
            detail: nil,
            sourceEvidence: "周五之前交实验报告",
            due: ContractDue(kind: .date, local: "2026-10-16"),
            courseHint: "操作系统"
        )
    }

    private func response(captureId: String, items: [ContractExtractionItem]) -> ExtractionResponse {
        ExtractionResponse(
            schemaVersion: "v1",
            captureId: captureId,
            mode: .live,
            items: items,
            warnings: []
        )
    }

    // MARK: - 用例

    func testNoteItemBecomesNoteWithCaptureOrigin() throws {
        try insertCapture(id: "cap_note")
        let outcome = try store.applyNoteCandidates(response(captureId: "cap_note", items: [noteItem()]))

        XCTAssertEqual(outcome.inserted, 1)
        XCTAssertEqual(outcome.updated, 0)
        XCTAssertEqual(outcome.skipped, 0)

        let note = try XCTUnwrap(try store.notes().first)
        XCTAssertEqual(note.title, "操作系统第三章")
        XCTAssertEqual(note.body, "PV 操作与信号量")
        XCTAssertEqual(note.originKind, .capture)
        XCTAssertEqual(note.originCaptureId, "cap_note")
        XCTAssertEqual(note.originItemId, "itm_note_1")
        XCTAssertEqual(note.courseHint, "操作系统")
        XCTAssertFalse(note.userEdited)
        // 发生时间取记录的录入时刻，而不是这次解析的时刻。
        XCTAssertEqual(note.occurredAt, "2026-10-12T08:30:00Z")
        XCTAssertFalse(note.createdAt.isEmpty)
        XCTAssertFalse(note.updatedAt.isEmpty)
    }

    func testTaskItemsAreIgnoredByNotePipeline() throws {
        try insertCapture(id: "cap_task_only")
        let outcome = try store.applyNoteCandidates(response(captureId: "cap_task_only", items: [taskItem()]))

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(outcome.skipped, 0, "任务候选由任务路径处理，不该被笔记管道记成跳过")
        XCTAssertTrue(try store.notes().isEmpty)
    }

    func testRetryUpdatesUneditedNoteAndDoesNotDuplicate() throws {
        try insertCapture(id: "cap_retry")
        let first = try store.applyNoteCandidates(
            response(captureId: "cap_retry", items: [noteItem(detail: "第一版正文")])
        )
        XCTAssertEqual(first.inserted, 1)

        let second = try store.applyNoteCandidates(
            response(captureId: "cap_retry", items: [noteItem(detail: "第二版正文")])
        )

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 1)
        XCTAssertEqual(second.skipped, 0)
        XCTAssertEqual(try store.noteCount(), 1, "同一个 originItemId 不允许产生两条笔记")

        let note = try XCTUnwrap(try store.notes().first)
        XCTAssertEqual(note.body, "第二版正文")
    }

    func testRetryDoesNotOverwriteUserEditedNoteButCountsSkipped() throws {
        try insertCapture(id: "cap_edited")
        _ = try store.applyNoteCandidates(response(captureId: "cap_edited", items: [noteItem()]))

        var edited = try XCTUnwrap(try store.notes().first)
        edited.body = "我自己整理的正文"
        try store.updateNote(edited)
        try store.markNoteUserEdited(id: edited.id)

        let outcome = try store.applyNoteCandidates(
            response(captureId: "cap_edited", items: [noteItem(detail: "后端又给了一版")])
        )

        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertEqual(outcome.updated, 0)
        XCTAssertEqual(outcome.skippedUserEdited, 1)
        XCTAssertEqual(outcome.skipped, 1)

        let reloaded = try XCTUnwrap(try store.note(id: edited.id))
        XCTAssertEqual(reloaded.body, "我自己整理的正文", "用户改过的正文不能被重试解析覆盖")
        XCTAssertTrue(reloaded.userEdited)
    }

    func testDeletedNoteIsNotResurrectedByRetry() throws {
        try insertCapture(id: "cap_deleted")
        _ = try store.applyNoteCandidates(response(captureId: "cap_deleted", items: [noteItem()]))

        let note = try XCTUnwrap(try store.notes().first)
        try store.softDeleteNote(id: note.id)

        let outcome = try store.applyNoteCandidates(
            response(captureId: "cap_deleted", items: [noteItem(detail: "删除之后的新版本")])
        )

        XCTAssertEqual(outcome.skippedDeleted, 1)
        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertEqual(try store.noteCount(), 0, "用户删掉的笔记不能因为一次重试又回来")
        XCTAssertNil(try store.note(id: note.id))
    }

    func testMixedBatchIsAggregatedHonestly() throws {
        try insertCapture(id: "cap_mixed")
        _ = try store.applyNoteCandidates(
            response(captureId: "cap_mixed", items: [noteItem(itemId: "itm_keep_me")])
        )
        var edited = try XCTUnwrap(try store.notes().first)
        edited.body = "用户改过的正文"
        try store.updateNote(edited)
        try store.markNoteUserEdited(id: edited.id)

        let outcome = try store.applyNoteCandidates(response(captureId: "cap_mixed", items: [
            noteItem(itemId: "itm_keep_me", detail: "重试给的新正文"),
            noteItem(itemId: "itm_new", title: "新笔记", detail: "新正文"),
            noteItem(itemId: "itm_empty", title: "   ", detail: nil, sourceEvidence: "  ")
        ]))

        XCTAssertEqual(outcome.inserted, 1)
        XCTAssertEqual(outcome.updated, 0)
        XCTAssertEqual(outcome.skippedUserEdited, 1)
        XCTAssertEqual(outcome.skippedInvalid, 1)
        XCTAssertEqual(outcome.skipped, 2)
        XCTAssertEqual(try store.noteCount(), 2)
    }

    func testItemWithoutTitleFallsBackToEvidenceFirstLine() throws {
        try insertCapture(id: "cap_title_fallback")
        _ = try store.applyNoteCandidates(response(captureId: "cap_title_fallback", items: [
            noteItem(
                itemId: "itm_no_title",
                title: "   ",
                detail: nil,
                sourceEvidence: "\n  午休时想到：把复习拆成两段  \n剩下的都是细节"
            )
        ]))

        let note = try XCTUnwrap(try store.notes().first)
        XCTAssertEqual(note.title, "午休时想到：把复习拆成两段")
        XCTAssertEqual(
            note.body,
            "\n  午休时想到：把复习拆成两段  \n剩下的都是细节",
            "没有 detail 时正文用证据原文，保留原始格式"
        )
    }

    func testUserTagsSurviveRetry() throws {
        try insertCapture(id: "cap_tags")
        _ = try store.applyNoteCandidates(response(captureId: "cap_tags", items: [noteItem()]))

        var note = try XCTUnwrap(try store.notes().first)
        note.tags = ["期末", "重点"]
        try store.updateNote(note)

        let outcome = try store.applyNoteCandidates(
            response(captureId: "cap_tags", items: [noteItem(detail: "重试后的正文")])
        )

        XCTAssertEqual(outcome.updated, 1)
        let reloaded = try XCTUnwrap(try store.note(id: note.id))
        XCTAssertEqual(reloaded.tags, ["期末", "重点"], "后端候选里没有标签字段，重试不能抹掉用户加的标签")
        XCTAssertEqual(reloaded.body, "重试后的正文")
    }

    func testSameItemIdFromDifferentCapturesCreatesSeparateNotes() throws {
        try insertCapture(id: "cap_a")
        try insertCapture(id: "cap_b")

        _ = try store.applyNoteCandidates(response(captureId: "cap_a", items: [noteItem(itemId: "itm_shared")]))
        _ = try store.applyNoteCandidates(response(captureId: "cap_b", items: [noteItem(itemId: "itm_shared")]))

        XCTAssertEqual(try store.noteCount(), 2, "去重键是 (captureId, itemId)，不同记录里的同名候选是两条笔记")
        XCTAssertEqual(Set(try store.notes().map(\.id)).count, 2, "两次解析不能复用同一个 note id")
    }

    func testOutcomeSummaryTextExplainsWhatHappened() throws {
        try insertCapture(id: "cap_summary")
        let outcome = try store.applyNoteCandidates(response(captureId: "cap_summary", items: [noteItem()]))

        XCTAssertEqual(outcome.summaryText, "新增 1 条笔记。")
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(NoteUpsertOutcome().summaryText, "这次解析没有产生笔记。")
        XCTAssertEqual(NoteUpsertOutcome(skippedUserEdited: 2).summaryText, "保留 2 条你改过的笔记。")
    }
}
