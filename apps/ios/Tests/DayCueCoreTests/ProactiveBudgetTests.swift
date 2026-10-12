import Foundation
import XCTest
@testable import DayCueCore

/// 主动提醒预算测试。纯逻辑，不需要数据库。
///
/// 全部使用显式传入的「现在」与时区，不依赖执行日期，也不依赖机器时区。
final class ProactiveBudgetTests: XCTestCase {

    private let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    private func fixedDate(_ string: String) -> Date {
        guard let date = RFC3339.date(fromUTC: string) else {
            fatalError("测试用的固定时间写错了：\(string)")
        }
        return date
    }

    /// 账本里的一行。
    private func ledgerEntry(
        kind: ProactiveMessageKind = .geo,
        dedupeKey: String,
        state: ProactiveMessageState,
        scheduledAt: String,
        deliveredAt: String? = nil,
        expiresAt: String? = nil
    ) -> ProactiveMessageRecord {
        ProactiveMessageRecord(
            id: "pm_" + dedupeKey,
            kind: kind,
            dedupeKey: dedupeKey,
            targetRef: nil,
            state: state,
            suppressReason: nil,
            scheduledAtUTC: scheduledAt,
            deliveredAtUTC: deliveredAt,
            expiresAtUTC: expiresAt,
            createdAt: scheduledAt,
            updatedAt: scheduledAt
        )
    }

    private func config(
        dailyLimit: Int = 3,
        cooldown: TimeInterval = 0,
        quiet: [ProactiveQuietWindow] = []
    ) -> ProactiveBudgetConfig {
        ProactiveBudgetConfig(
            disabledKinds: [],
            dailyLimitByKind: [:],
            defaultDailyLimit: dailyLimit,
            cooldownByKind: [:],
            defaultCooldown: cooldown,
            quietWindows: quiet
        )
    }

    // MARK: - 预算

    func testSameDayBudgetIsExhaustedWithChineseReason() {
        let existing = ledgerEntry(
            kind: .geo,
            dedupeKey: "geo:a",
            state: .delivered,
            scheduledAt: "2026-10-12T01:00:00Z",
            deliveredAt: "2026-10-12T01:00:00Z"
        )
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:b",
            scheduledAt: fixedDate("2026-10-12T02:00:00Z"),
            ledger: [existing],
            now: fixedDate("2026-10-12T02:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 1)
        ))

        XCTAssertTrue(decision.isSuppressed)
        XCTAssertNil(decision.deliveryDate)
        XCTAssertTrue(decision.reason.contains("已经用满"), "超预算必须给出中文原因，实际是：\(decision.reason)")
        XCTAssertTrue(decision.reason.contains("明天"))
    }

    func testBudgetResetsAcrossMidnight() {
        // 上海时间 23:50 已用掉当天唯一额度。
        let existing = ledgerEntry(
            kind: .geo,
            dedupeKey: "geo:night",
            state: .delivered,
            scheduledAt: "2026-10-12T15:50:00Z",
            deliveredAt: "2026-10-12T15:50:00Z"
        )
        let sameDay = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:same",
            scheduledAt: fixedDate("2026-10-12T15:55:00Z"),
            ledger: [existing],
            now: fixedDate("2026-10-12T15:55:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 1)
        ))
        XCTAssertTrue(sameDay.isSuppressed, "同一个自然日内额度已用尽")

        // 过了零点（上海 10-13 00:10），预算必须从 0 重新算。
        let nextDay = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:next",
            scheduledAt: fixedDate("2026-10-12T16:10:00Z"),
            ledger: [existing],
            now: fixedDate("2026-10-12T16:10:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 1)
        ))
        XCTAssertFalse(nextDay.isSuppressed, "跨零点之后预算必须重置")
        XCTAssertEqual(nextDay.deliveryDate, fixedDate("2026-10-12T16:10:00Z"))

        // 直接验证按当地自然日统计的口径。
        XCTAssertEqual(
            ProactiveBudget.consumedCount(
                kind: .geo,
                onLocalDayOf: fixedDate("2026-10-12T15:00:00Z"),
                timeZone: shanghai,
                ledger: [existing]
            ),
            1
        )
        XCTAssertEqual(
            ProactiveBudget.consumedCount(
                kind: .geo,
                onLocalDayOf: fixedDate("2026-10-12T16:30:00Z"),
                timeZone: shanghai,
                ledger: [existing]
            ),
            0
        )
    }

    func testLateScheduleIsShiftedToNowNotPast() {
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .reminder,
            dedupeKey: "reminder:late",
            // 计划时间在过去（App 当时没在运行），只能从现在开始算。
            scheduledAt: fixedDate("2026-10-12T01:00:00Z"),
            now: fixedDate("2026-10-12T05:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 3)
        ))
        XCTAssertFalse(decision.isSuppressed)
        XCTAssertEqual(decision.deliveryDate, fixedDate("2026-10-12T05:00:00Z"))
    }

    func testZeroDailyLimitSuppressesWithReason() {
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:zero",
            scheduledAt: fixedDate("2026-10-12T02:00:00Z"),
            now: fixedDate("2026-10-12T02:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 0)
        ))
        XCTAssertTrue(decision.isSuppressed)
        XCTAssertTrue(decision.reason.contains("每日预算是 0"))
    }

    // MARK: - 去重

    func testDuplicateDedupeKeyIsSuppressedButStaleSuppressionDoesNotBlock() {
        let delivered = ledgerEntry(
            kind: .review,
            dedupeKey: "review:x",
            state: .delivered,
            scheduledAt: "2026-10-12T01:00:00Z",
            deliveredAt: "2026-10-12T01:00:00Z"
        )
        let duplicate = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .review,
            dedupeKey: "review:x",
            scheduledAt: fixedDate("2026-10-12T02:00:00Z"),
            ledger: [delivered],
            now: fixedDate("2026-10-12T02:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5)
        ))
        XCTAssertTrue(duplicate.isSuppressed)
        XCTAssertTrue(duplicate.reason.contains("重复"), "实际是：\(duplicate.reason)")

        // 上一次是被抑制的（没真的发出去），就不该永远挡住这个 key。
        let stale = ledgerEntry(
            kind: .review,
            dedupeKey: "review:y",
            state: .suppressed,
            scheduledAt: "2026-10-12T01:00:00Z"
        )
        let retry = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .review,
            dedupeKey: "review:y",
            scheduledAt: fixedDate("2026-10-12T02:00:00Z"),
            ledger: [stale],
            now: fixedDate("2026-10-12T02:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5)
        ))
        XCTAssertFalse(retry.isSuppressed, "被抑制过的消息不算「已经发过」")
    }

    // MARK: - 静默时段

    func testQuietHoursDeferInsteadOfDrop() throws {
        // 上海 22:30，落在 22:00–07:00 的静默时段里。
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:quiet",
            scheduledAt: fixedDate("2026-10-12T14:30:00Z"),
            now: fixedDate("2026-10-12T14:30:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5, quiet: [ProactiveQuietWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)])
        ))

        XCTAssertFalse(decision.isSuppressed, "静默时段内必须延迟而不是丢弃")
        let delivery = try XCTUnwrap(decision.deliveryDate)
        XCTAssertEqual(
            RFC3339.localString(from: delivery, timeZone: shanghai),
            "2026-10-13T07:00:00",
            "应当顺延到静默时段结束的那一刻"
        )
        XCTAssertTrue(decision.reason.contains("顺延"))
    }

    func testDeferredDeliveryBeyondExpiryIsSuppressed() {
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:quiet-expired",
            scheduledAt: fixedDate("2026-10-12T14:30:00Z"),
            // 有效期到上海时间 10-13 04:00，早于顺延后的 07:00。
            expiresAt: fixedDate("2026-10-12T20:00:00Z"),
            now: fixedDate("2026-10-12T14:30:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5, quiet: [ProactiveQuietWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)])
        ))
        XCTAssertTrue(decision.isSuppressed)
        XCTAssertTrue(decision.reason.contains("有效期"))
    }

    func testOutsideQuietHoursDeliversImmediately() {
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:daytime",
            scheduledAt: fixedDate("2026-10-12T06:00:00Z"),
            now: fixedDate("2026-10-12T06:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5, quiet: [ProactiveQuietWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)])
        ))
        XCTAssertFalse(decision.isSuppressed)
        XCTAssertEqual(decision.deliveryDate, fixedDate("2026-10-12T06:00:00Z"))
        XCTAssertTrue(decision.reason.contains("可以提醒"))
    }

    // MARK: - 冷却与过期

    func testCooldownWindowBlocksThenAllows() {
        let last = ledgerEntry(
            kind: .geo,
            dedupeKey: "geo:last",
            state: .delivered,
            scheduledAt: "2026-10-12T01:00:00Z",
            deliveredAt: "2026-10-12T01:00:00Z"
        )
        let tooSoon = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:soon",
            scheduledAt: fixedDate("2026-10-12T01:30:00Z"),
            ledger: [last],
            now: fixedDate("2026-10-12T01:30:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5, cooldown: 3600)
        ))
        XCTAssertTrue(tooSoon.isSuppressed)
        XCTAssertTrue(tooSoon.reason.contains("冷却"), "实际是：\(tooSoon.reason)")

        let later = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:later",
            scheduledAt: fixedDate("2026-10-12T03:00:00Z"),
            ledger: [last],
            now: fixedDate("2026-10-12T03:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5, cooldown: 3600)
        ))
        XCTAssertFalse(later.isSuppressed)
    }

    func testCooldownOverrideWins() {
        let last = ledgerEntry(
            kind: .geo,
            dedupeKey: "geo:rule",
            state: .delivered,
            scheduledAt: "2026-10-12T01:00:00Z",
            deliveredAt: "2026-10-12T01:00:00Z"
        )
        // 地点规则自带更短的冷却：全局 3600 秒，规则只要 600 秒。
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:rule-2",
            scheduledAt: fixedDate("2026-10-12T01:20:00Z"),
            cooldownOverride: 600,
            ledger: [last],
            now: fixedDate("2026-10-12T01:20:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5, cooldown: 3600)
        ))
        XCTAssertFalse(decision.isSuppressed)
    }

    func testExpiredMessageIsSuppressed() {
        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .reminder,
            dedupeKey: "reminder:expired",
            scheduledAt: fixedDate("2026-10-12T09:00:00Z"),
            expiresAt: fixedDate("2026-10-12T08:00:00Z"),
            now: fixedDate("2026-10-12T09:00:00Z"),
            timeZone: shanghai,
            config: config(dailyLimit: 5)
        ))
        XCTAssertTrue(decision.isSuppressed)
        XCTAssertTrue(decision.reason.contains("过期"))
    }

    // MARK: - 类别开关与配置编解码

    func testDisabledKindIsSuppressed() {
        var cfg = config(dailyLimit: 5)
        cfg.setEnabled(false, for: .geo)
        XCTAssertFalse(cfg.isEnabled(kind: .geo))
        XCTAssertTrue(cfg.isEnabled(kind: .review))

        let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
            kind: .geo,
            dedupeKey: "geo:off",
            scheduledAt: fixedDate("2026-10-12T02:00:00Z"),
            now: fixedDate("2026-10-12T02:00:00Z"),
            timeZone: shanghai,
            config: cfg
        ))
        XCTAssertTrue(decision.isSuppressed)
        XCTAssertTrue(decision.reason.contains("关掉"))
    }

    func testConfigCodecRoundTripAndFallback() {
        var cfg = ProactiveBudgetConfig.standard
        cfg.setDailyLimit(5, for: .geo)
        cfg.setCooldown(90, for: .review)
        cfg.setEnabled(false, for: .schedule)
        cfg.quietWindows = [ProactiveQuietWindow(startMinutes: 21 * 60, endMinutes: 6 * 60 + 30)]

        let encoded = ProactiveBudgetConfigCodec.encode(cfg)
        XCTAssertNotNil(encoded)
        let decoded = ProactiveBudgetConfigCodec.decode(encoded)

        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.dailyLimit(for: .geo), 5)
        XCTAssertEqual(decoded.cooldown(for: .review), 90)
        XCTAssertEqual(decoded.isEnabled(kind: .schedule), false)
        XCTAssertEqual(decoded.quietWindows.first?.startText, "21:00")
        XCTAssertEqual(decoded.quietWindows.first?.endText, "06:30")

        // 坏数据回退到默认值，而不是抛错让 App 起不来。
        XCTAssertEqual(ProactiveBudgetConfigCodec.decode("{不是合法 JSON").defaultDailyLimit, ProactiveBudgetConfig.standard.defaultDailyLimit)
        XCTAssertEqual(ProactiveBudgetConfigCodec.decode(nil).dailyLimit(for: .geo), ProactiveBudgetConfig.standard.dailyLimit(for: .geo))
    }

    func testOvernightQuietWindowContainsMidnight() {
        let window = ProactiveQuietWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(window.isOvernight)
        XCTAssertTrue(window.contains(minutesOfDay: 23 * 60))
        XCTAssertTrue(window.contains(minutesOfDay: 2 * 60))
        XCTAssertFalse(window.contains(minutesOfDay: 12 * 60))
        // 起止相同 = 没有设置静默时段，不能判成全天静默。
        XCTAssertFalse(ProactiveQuietWindow(startMinutes: 600, endMinutes: 600).contains(minutesOfDay: 600))
    }
}
