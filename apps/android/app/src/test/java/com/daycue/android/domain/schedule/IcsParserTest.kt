package com.daycue.android.domain.schedule

import com.daycue.android.domain.model.WeekParity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId

/** ICS 解析与导入草稿。课表导入解析错了用户就上错课，所以这里覆盖的都是真实文件里会出现的东西。 */
class IcsParserTest {

    private val shanghai: ZoneId = ZoneId.of("Asia/Shanghai")
    private val term = TermCalendar(LocalDate.of(2026, 9, 7), totalWeeks = 16)

    private fun ics(vararg lines: String): String = lines.joinToString("\r\n")

    @Test
    fun parsesFloatingWeeklyEvent() {
        val result = IcsParser.parse(
            ics(
                "BEGIN:VCALENDAR",
                "BEGIN:VEVENT",
                "UID:course-1@example.com",
                "SUMMARY:操作系统",
                "LOCATION:三教 201",
                "DTSTART;TZID=Asia/Shanghai:20260907T080000",
                "DTEND;TZID=Asia/Shanghai:20260907T093500",
                "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;UNTIL=20261231T000000Z",
                "EXDATE:20261005T080000",
                "END:VEVENT",
                "END:VCALENDAR",
            ),
        )
        assertEquals(1, result.events.size)
        val event = result.events.single()
        assertEquals("操作系统", event.summary)
        assertEquals("三教 201", event.location)
        assertTrue(event.dtStart is IcsDateTime.Floating)
        assertEquals(LocalDateTime.of(2026, 9, 7, 8, 0), (event.dtStart as IcsDateTime.Floating).local)
        assertEquals(2, event.rrule?.interval)
        assertEquals(listOf(1), event.rrule?.byDays)
        assertEquals(IcsDateTime.Utc(Instant.parse("2026-12-31T00:00:00Z")), event.rrule?.until)
        assertEquals(1, event.exDates.size)
    }

    @Test
    fun utcTimestampsBecomeAbsoluteInstants() {
        val result = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART:20260907T000000Z",
                "SUMMARY:UTC 课的",
                "END:VEVENT",
            ),
        )
        assertEquals(IcsDateTime.Utc(Instant.parse("2026-09-07T00:00:00Z")), result.events.single().dtStart)
    }

    @Test
    fun dateOnlyValuesStayDateOnly() {
        val result = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART;VALUE=DATE:20260907",
                "SUMMARY:全天事项",
                "END:VEVENT",
            ),
        )
        assertEquals(IcsDateTime.DateOnly(LocalDate.of(2026, 9, 7)), result.events.single().dtStart)
    }

    @Test
    fun foldedLinesAreJoined() {
        val text = ics(
            "BEGIN:VEVENT",
            "DTSTART:20260907T000000Z",
            "SUMMARY:很长的一个课程名字会被折",
            " 行成两行",
            "END:VEVENT",
        )
        assertEquals("很长的一个课程名字会被折行成两行", IcsParser.parse(text).events.single().summary)
    }

    @Test
    fun quotedParameterMayContainColon() {
        val property = IcsParser.splitProperty("ORGANIZER;CN=\"张:老师\":mailto:teacher@example.com")
        assertNotNull(property)
        assertEquals("ORGANIZER", property?.name)
        assertEquals("张:老师", property?.params?.get("CN"))
        assertEquals("mailto:teacher@example.com", property?.value)
    }

    @Test
    fun textEscapesAreUnescapedOnce() {
        // ICS 里的转义换行是「反斜杠 + n」两个字符，不能被当成真正的换行符处理两次。
        assertEquals("第一行\n第二行", IcsParser.unescape("第一行\\n第二行"))
        assertEquals("逗号,分号;反斜杠\\", IcsParser.unescape("逗号\\,分号\\;反斜杠\\\\"))
    }

    @Test
    fun eventWithoutDtStartIsDroppedWithWarning() {
        val result = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "SUMMARY:没有时间的日程",
                "END:VEVENT",
            ),
        )
        assertTrue(result.events.isEmpty())
        assertTrue(result.warnings.any { it.contains("缺少 DTSTART") })
    }

    @Test
    fun unsupportedFrequencyProducesWarningNotSilentGuess() {
        val result = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART:20260907T000000Z",
                "SUMMARY:每天的事",
                "RRULE:FREQ=DAILY;INTERVAL=1",
                "END:VEVENT",
            ),
        )
        assertEquals("DAILY", result.events.single().rrule?.freq)
        assertTrue(result.warnings.any { it.contains("暂不支持") })
    }

    @Test
    fun emptyCalendarSaysSoExplicitly() {
        val result = IcsParser.parse(ics("BEGIN:VCALENDAR", "END:VCALENDAR"))
        assertTrue(result.events.isEmpty())
        // 空文件必须给出可显示的提示，而不是静默什么都不做。
        assertTrue(result.warnings.any { it.contains("没有找到任何日程") })
    }

    @Test
    fun weekdayCodesMapToIsoNumbers() {
        assertEquals(1, IcsParser.weekdayToIso("MO"))
        assertEquals(7, IcsParser.weekdayToIso("SU"))
        assertEquals(3, IcsParser.weekdayToIso("+3WE"))
        assertNull(IcsParser.weekdayToIso("XX"))
    }

    @Test
    fun importerInfersOddParityForFortnightlyCourseInOddWeek() {
        val event = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART;TZID=Asia/Shanghai:20260907T080000",
                "DTEND;TZID=Asia/Shanghai:20260907T093500",
                "SUMMARY:操作系统",
                "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO",
                "END:VEVENT",
            ),
        ).events.single()

        val draft = IcsScheduleImporter.draftFrom(event, term, shanghai)
        assertNotNull(draft)
        assertEquals(WeekParity.ODD, draft?.weekParity)
        assertEquals(LocalTime.of(8, 0), draft?.startTime)
        assertEquals(LocalTime.of(9, 35), draft?.endTime)
        assertEquals(1, draft?.weekday)
        assertEquals(1, draft?.weekStart)
        assertEquals(16, draft?.weekEnd)
    }

    @Test
    fun importerInfersEvenParityFromWeekIndexSix() {
        // 2026-10-12 是第 6 周（偶数周），所以两周一次的课属双周。
        val event = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART;TZID=Asia/Shanghai:20261012T140000",
                "DTEND;TZID=Asia/Shanghai:20261012T153500",
                "SUMMARY:数据结构",
                "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO",
                "END:VEVENT",
            ),
        ).events.single()

        assertEquals(WeekParity.EVEN, IcsScheduleImporter.draftFrom(event, term, shanghai)?.weekParity)
    }

    @Test
    fun importerFlagsMissingEndTimeInsteadOfInventingSilently() {
        val event = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART;TZID=Asia/Shanghai:20260907T080000",
                "SUMMARY:没有结束时间",
                "END:VEVENT",
            ),
        ).events.single()

        val draft = IcsScheduleImporter.draftFrom(event, term, shanghai)
        assertEquals(LocalTime.of(8, 45), draft?.endTime)
        assertTrue(draft?.notes?.any { it.contains("没有结束时间") } == true)
    }

    @Test
    fun importerRejectsEventBeforeTermStart() {
        val event = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART;TZID=Asia/Shanghai:20260831T080000",
                "SUMMARY:开学前的课",
                "END:VEVENT",
            ),
        ).events.single()

        assertNull(IcsScheduleImporter.draftFrom(event, term, shanghai))
    }

    @Test
    fun importerCarriesExcludedDates() {
        val event = IcsParser.parse(
            ics(
                "BEGIN:VEVENT",
                "DTSTART;TZID=Asia/Shanghai:20260907T080000",
                "DTEND;TZID=Asia/Shanghai:20260907T093500",
                "SUMMARY:操作系统",
                "EXDATE:20261005T080000,20261019T080000",
                "END:VEVENT",
            ),
        ).events.single()

        val draft = IcsScheduleImporter.draftFrom(event, term, shanghai)
        assertEquals(
            listOf(LocalDate.of(2026, 10, 5), LocalDate.of(2026, 10, 19)),
            draft?.excludedDates,
        )
    }
}
