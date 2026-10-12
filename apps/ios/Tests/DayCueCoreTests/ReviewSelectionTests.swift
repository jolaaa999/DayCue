import Foundation
import XCTest
@testable import DayCueCore

/// 笔记不能被算成任务；取消勾选的任务不能被创建。
///
/// 对应验收："1 条笔记 + 2 条任务，取消其中一条任务后，应保存 1 条笔记 + 1 条任务"。
final class ReviewSelectionTests: XCTestCase {

    private func draft(id: String, kind: ProposalItemKind, selected: Bool = true) -> ReviewDraft {
        ReviewDraft(
            id: id,
            kind: kind,
            title: "标题 " + id,
            sourceEvidence: "原文依据",
            dueKind: kind == .task ? .datetime : .none,
            dueLocal: kind == .task ? "2026-10-12T20:00:00" : nil,
            timezone: "Asia/Shanghai",
            isSelected: selected
        )
    }

    /// 契约 fixture 的形态：itm_1 笔记 + itm_2 / itm_3 任务。
    private func fixtureDrafts() -> [ReviewDraft] {
        [
            draft(id: "itm_1", kind: .note),
            draft(id: "itm_2", kind: .task),
            draft(id: "itm_3", kind: .task)
        ]
    }

    func testOneNoteTwoTasksCreatesTwoTasksAndOneNote() {
        let drafts = fixtureDrafts()
        XCTAssertEqual(drafts.tasksToCreate.map(\.id), ["itm_2", "itm_3"])
        XCTAssertEqual(drafts.selectedNoteCount, 1)
        XCTAssertFalse(drafts.createsNothing)
    }

    func testUnselectingOneTaskLeavesOneTaskAndOneNote() {
        var drafts = fixtureDrafts()
        drafts[1].isSelected = false  // 取消 itm_2

        XCTAssertEqual(drafts.tasksToCreate.map(\.id), ["itm_3"])
        XCTAssertEqual(drafts.selectedNoteCount, 1, "取消一个任务不应影响笔记计数")
    }

    func testNoteIsNeverCountedAsTask() {
        let drafts = [draft(id: "itm_1", kind: .note)]
        XCTAssertTrue(drafts.tasksToCreate.isEmpty)
        XCTAssertEqual(drafts.selectedNoteCount, 1)
        XCTAssertTrue(drafts.createsNothing)
    }

    /// 用户在预览页把类型从任务改成笔记，就不该再创建任务。
    func testChangingKindToNoteRemovesItFromTaskCreation() {
        var drafts = fixtureDrafts()
        drafts[1].kind = .note

        XCTAssertEqual(drafts.tasksToCreate.map(\.id), ["itm_3"])
        XCTAssertEqual(drafts.selectedNoteCount, 2)
    }

    func testChangingKindToTaskAddsItToTaskCreation() {
        var drafts = fixtureDrafts()
        drafts[0].kind = .task

        XCTAssertEqual(drafts.tasksToCreate.map(\.id), ["itm_1", "itm_2", "itm_3"])
        XCTAssertEqual(drafts.selectedNoteCount, 0)
    }

    func testAllUnselectedCreatesNothing() {
        var drafts = fixtureDrafts()
        for index in drafts.indices { drafts[index].isSelected = false }

        XCTAssertTrue(drafts.createsNothing)
        XCTAssertEqual(drafts.selectedNoteCount, 0)
    }
}
