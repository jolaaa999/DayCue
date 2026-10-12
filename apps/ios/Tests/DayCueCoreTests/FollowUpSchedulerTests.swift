import Foundation
import XCTest
@testable import DayCueCore

/// 课后追问调度测试。
///
/// 所有基准时刻（实例起止、课程延迟、now）都显式传入，
/// 不读系统时钟，所以在任何日期执行结果都一致。
final class FollowUpSchedulerTests: XCTestCase {

    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private let courseId = "course_ops"
    private let instanceId = "inst_ops_1"

    private func utc(_ text: String) -> Date {
        RFC3339.date(fromUTC: text)!
    }

    private func course(followUpEnabled: Bool = true, delayMinutes: Int = 10) -> CourseRecord {
        CourseRecord(
            id: courseId,
            name: "操作系统",
            followUpEnabled: followUpEnabled,
            followUpDelayMinutes: delayMinutes,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    /// 周一 08:00–09:40（+08:00），对应 UTC 00:00–01:40。
    private func instance(
        id: String? = nil,
        status: CourseInstanceStatus = .scheduled,
        startsAtUTC: String = "2026-03-02T00:00:00Z",
        endsAtUTC: String = "2026-03-02T01:40:00Z"
    ) -> CourseInstanceRecord {
        CourseInstanceRecord(
            id: id ?? instanceId,
            courseId: courseId,
            ruleId: "rule_ops",
            startsAtUTC: startsAtUTC,
            endsAtUTC: endsAtUTC,
            timezone: "Asia/Shanghai",
            status: status,
            origin: .rule,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    private func followUp(
        state: FollowUpState = .scheduled,
        scheduledAtUTC: String = "2026-03-02T01:50:00Z",
        snoozeUntilUTC: String? = nil,
        attempt: Int = 0,
        courseInstanceId: String? = nil
    ) -> FollowUpRecord {
        let instanceId = courseInstanceId ?? self.instanceId
        return FollowUpRecord(
            id: FollowUpScheduler.stableFollowUpId(courseInstanceId: instanceId),
            courseInstanceId: instanceId,
            courseId: courseId,
            state: state,
            scheduledAtUTC: scheduledAtUTC,
            snoozeUntilUTC: snoozeUntilUTC,
            attempt: attempt,
            createdAt: "2026-03-01T00:00:00Z",
            updatedAt: "2026-03-01T00:00:00Z"
        )
    }

    private func request(
        instances: [CourseInstanceRecord],
        course: CourseRecord? = nil,
        existing: [FollowUpRecord] = [],
        now: Date
    ) -> FollowUpSchedulingRequest {
        FollowUpSchedulingRequest(
            instances: instances,
            coursesById: [courseId: course ?? self.course()],
            existingFollowUps: existing,
            now: now
        )
    }

    // MARK: - 延迟计算

    func testScheduledTimeIsEndPlusDelay() throws {
        let target = instance()

        XCTAssertEqual(
            FollowUpScheduler.scheduledAt(for: target, delayMinutes: 10),
            utc("2026-03-02T01:50:00Z")
        )
        // 负数按 0 处理：宁可立刻提醒，也不要排到过去。
        XCTAssertEqual(
            FollowUpScheduler.scheduledAt(for: target, delayMinutes: -5),
            utc("2026-03-02T01:40:00Z")
        )
        // 上限 240 分钟。
        XCTAssertEqual(
            FollowUpScheduler.scheduledAt(for: target, delayMinutes: 9999),
            utc("2026-03-02T05:40:00Z")
        )
        XCTAssertEqual(FollowUpScheduler.clampDelay(-5), 0)
        XCTAssertEqual(FollowUpScheduler.clampDelay(9999), 240)
    }

    func testScheduleUsesCourseDelayAndCreatesFollowUp() throws {
        let result = FollowUpScheduler.schedule(request(
            instances: [instance()],
            course: course(delayMinutes: 15),
            now: utc("2026-03-01T00:00:00Z")
        ))

        XCTAssertEqual(result.created.count, 1)
        let created = try XCTUnwrap(result.created.first)
        XCTAssertEqual(created.state, .scheduled)
        XCTAssertEqual(created.courseInstanceId, instanceId)
        XCTAssertEqual(RFC3339.date(fromUTC: created.scheduledAtUTC), utc("2026-03-02T01:55:00Z"))
        XCTAssertEqual(created.id, FollowUpScheduler.stableFollowUpId(courseInstanceId: instanceId))
        XCTAssertTrue(result.skipped.isEmpty)
    }

    // MARK: - 不排追问的情形

    func testCancelledInstanceIsNotScheduled() throws {
        let result = FollowUpScheduler.schedule(request(
            instances: [instance(status: .cancelled)],
            now: utc("2026-03-01T00:00:00Z")
        ))

        XCTAssertTrue(result.created.isEmpty)
        let skip = try XCTUnwrap(result.skipped.first)
        XCTAssertTrue(skip.reason.contains("停课"))
    }

    func testDisabledCourseIsNotScheduled() throws {
        let result = FollowUpScheduler.schedule(request(
            instances: [instance()],
            course: course(followUpEnabled: false),
            now: utc("2026-03-01T00:00:00Z")
        ))

        XCTAssertTrue(result.created.isEmpty)
        let skip = try XCTUnwrap(result.skipped.first)
        XCTAssertTrue(skip.reason.contains("关闭"))
    }

    func testSoftDeletedCourseIsNotScheduled() {
        var deleted = course()
        deleted.deletedAt = "2026-02-01T00:00:00Z"

        let result = FollowUpScheduler.schedule(request(
            instances: [instance()],
            course: deleted,
            now: utc("2026-03-01T00:00:00Z")
        ))

        // 课程被软删除后 isEnabled 为 false，等同于开关关闭。
        XCTAssertTrue(result.created.isEmpty)
        XCTAssertFalse(result.skipped.isEmpty)
    }

    // MARK: - 终态与已发出

    func testTerminalFollowUpsAreNeverPickedUpAgain() {
        // answered / skipped / expired / cancelled 都是终态。
        for state in [FollowUpState.answered, .skipped, .expired, .cancelled] {
            let existing = followUp(state: state)
            let result = FollowUpScheduler.schedule(request(
                instances: [instance()],
                existing: [existing],
                now: utc("2026-03-02T02:00:00Z")
            ))

            XCTAssertTrue(result.created.isEmpty, "\(state) 是终态，不该重新生成追问")
            XCTAssertTrue(result.updated.isEmpty, "\(state) 是终态，不该被重排")
            XCTAssertTrue(result.expiredIds.isEmpty, "\(state) 是终态，不该被判过期")
            XCTAssertFalse(
                FollowUpScheduler.isPickupable(existing, at: utc("2026-03-02T02:00:00Z")),
                "\(state) 是终态，不该被拾取"
            )
        }
    }

    func testScheduledTimeChangeOnlyUpdatesScheduledFollowUp() throws {
        // 课程延迟从 10 分钟改成 30 分钟：已安排的追问要跟着走。
        let existing = followUp(scheduledAtUTC: "2026-03-02T01:50:00Z")
        let result = FollowUpScheduler.schedule(request(
            instances: [instance()],
            course: course(delayMinutes: 30),
            existing: [existing],
            now: utc("2026-03-01T00:00:00Z")
        ))

        XCTAssertTrue(result.created.isEmpty)
        let updated = try XCTUnwrap(result.updated.first)
        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(RFC3339.date(fromUTC: updated.scheduledAtUTC), utc("2026-03-02T02:10:00Z"))
    }

    func testDeliveredAndSnoozedFollowUpsAreNotRescheduled() {
        // 已发出 / 已稍后是用户明确表达过的节奏，调度器不能擅自改时间。
        for state in [FollowUpState.delivered, .snoozed] {
            let existing = followUp(state: state, snoozeUntilUTC: "2026-03-02T03:00:00Z")
            let result = FollowUpScheduler.schedule(request(
                instances: [instance()],
                course: course(delayMinutes: 30),
                existing: [existing],
                now: utc("2026-03-02T02:00:00Z")
            ))

            XCTAssertTrue(result.created.isEmpty, "\(state) 不该被重新创建")
            XCTAssertTrue(result.updated.isEmpty, "\(state) 不该被重排")
        }
    }

    // MARK: - 拾取与过期

    func testFollowUpIsPickupableOnlyAfterEffectiveTime() {
        let existing = followUp()

        // 还没到点。
        XCTAssertFalse(FollowUpScheduler.isPickupable(existing, at: utc("2026-03-02T01:49:00Z")))
        // 恰好到点即为可拾取（闭区间）。
        XCTAssertTrue(FollowUpScheduler.isPickupable(existing, at: utc("2026-03-02T01:50:00Z")))
        XCTAssertEqual(
            FollowUpScheduler.pickupable([existing], at: utc("2026-03-02T02:00:00Z")).map(\.id),
            [existing.id]
        )
    }

    func testExpiryUsesGracePeriodAndIsReportedToScheduler() {
        let existing = followUp()
        // 默认宽限 12 小时：01:50Z + 12h = 13:50Z。
        XCTAssertEqual(FollowUpScheduler.defaultGraceMinutes, 720)
        XCTAssertFalse(FollowUpScheduler.isExpired(existing, at: utc("2026-03-02T13:49:00Z")))
        XCTAssertTrue(FollowUpScheduler.isExpired(existing, at: utc("2026-03-02T13:51:00Z")))
        XCTAssertFalse(FollowUpScheduler.isPickupable(existing, at: utc("2026-03-02T13:51:00Z")))

        let expired = FollowUpScheduler.schedule(request(
            instances: [instance()],
            existing: [existing],
            now: utc("2026-03-02T13:51:00Z")
        ))
        XCTAssertEqual(expired.expiredIds, [existing.id])
        XCTAssertTrue(expired.created.isEmpty)
        XCTAssertTrue(expired.updated.isEmpty)
    }

    // MARK: - 稍后

    func testSnoozeSetsUntilAndIncrementsAttempt() throws {
        let original = followUp(state: .delivered)
        let snoozed = try XCTUnwrap(FollowUpScheduler.snoozed(
            original,
            until: utc("2026-03-02T03:00:00Z"),
            at: utc("2026-03-02T02:00:00Z")
        ))

        XCTAssertEqual(snoozed.state, .snoozed)
        XCTAssertEqual(snoozed.snoozeUntilUTC, RFC3339.utcString(from: utc("2026-03-02T03:00:00Z")))
        XCTAssertEqual(snoozed.attempt, original.attempt + 1)
        // 生效时刻必须变成稍后时间，而不是原来的 scheduledAt。
        XCTAssertEqual(FollowUpScheduler.effectiveDate(of: snoozed), utc("2026-03-02T03:00:00Z"))
        XCTAssertFalse(FollowUpScheduler.isPickupable(snoozed, at: utc("2026-03-02T02:30:00Z")))
        XCTAssertTrue(FollowUpScheduler.isPickupable(snoozed, at: utc("2026-03-02T03:00:00Z")))
    }

    func testSnoozeStopsAtMaximumAttempts() {
        let exhausted = followUp(state: .delivered, attempt: FollowUpScheduler.defaultMaximumSnoozeCount)

        // 到上限返回 nil，调用方应引导用户改为「跳过」。
        XCTAssertNil(FollowUpScheduler.snoozed(
            exhausted,
            until: utc("2026-03-02T03:00:00Z"),
            at: utc("2026-03-02T02:00:00Z")
        ))

        // 终态不允许再稍后。
        XCTAssertNil(FollowUpScheduler.snoozed(
            followUp(state: .answered),
            until: utc("2026-03-02T03:00:00Z"),
            at: utc("2026-03-02T02:00:00Z")
        ))
    }

    // MARK: - 停课取消已经排好的追问

    func testCancelPendingOnlyTouchesNonTerminalFollowUps() {
        let pending = followUp(courseInstanceId: "inst_a")
        let answered = followUp(state: .answered, courseInstanceId: "inst_b")
        let other = followUp(courseInstanceId: "inst_c")

        let cancelled = FollowUpScheduler.cancelPending(
            courseInstanceIds: ["inst_a", "inst_b"],
            in: [pending, answered, other],
            at: utc("2026-03-02T02:00:00Z")
        )

        XCTAssertEqual(cancelled.map(\.id), [pending.id])
        XCTAssertEqual(cancelled.first?.state, .cancelled)
    }
}
