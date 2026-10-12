package com.daycue.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * 时间出口的行为。
 *
 * 重点覆盖「日期型截止日绝不能被补成 UTC 午夜」这条产品红线：
 * 它一旦被破坏，用户看到的「周五之前」会变成「周五 00:00 提醒」。
 */
class DayCueTimeTest {

    private val shanghai: ZoneId = ZoneId.of("Asia/Shanghai")

    @Test
    fun utcStringTruncatesFractionalSeconds() {
        val instant = Instant.parse("2026-10-12T04:05:06.789Z")
        assertEquals("2026-10-12T04:05:06Z", DayCueTime.utcString(instant))
    }

    @Test
    fun parseInstantRejectsWallClockString() {
        // 没有时区的串必须解析失败，而不是被当成 UTC 猜一个——猜错就是 8 小时误差。
        assertNull(DayCueTime.parseInstantOrNull("2026-10-12T20:00:00"))
        assertEquals(Instant.parse("2026-10-12T20:00:00Z"), DayCueTime.parseInstantOrNull("2026-10-12T20:00:00Z"))
    }

    @Test
    fun wallClockTimeUsesGivenZone() {
        val instant = DayCueTime.parseLocalDateTimeOrNull("2026-10-12T20:00:00", shanghai)
        assertEquals(Instant.parse("2026-10-12T12:00:00Z"), instant)
    }

    @Test
    fun wallClockTimeAcceptsSpaceSeparatorAndMinutePrecision() {
        assertEquals(
            Instant.parse("2026-10-12T12:00:00Z"),
            DayCueTime.parseLocalDateTimeOrNull("2026-10-12 20:00", shanghai),
        )
    }

    @Test
    fun localDateStringIsStableForPureDates() {
        assertEquals("2026-10-16", DayCueTime.localDateString(LocalDate.of(2026, 10, 16)))
        assertEquals(LocalDate.of(2026, 10, 16), DayCueTime.parseLocalDateOrNull("2026-10-16"))
    }

    @Test
    fun localDayBoundariesUseUserZoneNotUtc() {
        val date = LocalDate.of(2026, 10, 12)
        // 上海 2026-10-12 00:00 == UTC 2026-10-11 16:00。用 UTC 日界会把凌晨的记录算到前一天。
        assertEquals(Instant.parse("2026-10-11T16:00:00Z"), DayCueTime.startOfLocalDay(date, shanghai))
        assertEquals(Instant.parse("2026-10-12T16:00:00Z"), DayCueTime.startOfNextLocalDay(date, shanghai))
    }

    @Test
    fun sameLocalDayHandlesMidnightCrossing() {
        val before = Instant.parse("2026-10-11T15:59:00Z") // 上海 23:59
        val after = Instant.parse("2026-10-11T16:01:00Z") // 上海次日 00:01
        assertFalse(DayCueTime.isSameLocalDay(before, after, shanghai))
        assertTrue(
            DayCueTime.isSameLocalDay(
                after,
                Instant.parse("2026-10-11T18:00:00Z"),
                shanghai,
            ),
        )
    }

    @Test
    fun displayDateTimeIsMinutePrecision() {
        val instant = Instant.parse("2026-10-12T12:05:00Z")
        assertEquals("2026-10-12 20:05", DayCueTime.displayDateTime(instant, shanghai))
        assertEquals("2026-10-12", DayCueTime.displayDate(instant, shanghai))
    }

    @Test
    fun atLocalComposesDateAndTime() {
        val instant = DayCueTime.atLocal(LocalDate.of(2026, 10, 12), LocalTime.of(8, 0), shanghai)
        assertEquals(Instant.parse("2026-10-12T00:00:00Z"), instant)
    }

    @Test
    fun weekStartIsMonday() {
        assertEquals(LocalDate.of(2026, 10, 12), DayCueTime.weekStart(LocalDate.of(2026, 10, 15)))
        assertEquals(LocalDate.of(2026, 10, 12), DayCueTime.weekStart(LocalDate.of(2026, 10, 12)))
    }
}
