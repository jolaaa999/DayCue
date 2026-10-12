import Foundation
import XCTest
@testable import DayCueCore

// 测试用的固定辅助。放在文件作用域而不是 XCTestCase 的实例方法上，
// 是为了让默认参数能直接调用它们（实例方法不能出现在默认参数里）。

private let shanghaiZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

private func fixedDate(_ string: String) -> Date {
    guard let date = RFC3339.date(fromUTC: string) else {
        fatalError("测试用的固定时间写错了：\(string)")
    }
    return date
}

private func makePlace(confirmed: Bool = true, deletedAt: String? = nil) -> PlaceRecord {
    PlaceRecord(
        id: "place_1",
        name: "三教",
        latitude: 31.2304,
        longitude: 121.4737,
        radiusMeters: 200,
        address: "教学楼",
        confirmedByUser: confirmed,
        createdAt: "2026-10-01T00:00:00Z",
        updatedAt: "2026-10-01T00:00:00Z",
        deletedAt: deletedAt
    )
}

private func makeRule(
    id: String = "rule_1",
    trigger: GeoRuleTrigger = .enter,
    minDwellSeconds: Int = 0,
    cooldownSeconds: Int = 0,
    activeFromLocal: String? = nil,
    activeToLocal: String? = nil,
    weekdays: String? = nil,
    enabled: Bool = true,
    expiresAtUTC: String? = nil,
    deletedAt: String? = nil
) -> GeoRuleRecord {
    GeoRuleRecord(
        id: id,
        placeId: "place_1",
        trigger: trigger,
        title: "到达三教",
        body: nil,
        minDwellSeconds: minDwellSeconds,
        cooldownSeconds: cooldownSeconds,
        activeFromLocal: activeFromLocal,
        activeToLocal: activeToLocal,
        weekdays: weekdays,
        enabled: enabled,
        expiresAtUTC: expiresAtUTC,
        createdAt: "2026-10-01T00:00:00Z",
        updatedAt: "2026-10-01T00:00:00Z",
        deletedAt: deletedAt
    )
}

/// 默认场景：周一上海时间 10:00，从区域外进入「三教」。
private func evaluate(
    rule: GeoRuleRecord = makeRule(),
    place: PlaceRecord? = makePlace(),
    previous: GeoRegionState = .outside,
    current: GeoRegionState = .inside,
    insideSince: Date? = nil,
    lastDeliveredAt: Date? = nil,
    granted: Bool = true,
    servicesAvailable: Bool = true,
    now: Date = fixedDate("2026-10-12T02:00:00Z")
) -> GeoRuleDecision {
    GeoRuleEvaluator.evaluate(GeoEvaluationRequest(
        rule: rule,
        place: place,
        previousState: previous,
        currentState: current,
        insideSince: insideSince,
        locationAuthorizationGranted: granted,
        locationServicesAvailable: servicesAvailable,
        lastDeliveredAt: lastDeliveredAt,
        now: now,
        timeZone: shanghaiZone
    ))
}

/// 地点规则判定测试。纯逻辑，不需要数据库，也不需要真的定位。
final class GeoRuleEvaluatorTests: XCTestCase {

    // MARK: - 位置不可用

    func testUnknownCurrentStateNeverTriggers() {
        let decision = evaluate(current: .unknown)
        XCTAssertFalse(decision.triggers, "unknown 绝不能触发")
        XCTAssertTrue(decision.isSilent, "位置不可用属于静默降级")
        XCTAssertNil(decision.dedupeKey)
    }

    func testUnknownPreviousStateNeverTriggers() {
        let decision = evaluate(previous: .unknown, current: .inside)
        XCTAssertFalse(decision.triggers, "上一次状态未知就无法判断「刚进入」，不能触发")
        XCTAssertTrue(decision.isSilent)
    }

    func testPermissionDeniedIsSilentAndProducesNoMessage() {
        let decision = evaluate(granted: false)
        XCTAssertFalse(decision.triggers)
        XCTAssertTrue(decision.isSilent)
        XCTAssertTrue(decision.reason.contains("权限"), "实际是：\(decision.reason)")
    }

    func testLocationServicesUnavailableIsSilent() {
        let decision = evaluate(servicesAvailable: false)
        XCTAssertFalse(decision.triggers)
        XCTAssertTrue(decision.isSilent)
        XCTAssertTrue(decision.reason.contains("定位服务"))
    }

    // MARK: - 触发条件

    func testEnterRequiresOutsideToInside() {
        XCTAssertTrue(evaluate(previous: .outside, current: .inside).triggers)
        XCTAssertFalse(evaluate(previous: .inside, current: .inside).triggers, "一直在里面不算「进入」")
        XCTAssertFalse(evaluate(previous: .outside, current: .outside).triggers)
    }

    func testExitRequiresInsideToOutside() {
        let exitRule = makeRule(trigger: .exit)
        XCTAssertTrue(evaluate(rule: exitRule, previous: .inside, current: .outside).triggers)
        XCTAssertFalse(evaluate(rule: exitRule, previous: .outside, current: .inside).triggers)
        // 进入规则不会因为「离开」而被触发。
        XCTAssertFalse(evaluate(rule: makeRule(trigger: .enter), previous: .inside, current: .outside).triggers)
    }

    func testDwellRequiresInsideAndMinimumDuration() {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let dwellRule = makeRule(trigger: .dwell, minDwellSeconds: 600)

        // 只待了 5 分钟。
        let tooShort = evaluate(
            rule: dwellRule,
            previous: .inside,
            current: .inside,
            insideSince: now.addingTimeInterval(-300),
            now: now
        )
        XCTAssertFalse(tooShort.triggers)
        XCTAssertTrue(tooShort.reason.contains("停留时长"), "实际是：\(tooShort.reason)")

        // 待满 10 分钟。
        XCTAssertTrue(evaluate(
            rule: dwellRule,
            previous: .inside,
            current: .inside,
            insideSince: now.addingTimeInterval(-600),
            now: now
        ).triggers)

        // 不知道从什么时候开始待着，就不能声称待够了。
        let unknownSince = evaluate(
            rule: dwellRule,
            previous: .inside,
            current: .inside,
            insideSince: nil,
            now: now
        )
        XCTAssertFalse(unknownSince.triggers)
        XCTAssertTrue(unknownSince.reason.contains("什么时候"))

        // 人根本不在区域内。
        XCTAssertFalse(evaluate(
            rule: dwellRule,
            previous: .outside,
            current: .outside,
            insideSince: now.addingTimeInterval(-3600),
            now: now
        ).triggers)
    }

    func testDwellWithZeroMinimumTriggersWhileInside() {
        let dwellRule = makeRule(trigger: .dwell, minDwellSeconds: 0)
        XCTAssertTrue(evaluate(rule: dwellRule, previous: .inside, current: .inside).triggers)
        XCTAssertFalse(evaluate(rule: dwellRule, previous: .outside, current: .outside).triggers)
    }

    // MARK: - 地点与规则状态

    func testUnconfirmedOrMissingPlaceDoesNotTrigger() {
        XCTAssertFalse(evaluate(place: makePlace(confirmed: false)).triggers, "未确认的地点不参与判定")
        XCTAssertFalse(evaluate(place: nil).triggers)
        XCTAssertFalse(evaluate(place: makePlace(deletedAt: "2026-10-02T00:00:00Z")).triggers)
    }

    func testDisabledDeletedAndExpiredRulesDoNotTrigger() {
        XCTAssertFalse(evaluate(rule: makeRule(enabled: false)).triggers)
        XCTAssertFalse(evaluate(rule: makeRule(deletedAt: "2026-10-02T00:00:00Z")).triggers)
        // 有效期到上海时间 10-12 09:00，评估时刻是 10:00，已经过期。
        XCTAssertFalse(evaluate(rule: makeRule(expiresAtUTC: "2026-10-12T01:00:00Z")).triggers)
    }

    // MARK: - 生效时段与星期

    func testActiveWindowUsesPassedTimeAndZone() {
        let morningRule = makeRule(activeFromLocal: "08:00", activeToLocal: "12:00")
        // 上海 10:00，在时段内。
        XCTAssertTrue(evaluate(rule: morningRule, now: fixedDate("2026-10-12T02:00:00Z")).triggers)

        // 上海 13:00，出了时段。
        let outside = evaluate(rule: morningRule, now: fixedDate("2026-10-12T05:00:00Z"))
        XCTAssertFalse(outside.triggers)
        XCTAssertTrue(outside.reason.contains("生效时段"), "实际是：\(outside.reason)")

        // 跨零点的时段：23:00–02:00，上海 00:30 仍然算在时段内。
        let overnight = makeRule(activeFromLocal: "23:00", activeToLocal: "02:00")
        XCTAssertTrue(evaluate(rule: overnight, now: fixedDate("2026-10-12T16:30:00Z")).triggers)

        // 没有设置时段 = 全天。
        XCTAssertTrue(evaluate(rule: makeRule(), now: fixedDate("2026-10-12T18:00:00Z")).triggers)
    }

    func testWeekdayFilterUsesPassedTime() {
        XCTAssertEqual(GeoRuleEvaluator.weekdayNumber(fixedDate("2026-10-12T02:00:00Z"), timeZone: shanghaiZone), 1)
        XCTAssertEqual(GeoRuleEvaluator.weekdayNumber(fixedDate("2026-10-13T02:00:00Z"), timeZone: shanghaiZone), 2)

        let mondayOnly = makeRule(weekdays: "1")
        XCTAssertTrue(evaluate(rule: mondayOnly, now: fixedDate("2026-10-12T02:00:00Z")).triggers)

        let tuesday = evaluate(rule: mondayOnly, now: fixedDate("2026-10-13T02:00:00Z"))
        XCTAssertFalse(tuesday.triggers)
        XCTAssertTrue(tuesday.reason.contains("生效星期"), "实际是：\(tuesday.reason)")

        // 坏数据不能被当成「每天」而默默生效。
        let broken = evaluate(rule: makeRule(weekdays: "周一周二"), now: fixedDate("2026-10-12T02:00:00Z"))
        XCTAssertFalse(broken.triggers)
        XCTAssertTrue(broken.reason.contains("无法识别"))
    }

    // MARK: - 冷却与去重键

    func testCooldownSuppressesRepeatTrigger() {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let cooled = makeRule(cooldownSeconds: 3600)

        let tooSoon = evaluate(rule: cooled, lastDeliveredAt: now.addingTimeInterval(-1800), now: now)
        XCTAssertFalse(tooSoon.triggers)
        XCTAssertTrue(tooSoon.reason.contains("冷却"), "实际是：\(tooSoon.reason)")

        XCTAssertTrue(evaluate(rule: cooled, lastDeliveredAt: now.addingTimeInterval(-7200), now: now).triggers)
    }

    func testDedupeKeyDiffersByTriggerAndDay() {
        let now = fixedDate("2026-10-12T02:00:00Z")
        let enter = makeRule(trigger: .enter)
        let exit = makeRule(trigger: .exit)
        let dwell = makeRule(trigger: .dwell, minDwellSeconds: 600)

        let enterKey = GeoRuleEvaluator.dedupeKey(rule: enter, at: now, insideSince: nil, timeZone: shanghaiZone)
        let exitKey = GeoRuleEvaluator.dedupeKey(rule: exit, at: now, insideSince: nil, timeZone: shanghaiZone)
        XCTAssertNotEqual(enterKey, exitKey)
        XCTAssertTrue(enterKey.hasPrefix("geo:rule_1:enter:"))

        let monday = GeoRuleEvaluator.dedupeKey(rule: enter, at: now, insideSince: nil, timeZone: shanghaiZone)
        let tuesday = GeoRuleEvaluator.dedupeKey(
            rule: enter,
            at: fixedDate("2026-10-13T02:00:00Z"),
            insideSince: nil,
            timeZone: shanghaiZone
        )
        XCTAssertNotEqual(monday, tuesday, "enter/exit 按天去重，跨天应重新计数")

        // dwell 按「本次连续停留的起始时刻」去重：同一次停留只提醒一次。
        let since = now.addingTimeInterval(-900)
        let first = GeoRuleEvaluator.dedupeKey(rule: dwell, at: now, insideSince: since, timeZone: shanghaiZone)
        let second = GeoRuleEvaluator.dedupeKey(
            rule: dwell,
            at: now.addingTimeInterval(300),
            insideSince: since,
            timeZone: shanghaiZone
        )
        XCTAssertEqual(first, second)
        let newStay = GeoRuleEvaluator.dedupeKey(
            rule: dwell,
            at: now,
            insideSince: now.addingTimeInterval(-60),
            timeZone: shanghaiZone
        )
        XCTAssertNotEqual(first, newStay, "离开再回来是新的停留，应该允许再提醒")
    }

    func testTriggerReasonNamesThePlace() {
        let decision = evaluate()
        XCTAssertTrue(decision.triggers)
        XCTAssertTrue(decision.reason.contains("三教"), "触发原因要说明是哪个地点，实际是：\(decision.reason)")
    }

    // MARK: - 星期编解码

    func testWeekdaysCodecRoundTrip() {
        XCTAssertEqual(GeoRuleWeekdays.encode([1, 3, 5]), "1,3,5")
        XCTAssertEqual(GeoRuleWeekdays.parse("1,3,5"), [1, 3, 5])
        XCTAssertEqual(GeoRuleWeekdays.parse(nil), GeoRuleWeekdays.all)
        XCTAssertEqual(GeoRuleWeekdays.parse(""), GeoRuleWeekdays.all)
        XCTAssertEqual(GeoRuleWeekdays.parse("abc"), [])
        XCTAssertEqual(GeoRuleWeekdays.encode(GeoRuleWeekdays.all), nil, "全选写 NULL，库里只有一种「每天」的表示")
        XCTAssertEqual(GeoRuleWeekdays.encode([]), nil)
        XCTAssertEqual(GeoRuleWeekdays.displayText(nil), "每天")
        XCTAssertEqual(GeoRuleWeekdays.displayText("abc"), "星期设置无效")
        XCTAssertEqual(GeoRuleWeekdays.displayText("1,7"), "周一、周日")
    }
}
