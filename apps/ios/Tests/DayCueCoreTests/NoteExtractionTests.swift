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

    // MARK: - 用户勾选才落库（预览页确认路径）

    /// 预览页的意义是「点了才算数」。
    ///
    /// 这条测试守的是一个真实缺陷：应用层曾经只创建任务，笔记只作为提案 JSON 的一个
    /// 字段躺着，用户在笔记页看不到、改不了、删不掉。修完之后，**取消勾选的候选
    /// 绝不能落库** —— 否则勾选框就只是装饰，用户以为取消掉了，数据却还在。
    func testOnlySelectedNoteDraftsArePersisted() throws {
        let captureId = "cap_select_1"
        try insertCapture(id: captureId)

        let selected = ReviewDraft.from(item: noteItem(itemId: "itm_keep", title: "留下的"), mode: .live)
        var deselected = ReviewDraft.from(item: noteItem(itemId: "itm_drop", title: "取消的"), mode: .live)
        deselected.isSelected = false

        let outcome = try store.applySelectedNoteDrafts(
            [selected, deselected],
            captureId: captureId,
            occurredAt: "2026-10-12T08:30:00Z"
        )

        // 只写了一条：被取消的那条不产生任何动作，也不算「跳过」——
        // 跳过意味着"系统看过但没写"，而这里用户根本没要它。
        XCTAssertEqual(outcome.inserted, 1)
        XCTAssertEqual(outcome.skipped, 0)

        XCTAssertNotNil(try store.note(originCaptureId: captureId, originItemId: "itm_keep"))
        XCTAssertNil(try store.note(originCaptureId: captureId, originItemId: "itm_drop"))
    }

    /// 笔记的「发生时间」应当指向用户说话的那一刻，而不是他事后点确认的那一刻。
    /// 取错的话，每确认一次就会把这条笔记的时间线往后挪一次。
    func testSelectedNoteUsesCaptureRecordedAtNotConfirmTime() throws {
        let captureId = "cap_select_2"
        try insertCapture(id: captureId, recordedAt: "2026-10-12T08:30:00Z")

        let draft = ReviewDraft.from(item: noteItem(itemId: "itm_time"), mode: .live)
        _ = try store.applySelectedNoteDrafts(
            [draft],
            captureId: captureId,
            occurredAt: "2026-10-12T08:30:00Z"
        )

        let saved = try XCTUnwrap(try store.note(originCaptureId: captureId, originItemId: "itm_time"))
        XCTAssertEqual(saved.occurredAt, "2026-10-12T08:30:00Z")
    }

    /// 同一条候选被确认两次（用户重复点、或自动模式与手动确认各走一次），
    /// 只能有一条笔记；否则笔记列表里会出现两条一模一样的记录。
    func testConfirmingTwiceDoesNotDuplicateNote() throws {
        let captureId = "cap_select_3"
        try insertCapture(id: captureId)
        let draft = ReviewDraft.from(item: noteItem(itemId: "itm_twice"), mode: .live)

        let first = try store.applySelectedNoteDrafts([draft], captureId: captureId)
        let second = try store.applySelectedNoteDrafts([draft], captureId: captureId)

        XCTAssertEqual(first.inserted, 1)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 1, "第二次应当是覆盖更新同一条，而不是新增")
        XCTAssertEqual(try store.notes().count, 1)
    }

    /// 用户删掉一条笔记之后，重试解析绝不能把它复活。
    /// 「我删了的东西又回来了」是用户最难接受的一类问题。
    func testDeletedNoteIsNotResurrectedBySelectedDrafts() throws {
        let captureId = "cap_select_4"
        try insertCapture(id: captureId)
        let draft = ReviewDraft.from(item: noteItem(itemId: "itm_deleted"), mode: .live)

        _ = try store.applySelectedNoteDrafts([draft], captureId: captureId)
        let saved = try XCTUnwrap(try store.note(originCaptureId: captureId, originItemId: "itm_deleted"))
        try store.softDeleteNote(id: saved.id)

        let outcome = try store.applySelectedNoteDrafts([draft], captureId: captureId)

        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertEqual(outcome.skippedDeleted, 1)
    }

}
