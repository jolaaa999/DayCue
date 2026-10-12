import Foundation
import XCTest
@testable import DayCueCore

/// 课后追问通知的「安排前预算检查」与「设置变化后重算」测试。
///
/// 状态：已编写、未运行（本机没有 Swift 工具链）。
/// 通知安排用 RecordingNotifier 替身记录调用次数：这是**替身验证编排**，
/// 证明的是「抑制时安排环节真的没被调用」，不是系统通知中心的行为验收。
final class FollowUpNotificationTests: XCTestCase {

    private var store: DayCueStore!
    private var directory: URL!
    private let zone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

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

    private func makeCourse() -> CourseRecord {
        CourseRecord(
            id: "course_1",
            name: "操作系统",
            followUpEnabled: true,
            followUpDelayMinutes: 5,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z"
        )
    }

    private func makeFollowUp(state: FollowUpState, scheduledAtUTC: String) -> FollowUpRecord {
        FollowUpRecord(
            id: "fu_1",
            courseInstanceId: "inst_1",
            courseId: "course_1",
            state: state,
            scheduledAtUTC: scheduledAtUTC,
            createdAt: "2026-10-12T02:00:00Z",
            updatedAt: "2026-10-12T02:00:00Z"
        )
    }

    private var plannedIdentifier: String {
        ProactiveNotificationIdentifier.identifier(
            forDedupeKey: FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_1")
        )
    }

    func testScheduledFollowUpIsPlannedAndNotifierCalled() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .scheduled, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: .standard,
            timeZone: zone,
            now: now
        )

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.fireAt, fixedDate("2026-10-12T02:05:00Z"))
        XCTAssertEqual(plan.items.first?.identifier, plannedIdentifier)
        XCTAssertTrue(plan.suppressions.isEmpty)
        XCTAssertTrue((plan.items.first?.body ?? "").contains("操作系统"))

        let notifier = RecordingNotifier()
        let outcome = try await FollowUpNotificationRunner(store: store, notifier: notifier)
            .apply(plan, at: now)

        XCTAssertEqual(notifier.scheduleCallCount, 1, "预算允许时必须真的安排通知")
        XCTAssertEqual(outcome.scheduledCount, 1)
        XCTAssertEqual(
            try store.proactiveMessage(dedupeKey: FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_1"))?.state,
            .pending
        )
    }

    func testQuietWindowBeyondExpiryPreventsFollowUpScheduling() async throws {
        // 上海周一 23:00，静默时段内；宽限期只有 30 分钟，顺延到次日 07:00 已越过有效期。
        let now = fixedDate("2026-10-12T15:00:00Z")
        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .scheduled, scheduledAtUTC: "2026-10-12T15:00:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: .standard,
            timeZone: zone,
            now: now,
            graceMinutes: 30
        )

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.suppressions.count, 1)
        XCTAssertEqual(plan.suppressions.first?.state, .suppressed)
        XCTAssertTrue((plan.suppressions.first?.reason ?? "").contains("有效期"))
        XCTAssertTrue(plan.identifiersToCancel.contains(plannedIdentifier))

        let notifier = RecordingNotifier()
        let outcome = try await FollowUpNotificationRunner(store: store, notifier: notifier)
            .apply(plan, at: now)

        XCTAssertEqual(notifier.scheduleCallCount, 0, "被静默顺延作废时安排环节必须真的没被调用")
        XCTAssertEqual(notifier.cancelCallCount, 1)
        XCTAssertEqual(outcome.scheduledCount, 0)
        XCTAssertEqual(outcome.suppressedCount, 1)

        let row = try XCTUnwrap(try store.proactiveMessage(
            dedupeKey: FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_1")
        ))
        XCTAssertEqual(row.state, .suppressed)
        XCTAssertFalse(row.suppressReason?.isEmpty ?? true, "抑制必须留下可解释的记录")
    }

    func testZeroDailyLimitSuppressesFollowUpAndSkipsScheduling() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        var config = ProactiveBudgetConfig.standard
        config.setDailyLimit(0, for: .followUp)

        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .scheduled, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: config,
            timeZone: zone,
            now: now
        )

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue((plan.suppressions.first?.reason ?? "").contains("预算是 0"))

        let notifier = RecordingNotifier()
        _ = try await FollowUpNotificationRunner(store: store, notifier: notifier).apply(plan, at: now)
        XCTAssertEqual(notifier.scheduleCallCount, 0)
    }

    func testTerminalFollowUpCancelsOldNotification() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .answered, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: .standard,
            timeZone: zone,
            now: now,
            currentlyScheduledIdentifiers: [plannedIdentifier]
        )

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.identifiersToCancel.contains(plannedIdentifier), "终态追问的旧通知必须被取消")
        XCTAssertEqual(plan.suppressions.first?.state, .cancelled)

        let notifier = RecordingNotifier()
        let outcome = try await FollowUpNotificationRunner(store: store, notifier: notifier)
            .apply(plan, at: now)

        XCTAssertEqual(notifier.cancelCallCount, 1)
        XCTAssertEqual(notifier.scheduleCallCount, 0)
        XCTAssertEqual(outcome.cancelledCount, 1)
    }

    func testDeliveredFollowUpIsNotReplanned() {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .delivered, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: .standard,
            timeZone: zone,
            now: now,
            currentlyScheduledIdentifiers: [plannedIdentifier]
        )

        XCTAssertTrue(plan.items.isEmpty, "已经发出过的追问不能重排，否则会被问两遍")
        XCTAssertTrue(plan.identifiersToCancel.contains(plannedIdentifier))
    }

    func testSettingsChangeCancelsWildRegistrations() {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let ghost = ProactiveNotificationIdentifier.identifier(
            forDedupeKey: FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_ghost")
        )

        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .scheduled, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: .standard,
            timeZone: zone,
            now: now,
            currentlyScheduledIdentifiers: [plannedIdentifier, ghost]
        )

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertTrue(plan.identifiersToCancel.contains(ghost), "系统里多出来的追问通知必须被清掉，不能留野注册")
        XCTAssertFalse(plan.identifiersToCancel.contains(plannedIdentifier), "本轮仍要保留的通知不能被误取消")
    }

    func testExpiredFollowUpIsRecordedAsExpired() async throws {
        // 追问时刻是 10-12 02:05，宽限期按默认 12 小时；评估时刻已经过了一整天。
        let now = fixedDate("2026-10-13T20:00:00Z")
        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .scheduled, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: [],
            config: .standard,
            timeZone: zone,
            now: now
        )

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.suppressions.first?.state, .expired)

        let notifier = RecordingNotifier()
        _ = try await FollowUpNotificationRunner(store: store, notifier: notifier).apply(plan, at: now)

        XCTAssertEqual(notifier.scheduleCallCount, 0)
        XCTAssertEqual(
            try store.proactiveMessage(dedupeKey: FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_1"))?.state,
            .expired
        )
    }

    func testOwnLedgerRowDoesNotBlockReplanning() async throws {
        // 账本里已有这个追问的抑制行（例如上一次预算为 0），设置调大后必须能重新排上。
        let now = fixedDate("2026-10-12T02:00:00Z")
        let key = FollowUpNotificationPlanner.dedupeKey(followUpId: "fu_1")
        _ = try store.recordProactiveMessage(ProactiveMessageRecord(
            kind: .followUp,
            dedupeKey: key,
            targetRef: "fu_1",
            state: .suppressed,
            suppressReason: "今天的课后追问已经用满 0 条。",
            scheduledAtUTC: "2026-10-12T01:00:00Z",
            deliveredAtUTC: nil,
            expiresAtUTC: nil,
            createdAt: "2026-10-12T01:00:00Z",
            updatedAt: "2026-10-12T01:00:00Z"
        ))

        let plan = FollowUpNotificationPlanner.plan(
            followUps: [makeFollowUp(state: .scheduled, scheduledAtUTC: "2026-10-12T02:05:00Z")],
            coursesById: ["course_1": makeCourse()],
            ledger: try store.proactiveLedger(since: fixedDate("2026-10-11T00:00:00Z"), limit: 100),
            config: .standard,
            timeZone: zone,
            now: now
        )

        XCTAssertEqual(plan.items.count, 1, "重算是「同一件事」，不能被自己的旧账本行当成重复")
        XCTAssertTrue(plan.suppressions.isEmpty)
    }
}
