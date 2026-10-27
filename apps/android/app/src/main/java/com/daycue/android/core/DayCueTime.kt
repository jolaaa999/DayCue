package com.daycue.android.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * 时间处理的唯一出口。
 *
 * 为什么要把三种时间写法严格分开：契约里的 remind.utc 是绝对时刻，due.local 是用户时区的墙面时间，
 * 而 kind=date 时只有年月日。把它们压成一个 Long，就会在「日期型截止日」上凭空补出一个 UTC 午夜，
 * 而 docs/architecture.md 2.2 明确禁止这件事——用户会因此错过作业。
 *
 * 本对象没有任何「取当前时间」的方法：时间基准必须由调用方显式传入，
 * 否则领域逻辑就没法在单元测试里复现跨零点、静默时段这类场景。
 */
object DayCueTime {

    val UTC: ZoneId = ZoneOffset.UTC

    /** 墙面时间（无时区）：2026-10-12T20:00:00 */
    private val LOCAL_DATE_TIME: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss")
    /** 展示用：带空格的分钟精度 */
    private val LOCAL_MINUTE: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    /** 纯日期：2026-10-16 */
    private val LOCAL_DATE: DateTimeFormatter = DateTimeFormatter.ISO_LOCAL_DATE

    // ---- 绝对时刻 ----

    /** Instant -> RFC3339 秒精度 UTC 串。与 iOS `DayCueClock.nowUTCString` 的输出逐字符一致，便于双端对账。 */
    fun utcString(instant: Instant): String =
        DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))

    /**
     * 解析绝对时刻。只接受带 Z 或明确偏移的串；没有时区的串一律返回 null。
     * 返回 null 而不是「当作本地时间猜一个」，是因为猜错时区会让提醒差 8 小时。
     */
    fun parseInstantOrNull(text: String?): Instant? {
        if (text.isNullOrBlank()) return null
        return try {
            Instant.parse(text)
        } catch (_: Exception) {
            null
        }
    }

    // ---- 用户时区的墙面时间 ----

    /** 墙面时间 -> Instant。需要调用方给出时区，解析失败返回 null。 */
    fun parseLocalDateTimeOrNull(text: String?, zone: ZoneId): Instant? {
        if (text.isNullOrBlank()) return null
        val trimmed = text.trim()
        val local = try {
            LocalDateTime.parse(trimmed, LOCAL_DATE_TIME)
        } catch (_: Exception) {
            // 兼容 "2026-10-12 20:00:00" 与 "2026-10-12T20:00" 这两种口头常见写法。
            val normalized = trimmed.replace(' ', 'T')
            try {
                LocalDateTime.parse(if (normalized.length == 16) normalized + ":00" else normalized)
            } catch (_: Exception) {
                return null
            }
        }
        return local.atZone(zone).toInstant()
    }

    fun localDateTimeString(instant: Instant, zone: ZoneId): String =
        ZonedDateTime.ofInstant(instant, zone).format(LOCAL_DATE_TIME)

    fun localDateString(instant: Instant, zone: ZoneId): String =
        ZonedDateTime.ofInstant(instant, zone).toLocalDate().format(LOCAL_DATE)

    fun localDateOf(instant: Instant, zone: ZoneId): LocalDate =
        ZonedDateTime.ofInstant(instant, zone).toLocalDate()

    fun localTimeOf(instant: Instant, zone: ZoneId): LocalTime =
        ZonedDateTime.ofInstant(instant, zone).toLocalTime()

    /** 组合：某个本地日期的某个本地时刻 -> 绝对时刻。跨夏令时时由 java.time 处理重叠/缺口。 */
    fun atLocal(date: LocalDate, time: LocalTime, zone: ZoneId): Instant =
        ZonedDateTime.of(date, time, zone).toInstant()

    // ---- 纯日期 ----

    fun parseLocalDateOrNull(text: String?): LocalDate? {
        if (text.isNullOrBlank()) return null
        return try {
            LocalDate.parse(text.trim(), LOCAL_DATE)
        } catch (_: Exception) {
            null
        }
    }

    fun localDateString(date: LocalDate): String = date.format(LOCAL_DATE)

    // ---- 天的边界（预算重置、静默时段都按用户时区的「天」算）----

    fun startOfLocalDay(date: LocalDate, zone: ZoneId): Instant =
        date.atStartOfDay(zone).toInstant()

    /** 左闭右开区间的右端：次日零点。用右开是为了避免 23:59:59.999 这类边界漏算。 */
    fun startOfNextLocalDay(date: LocalDate, zone: ZoneId): Instant =
        date.plusDays(1).atStartOfDay(zone).toInstant()

    fun isSameLocalDay(a: Instant, b: Instant, zone: ZoneId): Boolean =
        localDateOf(a, zone) == localDateOf(b, zone)

    fun weekStart(date: LocalDate): LocalDate = date.with(DayOfWeek.MONDAY)

    // ---- 展示 ----

    /**
     * 日期型截止日只显示日期，绝不显示 00:00。
     * 这是「不伪造 UTC 午夜」在界面上的落地：显示层也不许把日期补成时刻。
     */
    fun displayDate(instant: Instant, zone: ZoneId): String = localDateString(instant, zone)

    fun displayDateTime(instant: Instant, zone: ZoneId): String =
        ZonedDateTime.ofInstant(instant, zone).format(LOCAL_MINUTE)

    /**
     * 页头用的短日期：「10月26日 周日」。
     *
     * 不交给 DateTimeFormatter 的本地化模式（"M月d日 EEEE"）：那会跟随系统语言输出
     * "Oct 26 Sunday" 或 "10月26日 星期日"，页头宽度会随系统语言跳。
     * 星期用固定中文缩写，长度稳定。
     */
    fun displayMonthDayWeekday(instant: Instant, zone: ZoneId): String {
        val date = ZonedDateTime.ofInstant(instant, zone).toLocalDate()
        return date.monthValue.toString() + "月" + date.dayOfMonth.toString() + "日 " + weekdayLabel(date.dayOfWeek)
    }

    /**
     * 列表里用的「相对日期 + 时刻」：今天 19:30 / 昨天 19:30 / 10月24日 19:30（跨年补年份）。
     *
     * 记录行原来只印 HH:mm，隔天的记录和刚写下的一模一样，用户只能靠记忆回推这是哪天的事。
     * 这里刻意不做「几分钟前」：滚动列表里相对分钟数每刷新一次就变一遍，越读越乱。
     */
    fun displayDayTime(instant: Instant, now: Instant, zone: ZoneId): String {
        val date = localDateOf(instant, zone)
        val today = localDateOf(now, zone)
        val day = when (ChronoUnit.DAYS.between(today, date)) {
            0L -> "今天"
            -1L -> "昨天"
            1L -> "明天"
            else -> if (date.year == today.year) {
                date.monthValue.toString() + "月" + date.dayOfMonth.toString() + "日"
            } else {
                date.year.toString() + "年" + date.monthValue.toString() + "月" + date.dayOfMonth.toString() + "日"
            }
        }
        return day + " " + displayClock(instant, zone)
    }

    /**
     * 只到日的短日期：「10月20日」，不是今年时补年份。
     *
     * 记忆列表原来直接印 2026-10-20 这种 ISO 串：那是机器写的格式，
     * 和别处「今天 19:30」「10月20日」的中文日期放在一起会显得像调试信息。
     */
    fun displayMonthDay(instant: Instant, now: Instant, zone: ZoneId): String {
        val date = localDateOf(instant, zone)
        val today = localDateOf(now, zone)
        return if (date.year == today.year) {
            date.monthValue.toString() + "月" + date.dayOfMonth.toString() + "日"
        } else {
            date.year.toString() + "年" + date.monthValue.toString() + "月" + date.dayOfMonth.toString() + "日"
        }
    }

    /** 两个时刻相差多少分钟（向下取整，to 在过去则为负）。只用于「还有多久」这类展示。 */
    fun minutesBetween(from: Instant, to: Instant): Long = ChronoUnit.MINUTES.between(from, to)

    /** 只给「同一天内的时段」用的时刻：18:30。跨天时段由调用方加上日期。 */
    fun displayClock(instant: Instant, zone: ZoneId): String =
        ZonedDateTime.ofInstant(instant, zone).toLocalTime().format(CLOCK)

    private val CLOCK: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")

    private fun weekdayLabel(dayOfWeek: DayOfWeek): String = when (dayOfWeek) {
        DayOfWeek.MONDAY -> "周一"
        DayOfWeek.TUESDAY -> "周二"
        DayOfWeek.WEDNESDAY -> "周三"
        DayOfWeek.THURSDAY -> "周四"
        DayOfWeek.FRIDAY -> "周五"
        DayOfWeek.SATURDAY -> "周六"
        DayOfWeek.SUNDAY -> "周日"
    }
}
