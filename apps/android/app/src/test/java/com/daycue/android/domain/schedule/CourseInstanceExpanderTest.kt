package com.daycue.android.domain.schedule

import com.daycue.android.core.DayCueTime
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.WeekParity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * 课表展开。
 *
 * 2026-09-07 是周一，所以「第 N 周的周一」= 2026-09-07 + (N-1) 周；
 * 所有期望值都按这个基准手算，不用实现自己的输出当期望值。
 */
class CourseInstanceExpanderTest {

    private val shanghai: ZoneId = ZoneId.of("Asia/Shanghai")
    private val term = TermCalendar(firstWeekMonday = LocalDate.of(2026, 9, 7), totalWeeks = 16)

    private fun rule(
        weekday: Int = 1,
        weekParity: WeekParity = WeekParity.ALL,
        weekStart: Int = 1,
        weekEnd: Int = 16,
        start: LocalTime = LocalTime.of(8, 0),
        end: LocalTime = LocalTime.of(9, 35),
        effectiveFrom: LocalDate? = null,
        effectiveTo: LocalDate? = null,
    ) = ScheduleRuleSpec(
        id = "rule_1",
        courseId = "course_1",
        weekday = weekday,
        sectionStart = 1,
        sectionEnd = 2,
        startTimeLocal = start,
        endTimeLocal = end,
        weekParity = weekParity,
        weekStart = weekStart,
        weekEnd = weekEnd,
        effectiveFrom = effectiveFrom,
        effectiveTo = effectiveTo,
    )

    @Test
    fun expandsSingleWeeklySlot() {
        val occurrences = CourseInstanceExpander.expand(rule(weekStart = 1, weekEnd = 1), term, shanghai)
        assertEquals(1, occurrences.size)
        assertEquals(LocalDate.of(2026, 9, 7), occurrences.first().startDate)
        // 上海 08:00 == UTC 00:00，展开必须落到绝对时刻。
        assertEquals(Instant.parse("2026-09-07T00:00:00Z"), occurrences.first().startsAt)
        assertEquals(Instant.parse("2026-09-07T01:35:00Z"), occurrences.first().endsAt)
    }

    @Test
    fun respectsWeekRange() {
        val occurrences = CourseInstanceExpander.expand(rule(weekStart = 3, weekEnd = 4), term, shanghai)
        assertEquals(
            listOf(LocalDate.of(2026, 9, 21), LocalDate.of(2026, 9, 28)),
            occurrences.map { it.startDate },
        )
    }

    @Test
    fun oddParityKeepsOddWeeksOnly() {
        val occurrences = CourseInstanceExpander.expand(
            rule(weekParity = WeekParity.ODD, weekStart = 1, weekEnd = 4),
            term,
            shanghai,
        )
        assertEquals(
            listOf(LocalDate.of(2026, 9, 7), LocalDate.of(2026, 9, 21)),
            occurrences.map { it.startDate },
        )
        assertTrue(occurrences.all { it.weekIndex % 2 == 1 })
    }

    @Test
    fun evenParityKeepsEvenWeeksOnly() {
        val occurrences = CourseInstanceExpander.expand(
            rule(weekParity = WeekParity.EVEN, weekStart = 1, weekEnd = 4),
            term,
            shanghai,
        )
        assertEquals(
            listOf(LocalDate.of(2026, 9, 14), LocalDate.of(2026, 9, 28)),
            occurrences.map { it.startDate },
        )
    }

    @Test
    fun excludedDatesAreSkippedWithoutChangingTheRule() {
        val occurrences = CourseInstanceExpander.expand(
            rule(weekStart = 1, weekEnd = 3),
            term,
            shanghai,
            excludedDates = setOf(LocalDate.of(2026, 9, 14)),
        )
        assertEquals(
            listOf(LocalDate.of(2026, 9, 7), LocalDate.of(2026, 9, 21)),
            occurrences.map { it.startDate },
        )
        // 规则本身没有被改写：停课只影响被排除的那一天。
        assertEquals(WeekParity.ALL, rule().weekParity)
    }

    @Test
    fun effectiveRangeClampsWithoutTouchingWeekRange() {
        val occurrences = CourseInstanceExpander.expand(
            rule(weekStart = 1, weekEnd = 4, effectiveFrom = LocalDate.of(2026, 9, 14)),
            term,
            shanghai,
        )
        assertEquals(
            listOf(LocalDate.of(2026, 9, 14), LocalDate.of(2026, 9, 21), LocalDate.of(2026, 9, 28)),
            occurrences.map { it.startDate },
        )
    }

    @Test
    fun overnightClassEndsOnNextDay() {
        // 23:00–00:30 的课结束时间必须落在次日，否则课后追问会算到开始前的时刻。
        val occurrences = CourseInstanceExpander.expand(
            rule(weekStart = 1, weekEnd = 1, start = LocalTime.of(23, 0), end = LocalTime.of(0, 30)),
            term,
            shanghai,
        )
        val occurrence = occurrences.single()
        assertEquals(Instant.parse("2026-09-07T15:00:00Z"), occurrence.startsAt)
        assertEquals(Instant.parse("2026-09-07T16:30:00Z"), occurrence.endsAt)
        assertTrue(occurrence.endsAt.isAfter(occurrence.startsAt))
    }

    @Test
    fun expansionIsIdempotent() {
        val first = CourseInstanceExpander.expand(rule(), term, shanghai)
        val second = CourseInstanceExpander.expand(rule(), term, shanghai)
        assertEquals(first.map { it.id }, second.map { it.id })
        assertEquals(first.size, first.map { it.id }.distinct().size)
    }

    @Test
    fun weekEndIsClampedByTermLength() {
        val shortTerm = TermCalendar(LocalDate.of(2026, 9, 7), totalWeeks = 3)
        val occurrences = CourseInstanceExpander.expand(rule(weekEnd = 30), shortTerm, shanghai)
        assertEquals(3, occurrences.size)
    }

    @Test
    fun invalidWeekdayYieldsNoOccurrenceInsteadOfCrashing() {
        // 课表来自手输或 ICS，一条坏规则不应该让整个周视图打不开。
        assertTrue(CourseInstanceExpander.expand(rule(weekday = 0), term, shanghai).isEmpty())
        assertTrue(CourseInstanceExpander.expand(rule(weekday = 8), term, shanghai).isEmpty())
    }

    @Test
    fun expandDayKeepsOnlyRequestedDateAndSortsByStart() {
        val morning = rule(weekday = 1, start = LocalTime.of(8, 0), end = LocalTime.of(9, 35))
        val afternoon = rule(weekday = 1, start = LocalTime.of(14, 0), end = LocalTime.of(15, 35))
            .copy(id = "rule_2")
        val occurrences = CourseInstanceExpander.expandDay(
            rules = listOf(afternoon, morning),
            term = term,
            zone = shanghai,
            date = LocalDate.of(2026, 9, 7),
        )
        assertEquals(listOf("rule_1", "rule_2"), occurrences.map { it.ruleId })
        assertTrue(occurrences.all { it.startDate == LocalDate.of(2026, 9, 7) })
    }

    @Test
    fun expandDayHonoursPerCourseExcludedDates() {
        val occurrences = CourseInstanceExpander.expandDay(
            rules = listOf(rule(weekStart = 1, weekEnd = 1)),
            term = term,
            zone = shanghai,
            date = LocalDate.of(2026, 9, 7),
            excludedDatesByCourse = mapOf("course_1" to setOf(LocalDate.of(2026, 9, 7))),
        )
        assertTrue(occurrences.isEmpty())
    }

    @Test
    fun occurrenceCarriesSectionAndLocation() {
        val occurrence = CourseInstanceExpander.expand(rule(weekStart = 1, weekEnd = 1), term, shanghai, location = "三教 201")
            .single()
        assertEquals(1, occurrence.sectionStart)
        assertEquals(2, occurrence.sectionEnd)
        assertEquals("三教 201", occurrence.location)
        assertEquals(CourseInstanceStatus.SCHEDULED, occurrence.status)
        assertEquals("course_1", occurrence.courseId)
    }

    @Test
    fun termCalendarConvertsWeeksAndDatesBothWays() {
        assertEquals(LocalDate.of(2026, 10, 12), term.mondayOfWeek(6))
        assertEquals(6, term.weekIndexOf(LocalDate.of(2026, 10, 12)))
        assertEquals(1, term.weekIndexOf(LocalDate.of(2026, 9, 13)))
        // 学期开始之前没有「第 0 周」这种说法。
        assertNull(term.weekIndexOf(LocalDate.of(2026, 9, 6)))
    }

    @Test
    fun weekParityMatchesWeekNumber() {
        assertTrue(WeekParity.ALL.matchesWeek(7))
        assertTrue(WeekParity.ODD.matchesWeek(7))
        assertTrue(WeekParity.EVEN.matchesWeek(8))
    }

    @Test
    fun standardSectionTableMapsSectionsToTimes() {
        val table = SectionTimeTable.standard()
        assertEquals(LocalTime.of(8, 0) to LocalTime.of(9, 40), table.rangeFor(1, 2))
        // 找不到映射时返回 null，而不是猜一个时间。
        assertNull(table.rangeFor(1, 99))
    }
}
