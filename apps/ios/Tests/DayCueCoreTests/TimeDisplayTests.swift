import Foundation
import XCTest
@testable import DayCueCore

/// 时间展示测试：日期型截止日不能显示成带时刻的字符串。
final class TimeDisplayTests: XCTestCase {

    func testDateKindShowsOnlyCalendarDate() {
        XCTAssertEqual(TaskTimeDisplay.dueText(kind: .date, local: "2026-10-16"), "2026-10-16")
        // 即使后端多给了 T00:00:00，也只能显示日期，不能变成 "2026-10-16 00:00"。
        XCTAssertEqual(TaskTimeDisplay.dueText(kind: .date, local: "2026-10-16T00:00:00"), "2026-10-16")
    }

    func testDateTimeKindShowsFullMinutePrecision() {
        XCTAssertEqual(TaskTimeDisplay.dueText(kind: .datetime, local: "2026-10-12T20:00:00"), "2026-10-12 20:00")
    }

    func testNoneKindHasNoDueText() {
        XCTAssertNil(TaskTimeDisplay.dueText(kind: .none, local: nil))
        // kind=none 却带着 local 时也不能显示，避免界面凭空冒出一个时间。
        XCTAssertNil(TaskTimeDisplay.dueText(kind: .none, local: "2026-10-16"))
    }

    func testReminderTextIsNilWhenThereIsNoReminder() {
        let task = TaskRecord(
            id: "task_deadline_only",
            title: "交实验报告",
            dueKind: .date,
            dueLocal: "2026-10-16",
            timezone: "Asia/Shanghai",
            createdAt: "",
            updatedAt: ""
        )
        XCTAssertNil(TaskTimeDisplay.remindText(for: task))
        XCTAssertEqual(TaskTimeDisplay.dueText(for: task), "2026-10-16")
        XCTAssertEqual(TaskTimeDisplay.scheduleSummary(for: task), "截止 2026-10-16")
    }

    func testScheduleSummaryCombinesReminderAndDeadline() {
        let task = TaskRecord(
            id: "task_both",
            title: "复习 PV",
            dueKind: .datetime,
            dueLocal: "2026-10-12T22:00:00",
            timezone: "Asia/Shanghai",
            remindLocal: "2026-10-12T20:00:00",
            remindUTC: "2026-10-12T12:00:00Z",
            createdAt: "",
            updatedAt: ""
        )
        XCTAssertEqual(TaskTimeDisplay.remindText(for: task), "2026-10-12 20:00")
        XCTAssertEqual(TaskTimeDisplay.scheduleSummary(for: task), "提醒 2026-10-12 20:00 · 截止 2026-10-12 22:00")
    }

    func testScheduleSummaryWhenNothingIsSet() {
        let task = TaskRecord(id: "task_none", title: "随手记", createdAt: "", updatedAt: "")
        XCTAssertEqual(TaskTimeDisplay.scheduleSummary(for: task), "未设置时间")
    }

    func testMalformedDateIsPassedThroughInsteadOfFabricated() {
        // 不完整的日期不允许被"补全"；原样返回让用户看到问题。
        XCTAssertEqual(TaskTimeDisplay.dateText("2026-10-1"), "2026-10-1")
        XCTAssertEqual(TaskTimeDisplay.dateText(nil), nil)
    }

    func testTaskOrderingPutsReminderFirstThenDueThenUndated() {
        let tasks = [
            TaskRecord(id: "c", title: "无时间", createdAt: "", updatedAt: ""),
            TaskRecord(id: "b", title: "只有截止", dueKind: .date, dueLocal: "2026-10-16", createdAt: "", updatedAt: ""),
            TaskRecord(id: "a", title: "有提醒", dueKind: .date, dueLocal: "2026-10-20", remindLocal: "2026-10-12T20:00:00", createdAt: "", updatedAt: "")
        ]
        XCTAssertEqual(TaskOrdering.sorted(tasks).map { $0.id }, ["a", "b", "c"])
    }

    func testReviewDraftSetDueForDateKindDoesNotWriteUTC() {
        var draft = ReviewDraft(
            id: "itm_1",
            kind: .task,
            title: "交报告",
            sourceEvidence: "周五之前",
            dueKind: .none,
            timezone: "Asia/Shanghai"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!

        draft.setDue(kind: .date, date: date, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(draft.dueLocal, "2026-10-16")
        XCTAssertNil(draft.dueUTC, "日期型不得写入 UTC 时刻")
        XCTAssertTrue(draft.hasUserEditedTime)

        draft.setDue(kind: .datetime, date: date, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(draft.dueLocal, "2026-10-16T00:00:00")
        XCTAssertEqual(draft.dueUTC, "2026-10-15T16:00:00Z")
    }

    func testExternalIdentifierRoundTripThroughNotes() {
        let task = TaskRecord(id: "task_42", title: "复习 PV", detail: "细节", createdAt: "", updatedAt: "")
        let notes = ExternalIdentifier.noteBody(task: task, deepLink: "daycue://task/task_42")
        XCTAssertEqual(ExternalIdentifier.taskId(fromNotes: notes), "task_42")
        XCTAssertNil(ExternalIdentifier.taskId(fromNotes: "没有标识的备注"))
        XCTAssertNil(ExternalIdentifier.taskId(fromNotes: nil))
    }
}
