import Foundation
import XCTest
@testable import DayCueCore

/// 课程实例展开器测试。
///
/// 所有时间基准（学期锚点、区间、时区、now）都是显式传入的，
/// 所以这些用例在哪一天执行结果都一样，不依赖「今天」。
final class CourseInstanceExpanderTests: XCTestCase {

    /// 2026-03-02 是周一（已按公历核对），拿它当第 1 周周一。
    private let defaultAnchorDate = "2026-03-02"
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private var now: Date { RFC3339.date(fromUTC: "2026-02-01T00:00:00Z")! }

    private func utc(_ text: String) -> Date {
        RFC3339.date(fromUTC: text)!
    }

    private func makeCourse() -> CourseRecord {
        CourseRecord(
            id: "course_ops",
            name: "操作系统",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    private func makeRule(
        id: String = "rule_ops",
        weekday: Int = 1,
        parity: WeekParity = .all,
        weekStart: Int = 1,
        weekEnd: Int = 8
    ) -> CourseScheduleRule {
        CourseScheduleRule(
            id: id,
            courseId: "course_ops",
            weekday: weekday,
            sectionStart: 1,
            sectionEnd: 2,
            startTimeLocal: "08:00",
            endTimeLocal: "09:40",
            weekParity: parity,
            weekStart: weekStart,
            weekEnd: weekEnd,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    private func anchor(_ firstWeekMonday: String? = nil) -> CourseTermAnchor {
        CourseTermAnchor(
            firstWeekMondayLocalDate: firstWeekMonday ?? defaultAnchorDate,
            timeZoneIdentifier: "Asia/Shanghai",
            term: "2026春"
        )
    }

    private func expand(
        rules: [CourseScheduleRule],
        rangeStart: Date,
        rangeEnd: Date,
        existing: [CourseInstanceRecord] = [],
        excludedLocalDates: Set<String> = [],
        anchorDate: String? = nil
    ) -> CourseInstanceExpansionResult {
        let request = CourseInstanceExpansionRequest(
            course: makeCourse(),
            rules: rules,
            anchor: anchor(anchorDate),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            timeZone: timeZone,
            existingInstances: existing,
            excludedLocalDates: excludedLocalDates,
            now: now
        )
        return CourseInstanceExpander.expand(request)
    }

    private func localDates(_ result: CourseInstanceExpansionResult) -> [String] {
        result.created
            .compactMap { RFC3339.date(fromUTC: $0.startsAtUTC) }
            .map { CourseInstanceExpander.localDateString($0, timeZone: timeZone) }
            .sorted()
    }

    // MARK: - 单双周

    func testOddParityProducesOnlyOddWeeks() {
        let result = expand(
            rules: [makeRule(parity: .odd, weekStart: 1, weekEnd: 6)],
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-04-30T00:00:00Z")
        )

        // 第 1/3/5 周，且都是周一。
        XCTAssertEqual(localDates(result), ["2026-03-02", "2026-03-16", "2026-03-30"])
    }

    func testEvenParityProducesOnlyEvenWeeks() {
        let result = expand(
            rules: [makeRule(parity: .even, weekStart: 1, weekEnd: 6)],
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-04-30T00:00:00Z")
        )

        // 第 2/4/6 周。
        XCTAssertEqual(localDates(result), ["2026-03-09", "2026-03-23", "2026-04-06"])
    }

    // MARK: - 区间端点

    func testRangeEndpointsAreInclusive() {
        let rule = makeRule(parity: .odd, weekStart: 1, weekEnd: 6)
        // 第一次课：03-02 08:00 +08:00 == 03-02T00:00:00Z
        let firstClass = utc("2026-03-02T00:00:00Z")
        // 最后一次课：03-30 08:00 +08:00 == 03-30T00:00:00Z
        let lastClass = utc("2026-03-30T00:00:00Z")

        // 两端都含：三次课全在。
        XCTAssertEqual(
            localDates(expand(rules: [rule], rangeStart: firstClass, rangeEnd: lastClass)),
            ["2026-03-02", "2026-03-16", "2026-03-30"]
        )

        // 终点左移一秒：最后一次被排除，证明终点是闭区间而不是开区间。
        XCTAssertEqual(
            localDates(expand(rules: [rule], rangeStart: firstClass, rangeEnd: lastClass.addingTimeInterval(-1))),
            ["2026-03-02", "2026-03-16"]
        )

        // 起点右移一秒：第一次被排除。
        XCTAssertEqual(
            localDates(expand(rules: [rule], rangeStart: firstClass.addingTimeInterval(1), rangeEnd: lastClass)),
            ["2026-03-16", "2026-03-30"]
        )
    }

    // MARK: - 跨月

    func testExpansionCrossesMonthBoundaryAndKeepsWeekday() {
        // 学期从 03-30（周一）开始，第 1-3 周正好跨过 3 月与 4 月。
        let result = expand(
            rules: [makeRule(weekStart: 1, weekEnd: 3)],
            rangeStart: utc("2026-03-29T00:00:00Z"),
            rangeEnd: utc("2026-04-20T00:00:00Z"),
            anchorDate: "2026-03-30"
        )

        XCTAssertEqual(localDates(result), ["2026-03-30", "2026-04-06", "2026-04-13"])

        // 跨月之后仍然是周一，说明展开是按本地日期逐周推进的。
        for instance in result.created {
            let start = RFC3339.date(fromUTC: instance.startsAtUTC)!
            XCTAssertEqual(CourseGridPlacement.mondayBasedWeekday(of: start, timeZone: timeZone), 1)
        }
    }

    // MARK: - 已存在实例不被覆盖

    func testCancelledInstanceIsPreservedAndNotRecreated() {
        let cancelledId = CourseInstanceExpander.stableInstanceId(
            courseId: "course_ops",
            ruleId: "rule_ops",
            localDate: "2026-03-16"
        )
        let cancelled = CourseInstanceRecord(
            id: cancelledId,
            courseId: "course_ops",
            ruleId: "rule_ops",
            startsAtUTC: "2026-03-16T00:00:00Z",
            endsAtUTC: "2026-03-16T01:40:00Z",
            timezone: "Asia/Shanghai",
            status: .cancelled,
            location: "教一101",
            note: "老师出差，停课",
            origin: .rule,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )

        let result = expand(
            rules: [makeRule(weekStart: 1, weekEnd: 4)],
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-04-05T00:00:00Z"),
            existing: [cancelled]
        )

        // 停课那一次不能被当成「缺失」再建一遍。
        XCTAssertFalse(result.created.contains { $0.id == cancelledId })
        XCTAssertTrue(result.preserved.contains { $0.id == cancelledId })
        XCTAssertEqual(localDates(result), ["2026-03-02", "2026-03-09", "2026-03-23"])

        // 用户标的状态、地点与备注一个字段都不能被覆盖。
        let kept = result.instances.first { $0.id == cancelledId }
        XCTAssertEqual(kept?.status, .cancelled)
        XCTAssertEqual(kept?.location, "教一101")
        XCTAssertEqual(kept?.note, "老师出差，停课")
    }

    func testRescheduledInstanceIsReportedAsConflictingWithoutBeingOverwritten() {
        let rescheduledId = CourseInstanceExpander.stableInstanceId(
            courseId: "course_ops",
            ruleId: "rule_ops",
            localDate: "2026-03-09"
        )
        // 调课：时间改到晚上，但 ID 仍然是「第 2 周周一」这一天推导出来的。
        let rescheduled = CourseInstanceRecord(
            id: rescheduledId,
            courseId: "course_ops",
            ruleId: "rule_ops",
            startsAtUTC: "2026-03-09T11:00:00Z",
            endsAtUTC: "2026-03-09T12:40:00Z",
            timezone: "Asia/Shanghai",
            status: .rescheduled,
            origin: .rule,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )

        let result = expand(
            rules: [makeRule(weekStart: 1, weekEnd: 4)],
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-04-05T00:00:00Z"),
            existing: [rescheduled]
        )

        XCTAssertFalse(result.created.contains { $0.id == rescheduledId })
        XCTAssertTrue(result.conflicting.contains { $0.id == rescheduledId })
        let kept = result.instances.first { $0.id == rescheduledId }
        XCTAssertEqual(kept?.status, .rescheduled)
        XCTAssertEqual(kept?.startsAtUTC, "2026-03-09T11:00:00Z")
    }

    // MARK: - 排除日期扩展点

    func testExcludedLocalDatesAreSkippedAndReported() {
        let result = expand(
            rules: [makeRule(weekStart: 1, weekEnd: 4)],
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-04-05T00:00:00Z"),
            excludedLocalDates: ["2026-03-09"]
        )

        XCTAssertEqual(localDates(result), ["2026-03-02", "2026-03-16", "2026-03-23"])
        XCTAssertEqual(result.excludedLocalDates, ["2026-03-09"])
    }

    // MARK: - 缺少学期锚点的日期解析

    func testUnparseableTermAnchorProducesNoInstances() {
        let result = expand(
            rules: [makeRule()],
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-04-05T00:00:00Z"),
            anchorDate: "不是日期"
        )

        XCTAssertTrue(result.created.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
