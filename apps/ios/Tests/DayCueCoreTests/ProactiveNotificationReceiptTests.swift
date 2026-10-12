import Foundation
import XCTest
@testable import DayCueCore

/// 通知交互回执的落库测试。
///
/// 状态：已编写、未运行（本机没有 Swift 工具链）。
/// 这些用例给的是替身回执，不是真机点击通知的验收。
final class ProactiveNotificationReceiptTests: XCTestCase {

    private var store: DayCueStore!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = try GeoTestSupport.makeStore()
        store = made.store
        directory = made.directory
    }

    override func tearDownWithError() throws {
        store = nil
        GeoTestSupport.cleanUp(directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func fixedDate(_ string: String) -> Date {
        guard let date = RFC3339.date(fromUTC: string) else {
            fatalError("测试用的固定时间写错了：\(string)")
        }
        return date
    }

    @discardableResult
    private func insertPendingMessage(
        dedupeKey: String,
        kind: ProactiveMessageKind = .geo,
        targetRef: String? = "rule_1"
    ) throws -> ProactiveMessageRecord {
        try store.recordProactiveMessage(ProactiveMessageRecord(
            kind: kind,
            dedupeKey: dedupeKey,
            targetRef: targetRef,
            state: .pending,
            suppressReason: nil,
            scheduledAtUTC: "2026-10-12T02:00:00Z",
            deliveredAtUTC: nil,
            expiresAtUTC: nil,
            createdAt: "2026-10-12T02:00:00Z",
            updatedAt: "2026-10-12T02:00:00Z"
        ))
    }

    func testOpenedMarksDeliveredWithTimestamp() throws {
        let key = "geo:rule_1:enter:2026-10-12"
        try insertPendingMessage(dedupeKey: key)
        let openedAt = fixedDate("2026-10-12T02:10:00Z")

        let service = ProactiveReceiptService(store: store)
        let outcome = try service.apply(ProactiveInteractionReceipt(
            dedupeKey: key,
            interaction: .opened,
            at: openedAt
        ))

        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(outcome.state, .delivered)
        XCTAssertEqual(outcome.deliveredAt, openedAt)

        let row = try XCTUnwrap(try store.proactiveMessage(dedupeKey: key))
        XCTAssertEqual(row.state, .delivered)
        XCTAssertEqual(row.deliveredAtUTC, RFC3339.utcString(from: openedAt))
    }

    func testDismissedMarksCancelledWithReason() throws {
        let key = "geo:rule_1:enter:2026-10-12"
        try insertPendingMessage(dedupeKey: key)

        let service = ProactiveReceiptService(store: store)
        let outcome = try service.apply(ProactiveInteractionReceipt(
            dedupeKey: key,
            interaction: .dismissed,
            at: fixedDate("2026-10-12T02:10:00Z")
        ))

        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertNil(outcome.deliveredAt, "忽略不等于送达")

        let row = try XCTUnwrap(try store.proactiveMessage(dedupeKey: key))
        XCTAssertEqual(row.state, .cancelled)
        XCTAssertEqual(row.suppressReason, ProactiveInteraction.dismissed.stateReason)
        XCTAssertFalse(row.state.consumesBudget, "已取消的提醒不该继续占用当日预算")
    }

    func testExpiredReceiptMarksExpired() throws {
        let key = "geo:rule_1:enter:2026-10-12"
        try insertPendingMessage(dedupeKey: key)

        let outcome = try ProactiveReceiptService(store: store).apply(ProactiveInteractionReceipt(
            dedupeKey: key,
            interaction: .expired,
            at: fixedDate("2026-10-13T02:00:00Z")
        ))

        XCTAssertEqual(outcome.state, .expired)
        let row = try XCTUnwrap(try store.proactiveMessage(dedupeKey: key))
        XCTAssertEqual(row.state, .expired)
    }

    func testTerminalStateIsNotReversedByLateReceipt() throws {
        let key = "geo:rule_1:enter:2026-10-12"
        let record = try insertPendingMessage(dedupeKey: key)
        try store.updateProactiveMessageState(id: record.id, state: .cancelled, suppressReason: "已取消", at: nil)

        let outcome = try ProactiveReceiptService(store: store).apply(ProactiveInteractionReceipt(
            dedupeKey: key,
            interaction: .opened,
            at: fixedDate("2026-10-12T03:00:00Z")
        ))

        XCTAssertFalse(outcome.applied, "终态不因迟到回执而反转")
        XCTAssertEqual(outcome.state, .cancelled)
        let row = try XCTUnwrap(try store.proactiveMessage(dedupeKey: key))
        XCTAssertEqual(row.state, .cancelled)
    }

    func testUnknownDedupeKeyIsNotApplied() throws {
        let outcome = try ProactiveReceiptService(store: store).apply(ProactiveInteractionReceipt(
            dedupeKey: "geo:ghost:enter:2026-10-12",
            interaction: .opened,
            at: fixedDate("2026-10-12T02:10:00Z")
        ))

        XCTAssertFalse(outcome.applied)
        XCTAssertNil(outcome.record, "账本里没有就不能凭空造一条已发出")
        XCTAssertTrue((outcome.reason ?? "").contains("账本"))
    }

    func testFollowUpReceiptMarksFollowUpDelivered() throws {
        // 追问行有外键约束，必须先建课程与实例。
        _ = try store.insertCourse(CourseRecord(
            id: "course_1",
            name: "操作系统",
            followUpEnabled: true,
            followUpDelayMinutes: 5,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z"
        ))
        _ = try store.insertInstanceIfAbsent(CourseInstanceRecord(
            id: "inst_1",
            courseId: "course_1",
            startsAtUTC: "2026-10-12T01:00:00Z",
            endsAtUTC: "2026-10-12T02:00:00Z",
            timezone: "Asia/Shanghai",
            status: .scheduled,
            origin: .rule,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z"
        ))
        _ = try store.insertFollowUp(FollowUpRecord(
            id: "fu_1",
            courseInstanceId: "inst_1",
            courseId: "course_1",
            state: .scheduled,
            scheduledAtUTC: "2026-10-12T02:05:00Z",
            createdAt: "2026-10-12T02:00:00Z",
            updatedAt: "2026-10-12T02:00:00Z"
        ))

        let key = FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_1")
        try insertPendingMessage(dedupeKey: key, kind: .followUp, targetRef: "fu_1")

        let outcome = try ProactiveReceiptService(store: store).apply(ProactiveInteractionReceipt(
            dedupeKey: key,
            interaction: .opened,
            at: fixedDate("2026-10-12T02:10:00Z")
        ))

        XCTAssertTrue(outcome.applied)
        XCTAssertNotNil(outcome.followUpNote)
        XCTAssertEqual(try store.followUp(id: "fu_1")?.state, .delivered, "点开追问通知后追问行也要跟进，否则重算会再问一遍")
    }
}
