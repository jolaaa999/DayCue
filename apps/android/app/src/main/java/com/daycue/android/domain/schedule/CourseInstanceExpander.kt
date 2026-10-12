package com.daycue.android.domain.schedule

import com.daycue.android.core.DayCueTime
import com.daycue.android.core.IdempotencyKey
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.WeekParity
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * 学期的日历基准。
 *
 * 为什么必须要它：单双周、第几周都是相对概念，脱离了「第 1 周的周一」就无法换算成绝对时刻。
 * 由用户在导入课表时确认一次，之后所有展开都以它为基准。
 */
data class TermCalendar(
    val firstWeekMonday: LocalDate,
    val totalWeeks: Int = 30,
) {
    init {
        require(totalWeeks in 1..60) { "学期周数必须在 1..60 之间，实际为 " + totalWeeks.toString() }
    }

    /** 第 week 周（从 1 开始）的周一。 */
    fun mondayOfWeek(week: Int): LocalDate = firstWeekMonday.plusWeeks((week - 1).toLong())

    /** 反向换算：某个日期属于第几周。早于第 1 周返回 null，而不是负数。 */
    fun weekIndexOf(date: LocalDate): Int? {
        val days = ChronoUnit.DAYS.between(firstWeekMonday, date).toLong()
        if (days < 0) return null
        return (days / 7 + 1).toInt()
    }
}

/**
 * 展开课表用的规则快照。
 *
 * 刻意不复用 Room 实体：领域层不该知道表结构，否则「改一列名」就得改一遍纯逻辑和它的测试。
 * 仓储负责实体 → 快照的映射。
 */
data class ScheduleRuleSpec(
    val id: String,
    val courseId: String,
    /** 1=周一 .. 7=周日，与 iOS schema 的 weekday 取值一致（ISO-8601）。 */
    val weekday: Int,
    val sectionStart: Int,
    val sectionEnd: Int,
    val startTimeLocal: LocalTime,
    val endTimeLocal: LocalTime,
    val weekParity: WeekParity = WeekParity.ALL,
    val weekStart: Int = 1,
    val weekEnd: Int = 30,
    val effectiveFrom: LocalDate? = null,
    val effectiveTo: LocalDate? = null,
)

/** 展开出来的一次课。id 由 (规则, 开始时刻) 确定性生成，重复展开不会产生第二份。 */
data class ExpandedOccurrence(
    val id: String,
    val courseId: String,
    val ruleId: String,
    val weekIndex: Int,
    val startDate: LocalDate,
    val startsAt: Instant,
    val endsAt: Instant,
    val sectionStart: Int,
    val sectionEnd: Int,
    val status: CourseInstanceStatus,
    val location: String?,
)

/**
 * 课表展开：把「每周几、第几周、单双周、节次」变成一串具体的课。
 *
 * 两条不可让步的约束：
 * 1. 展开是纯函数且幂等的——同一个 (规则, 学期基准) 每次得到同样的 id 与时刻，
 *    所以「同步课表时重跑一次」不会产生重复实例，也不会重复安排课后追问；
 * 2. excludedDates（停课日）只影响这一次课，不改课程规则——这也是设计文档
 *    「用户说今天没上课，只改本次实例，不永久修改规则」在数据层的最小落点。
 */
object CourseInstanceExpander {

    fun expand(
        rule: ScheduleRuleSpec,
        term: TermCalendar,
        zone: ZoneId,
        excludedDates: Set<LocalDate> = emptySet(),
        location: String? = null,
    ): List<ExpandedOccurrence> {
        // 脏数据（weekday=0 或者 8）直接不展开。这里不抛异常，是因为课表来自用户手输或 ICS，
        // 一条坏规则不应该让整个周视图打不开。
        if (rule.weekday !in 1..7) return emptyList()

        val lastWeek = minOf(rule.weekEnd, term.totalWeeks)
        if (rule.weekStart > lastWeek) return emptyList()

        val occurrences = ArrayList<ExpandedOccurrence>()
        for (week in maxOf(rule.weekStart, 1)..lastWeek) {
            if (!rule.weekParity.matchesWeek(week)) continue

            val date = term.mondayOfWeek(week).plusDays((rule.weekday - 1).toLong())
            if (rule.effectiveFrom != null && date.isBefore(rule.effectiveFrom)) continue
            if (rule.effectiveTo != null && date.isAfter(rule.effectiveTo)) continue
            if (excludedDates.contains(date)) continue

            val startsAt = DayCueTime.atLocal(date, rule.startTimeLocal, zone)
            // 跨零点的课（23:00–00:30）结束时间必须落在次日，否则 endsAt 会早于 startsAt，
            // 课后追问的触发时刻就会算到过去。
            val endsDate = if (rule.endTimeLocal.isBefore(rule.startTimeLocal)) date.plusDays(1) else date
            val endsAt = DayCueTime.atLocal(endsDate, rule.endTimeLocal, zone)

            val startsAtUtc = DayCueTime.utcString(startsAt)
            occurrences += ExpandedOccurrence(
                id = IdempotencyKey.courseInstance(rule.id, startsAtUtc),
                courseId = rule.courseId,
                ruleId = rule.id,
                weekIndex = week,
                startDate = date,
                startsAt = startsAt,
                endsAt = endsAt,
                sectionStart = rule.sectionStart,
                sectionEnd = rule.sectionEnd,
                status = CourseInstanceStatus.SCHEDULED,
                location = location,
            )
        }
        return occurrences
    }

    /**
     * 展开整个学期里某一天的所有课，用于周视图与「今天」页。
     * 排序按开始时刻——课表 UI 依赖这个顺序，调用方不必再排一次。
     */
    fun expandDay(
        rules: List<ScheduleRuleSpec>,
        term: TermCalendar,
        zone: ZoneId,
        date: LocalDate,
        excludedDatesByCourse: Map<String, Set<LocalDate>> = emptyMap(),
    ): List<ExpandedOccurrence> =
        rules.asSequence()
            .flatMap { rule ->
                expand(
                    rule = rule,
                    term = term,
                    zone = zone,
                    excludedDates = excludedDatesByCourse[rule.courseId].orEmpty(),
                ).asSequence()
            }
            .filter { it.startDate == date }
            .sortedBy { it.startsAt }
            .toList()
}

/**
 * 节次 → 上课时间的映射。
 *
 * 只在「用户只给了节次、没给具体时间」的导入场景用（例如从图片识别出的课表）。
 * 默认值取最常见的国内作息，但**必须由用户在导入预览页确认**，
 * 它不参与任何自动判断，也不会悄悄改写用户已经填好的时间。
 */
data class SectionSlot(val section: Int, val start: LocalTime, val end: LocalTime)

class SectionTimeTable(val slots: List<SectionSlot>) {

    fun slotFor(section: Int): SectionSlot? = slots.firstOrNull { it.section == section }

    /** 节次区间 → 时间区间。任何一个节次找不到映射就返回 null，绝不猜一个时间。 */
    fun rangeFor(startSection: Int, endSection: Int): Pair<LocalTime, LocalTime>? {
        val start = slotFor(startSection) ?: return null
        val end = slotFor(endSection) ?: return null
        return start.start to end.end
    }

    companion object {
        /** 常见作息：08:00 第一节，每节 45 分钟，课间 10 分钟；上午 4 节、下午 4 节、晚上 3 节。 */
        fun standard(): SectionTimeTable {
            val slots = ArrayList<SectionSlot>()
            val morning = LocalTime.of(8, 0)
            for (section in 1..4) {
                val start = morning.plusMinutes(((section - 1) * 55).toLong())
                slots += SectionSlot(section, start, start.plusMinutes(45))
            }
            val afternoon = LocalTime.of(14, 0)
            for (section in 5..8) {
                val start = afternoon.plusMinutes(((section - 5) * 55).toLong())
                slots += SectionSlot(section, start, start.plusMinutes(45))
            }
            val evening = LocalTime.of(19, 0)
            for (section in 9..11) {
                val start = evening.plusMinutes(((section - 9) * 55).toLong())
                slots += SectionSlot(section, start, start.plusMinutes(45))
            }
            return SectionTimeTable(slots)
        }
    }
}

/** 便于 UI 直接用 ISO 数字转中文星期。 */
fun weekdayDisplayName(weekday: Int): String = when (weekday) {
    DayOfWeek.MONDAY.value -> "周一"
    DayOfWeek.TUESDAY.value -> "周二"
    DayOfWeek.WEDNESDAY.value -> "周三"
    DayOfWeek.THURSDAY.value -> "周四"
    DayOfWeek.FRIDAY.value -> "周五"
    DayOfWeek.SATURDAY.value -> "周六"
    DayOfWeek.SUNDAY.value -> "周日"
    else -> "未知"
}
