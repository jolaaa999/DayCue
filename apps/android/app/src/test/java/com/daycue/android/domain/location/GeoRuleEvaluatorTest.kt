package com.daycue.android.domain.location

import com.daycue.android.domain.model.PlaceTrigger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/** 位置规则判定。2026-10-12 是周一，本地时区用上海。 */
class GeoRuleEvaluatorTest {

    private val shanghai: ZoneId = ZoneId.of("Asia/Shanghai")

    private fun rule(
        trigger: PlaceTrigger = PlaceTrigger.ENTER,
        minDwellSeconds: Int = 0,
        cooldownSeconds: Int = 3600,
        activeFrom: LocalTime? = null,
        activeTo: LocalTime? = null,
        weekdays: List<Int> = emptyList(),
        enabled: Boolean = true,
        expiresAt: Instant? = null,
    ) = GeoRuleSpec(
        id = "rule_1",
        placeId = "place_1",
        trigger = trigger,
        title = "到图书馆了",
        minDwellSeconds = minDwellSeconds,
        cooldownSeconds = cooldownSeconds,
        activeFromLocal = activeFrom,
        activeToLocal = activeTo,
        weekdays = weekdays,
        enabled = enabled,
        expiresAt = expiresAt,
    )

    @Test
    fun enteringThePlaceTriggers() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(),
            state = GeoState(transition = GeoTransition.ENTERED),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Trigger)
    }

    @Test
    fun stayingInsideWithoutTransitionDoesNotTriggerAgain() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(),
            state = GeoState(transition = GeoTransition.NONE),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Skip)
    }

    @Test
    fun exitRuleTriggersOnlyOnExit() {
        assertTrue(
            GeoRuleEvaluator.evaluate(
                rule(trigger = PlaceTrigger.EXIT),
                GeoState(transition = GeoTransition.EXITED),
                Instant.parse("2026-10-12T02:00:00Z"),
                shanghai,
                locationUsable = true,
            ) is GeoDecision.Trigger,
        )
        assertTrue(
            GeoRuleEvaluator.evaluate(
                rule(trigger = PlaceTrigger.EXIT),
                GeoState(transition = GeoTransition.ENTERED),
                Instant.parse("2026-10-12T02:00:00Z"),
                shanghai,
                locationUsable = true,
            ) is GeoDecision.Skip,
        )
    }

    @Test
    fun dwellDefersUntilTheDwellTimeHasPassed() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(trigger = PlaceTrigger.DWELL, minDwellSeconds = 600),
            state = GeoState(
                transition = GeoTransition.NONE,
                insideSince = Instant.parse("2026-10-12T02:00:00Z"),
            ),
            now = Instant.parse("2026-10-12T02:05:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Defer)
        assertEquals(Instant.parse("2026-10-12T02:10:00Z"), (decision as GeoDecision.Defer).until)
    }

    @Test
    fun dwellTriggersOnceTheTimeIsReached() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(trigger = PlaceTrigger.DWELL, minDwellSeconds = 600),
            state = GeoState(
                transition = GeoTransition.NONE,
                insideSince = Instant.parse("2026-10-12T02:00:00Z"),
            ),
            now = Instant.parse("2026-10-12T02:10:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Trigger)
    }

    @Test
    fun cooldownSuppressesRepeatedTriggering() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(cooldownSeconds = 3600),
            state = GeoState(
                transition = GeoTransition.ENTERED,
                lastTriggeredAt = Instant.parse("2026-10-12T02:00:00Z"),
            ),
            now = Instant.parse("2026-10-12T02:30:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Suppress)
    }

    @Test
    fun cooldownExpiryAllowsTriggeringAgain() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(cooldownSeconds = 3600),
            state = GeoState(
                transition = GeoTransition.ENTERED,
                lastTriggeredAt = Instant.parse("2026-10-12T02:00:00Z"),
            ),
            now = Instant.parse("2026-10-12T03:30:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Trigger)
    }

    @Test
    fun outsideActiveWindowIsSkipped() {
        // 夜间 20:00（本地）不在 08:00–12:00 的生效时段内。
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(activeFrom = LocalTime.of(8, 0), activeTo = LocalTime.of(12, 0)),
            state = GeoState(transition = GeoTransition.ENTERED),
            now = Instant.parse("2026-10-12T12:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Skip)
    }

    @Test
    fun overnightActiveWindowWorks() {
        // 21:00–02:00 跨零点；本地 23:00 应当有效。
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(activeFrom = LocalTime.of(21, 0), activeTo = LocalTime.of(2, 0)),
            state = GeoState(transition = GeoTransition.ENTERED),
            now = Instant.parse("2026-10-12T15:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Trigger)
    }

    @Test
    fun weekdayFilterIsHonoured() {
        // 2026-10-12 是周一，规则只在周二生效。
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(weekdays = listOf(2)),
            state = GeoState(transition = GeoTransition.ENTERED),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Skip)
    }

    @Test
    fun expiredRuleIsSkipped() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(expiresAt = Instant.parse("2026-10-11T00:00:00Z")),
            state = GeoState(transition = GeoTransition.ENTERED),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Skip)
    }

    @Test
    fun disabledRuleIsSkipped() {
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(enabled = false),
            state = GeoState(transition = GeoTransition.ENTERED),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
            locationUsable = true,
        )
        assertTrue(decision is GeoDecision.Skip)
    }

    @Test
    fun unavailableLocationSkipsInsteadOfUsingStaleCoordinates() {
        // 这是最重要的一条：定位不可用时绝不能拿陈旧位置凑合。
        val decision = GeoRuleEvaluator.evaluate(
            rule = rule(),
            state = GeoState(
                transition = GeoTransition.ENTERED,
                lastTriggeredAt = Instant.parse("2026-10-01T00:00:00Z"),
            ),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
            locationUsable = false,
        )
        assertTrue(decision is GeoDecision.Skip)
        assertTrue((decision as GeoDecision.Skip).reason.contains("定位不可用"))
    }
}
