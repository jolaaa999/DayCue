package com.daycue.android.domain.schedule

import com.daycue.android.domain.model.WeekParity
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * ICS（iCalendar）里的一个时间值。
 *
 * 三种形态必须分开保存：带 Z 的是绝对时刻；不带时区的是「浮动时间」，
 * 只能按用户当前时区解释；VALUE=DATE 是纯日期。把它们都折成 Instant 就会重演
 * 「日期型被补成午夜」那个错误。
 */
sealed interface IcsDateTime {
    data class Utc(val instant: Instant) : IcsDateTime
    data class Floating(val local: LocalDateTime) : IcsDateTime
    data class DateOnly(val date: LocalDate) : IcsDateTime

    /** 按给定时区解释成本地日期时间；DateOnly 取当天 00:00。 */
    fun toLocalDateTime(zone: ZoneId): LocalDateTime = when (this) {
        is Utc -> LocalDateTime.ofInstant(instant, zone)
        is Floating -> local
        is DateOnly -> date.atStartOfDay()
    }

    fun toInstant(zone: ZoneId): Instant = when (this) {
        is Utc -> instant
        is Floating -> local.atZone(zone).toInstant()
        is DateOnly -> date.atStartOfDay(zone).toInstant()
    }
}

/** RRULE 的子集。FREQ 不是 WEEKLY 时上层会让用户手工确认，而不是硬套。 */
data class IcsRecurrence(
    val freq: String,
    val interval: Int = 1,
    val count: Int? = null,
    val until: IcsDateTime? = null,
    /** ISO 星期：1=周一 .. 7=周日。 */
    val byDays: List<Int> = emptyList(),
)

data class IcsEvent(
    val uid: String?,
    val summary: String,
    val location: String?,
    val description: String?,
    val dtStart: IcsDateTime,
    val dtEnd: IcsDateTime?,
    val rrule: IcsRecurrence?,
    val exDates: List<IcsDateTime>,
)

data class IcsParseResult(
    val events: List<IcsEvent>,
    /** 解析中遇到但不足以失败的问题（未支持的属性、坏行）。必须显示给用户，不能静默吞掉。 */
    val warnings: List<String>,
)

/**
 * ICS 解析。
 *
 * 为什么自己写而不是引依赖：需要解析的只有 VEVENT + 一小撮 RRULE，
 * 而课表导入是一个「解析错了用户就上错课」的路径，逻辑越少越好验证。
 * 解析器不做任何猜测——读不懂的行进 warnings，缺时间的 VEVENT 直接丢弃。
 */
object IcsParser {

    private val DATE_TIME_UTC = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'")
    private val DATE_TIME_LOCAL = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
    private val DATE_ONLY = DateTimeFormatter.ofPattern("yyyyMMdd")

    fun parse(text: String): IcsParseResult {
        val warnings = ArrayList<String>()
        val events = ArrayList<IcsEvent>()

        var current: MutableMap<String, MutableList<Pair<Map<String, String>, String>>>? = null
        var currentName: String? = null

        for (line in unfold(text)) {
            if (line.isBlank()) continue
            val property = splitProperty(line)
            if (property == null) {
                warnings += "跳过无法解析的行：" + line.take(60)
                continue
            }

            val name = property.name.uppercase()
            when (name) {
                "BEGIN" -> {
                    if (property.value.uppercase() == "VEVENT") {
                        current = LinkedHashMap()
                        currentName = "VEVENT"
                    }
                }

                "END" -> {
                    if (property.value.uppercase() == "VEVENT" && currentName == "VEVENT") {
                        val fields = current
                        if (fields == null) {
                            warnings += "遇到没有内容的 VEVENT"
                        } else {
                            val event = buildEvent(fields, warnings)
                            if (event != null) events += event else warnings += "丢弃一个缺少 DTSTART 的日程"
                        }
                        current = null
                        currentName = null
                    }
                }

                else -> current?.getOrPut(name) { ArrayList() }?.add(property.params to property.value)
            }
        }

        if (currentName != null) warnings += "文件在 VEVENT 结束前就断了，最后一条未收录"
        if (events.isEmpty() && warnings.isEmpty()) warnings += "这个文件里没有找到任何日程"
        return IcsParseResult(events = events, warnings = warnings)
    }

    private fun buildEvent(
        fields: Map<String, List<Pair<Map<String, String>, String>>>,
        warnings: MutableList<String>,
    ): IcsEvent? {
        val dtStartEntry = fields["DTSTART"]?.firstOrNull() ?: return null
        val dtStart = parseDateTime(dtStartEntry.first, dtStartEntry.second)
        if (dtStart == null) {
            warnings += "DTSTART 无法解析：" + dtStartEntry.second.take(40)
            return null
        }

        val dtEndEntry = fields["DTEND"]?.firstOrNull()
        val dtEnd = dtEndEntry?.let { parseDateTime(it.first, it.second) }
        if (dtEndEntry != null && dtEnd == null) warnings += "DTEND 无法解析，已忽略结束时间"

        val rruleEntry = fields["RRULE"]?.firstOrNull()?.second
        val rrule = rruleEntry?.let { parseRecurrence(it, warnings) }

        val exDates = fields["EXDATE"].orEmpty().flatMap { (params, value) ->
            value.split(',').mapNotNull { parseDateTime(params, it.trim()) }
        }

        return IcsEvent(
            uid = fields["UID"]?.firstOrNull()?.second,
            summary = unescape(fields["SUMMARY"]?.firstOrNull()?.second.orEmpty()).ifBlank { "未命名课程" },
            location = fields["LOCATION"]?.firstOrNull()?.second?.let { unescape(it) },
            description = fields["DESCRIPTION"]?.firstOrNull()?.second?.let { unescape(it) },
            dtStart = dtStart,
            dtEnd = dtEnd,
            rrule = rrule,
            exDates = exDates,
        )
    }

    /** 折行续行：RFC5545 规定续行以空格或制表符开头，去掉该字符后直接拼接。 */
    internal fun unfold(text: String): List<String> {
        val lines = text.split("\r\n", "\n", "\r")
        val result = ArrayList<String>(lines.size)
        for (line in lines) {
            if (line.isNotEmpty() && (line[0] == ' ' || line[0] == '\t') && result.isNotEmpty()) {
                result[result.size - 1] = result[result.size - 1] + line.substring(1)
            } else {
                result += line
            }
        }
        return result
    }

    internal data class IcsProperty(val name: String, val params: Map<String, String>, val value: String)

    /**
     * 拆 "NAME;PARAM=VALUE:VALUE"。
     * 冒号可能出现在带引号的参数里（例如 CN="张:老师"），所以不能简单地按第一个冒号切。
     */
    internal fun splitProperty(line: String): IcsProperty? {
        var inQuotes = false
        var colonIndex = -1
        for (index in line.indices) {
            val char = line[index]
            if (char == '"') inQuotes = !inQuotes
            if (char == ':' && !inQuotes) {
                colonIndex = index
                break
            }
        }
        if (colonIndex <= 0) return null

        val head = line.substring(0, colonIndex)
        val value = line.substring(colonIndex + 1)
        val parts = head.split(';')
        val name = parts.first()
        val params = LinkedHashMap<String, String>()
        for (index in 1 until parts.size) {
            val raw = parts[index]
            val eq = raw.indexOf('=')
            if (eq > 0) {
                val key = raw.substring(0, eq).uppercase()
                val paramValue = raw.substring(eq + 1).trim('"')
                params[key] = paramValue
            }
        }
        return IcsProperty(name, params, value)
    }

    internal fun parseDateTime(params: Map<String, String>, value: String): IcsDateTime? {
        val text = value.trim()
        if (text.isEmpty()) return null
        val isDateOnly = params["VALUE"].equals("DATE", ignoreCase = true)
        return try {
            when {
                isDateOnly -> IcsDateTime.DateOnly(LocalDate.parse(text, DATE_ONLY))
                // 模式里已经有字面量 Z，所以先解析成 LocalDateTime 再显式按 UTC 换算；
                // 直接 Instant.from(LocalDateTime) 会抛异常。
                text.endsWith("Z") -> IcsDateTime.Utc(
                    LocalDateTime.parse(text, DATE_TIME_UTC).toInstant(java.time.ZoneOffset.UTC),
                )
                text.length == 8 -> IcsDateTime.DateOnly(LocalDate.parse(text, DATE_ONLY))
                else -> IcsDateTime.Floating(LocalDateTime.parse(text, DATE_TIME_LOCAL))
            }
        } catch (_: Exception) {
            null
        }
    }

    internal fun parseRecurrence(value: String, warnings: MutableList<String>): IcsRecurrence? {
        val parts = LinkedHashMap<String, String>()
        for (piece in value.split(';')) {
            val eq = piece.indexOf('=')
            if (eq > 0) parts[piece.substring(0, eq).uppercase()] = piece.substring(eq + 1)
        }
        val freq = parts["FREQ"]?.uppercase() ?: return null
        if (freq != "WEEKLY") warnings += "暂不支持 " + freq + " 重复规则，请手工确认上课周次"
        val byDays = parts["BYDAY"].orEmpty().split(',').mapNotNull { weekdayToIso(it.trim()) }
        return IcsRecurrence(
            freq = freq,
            interval = parts["INTERVAL"]?.toIntOrNull() ?: 1,
            count = parts["COUNT"]?.toIntOrNull(),
            until = parts["UNTIL"]?.let { parseDateTime(emptyMap(), it) },
            byDays = byDays,
        )
    }

    /** MO/TU/... → 1..7（ISO）。与 iOS schema 的 weekday 取值一致。 */
    fun weekdayToIso(code: String): Int? = when (code.uppercase().takeLast(2)) {
        "MO" -> 1
        "TU" -> 2
        "WE" -> 3
        "TH" -> 4
        "FR" -> 5
        "SA" -> 6
        "SU" -> 7
        else -> null
    }

    /** TEXT 值的反转义。顺序很重要：先拆 \\，否则 \\n 会被二次解释。 */
    internal fun unescape(value: String): String {
        val builder = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '\\' && index + 1 < value.length) {
                when (val next = value[index + 1]) {
                    'n', 'N' -> builder.append('\n')
                    ',', ';', '\\' -> builder.append(next)
                    else -> {
                        builder.append(char)
                        builder.append(next)
                    }
                }
                index += 2
            } else {
                builder.append(char)
                index += 1
            }
        }
        return builder.toString()
    }
}

/** 由 ICS 事件推出「可导入的课程规则草稿」。生成前必须在界面上让用户确认学期与时区。 */
data class IcsScheduleDraft(
    val summary: String,
    val location: String?,
    val weekday: Int,
    val startTime: LocalTime,
    val endTime: LocalTime,
    val weekParity: WeekParity,
    val weekStart: Int,
    val weekEnd: Int,
    val excludedDates: List<LocalDate>,
    /** 无法自动确定的点（不支持的重复规则、缺结束时间），必须原样显示给用户。 */
    val notes: List<String>,
)

object IcsScheduleImporter {

    /**
     * 把一条 VEVENT 折算成规则草稿。
     *
     * 关键限制：INTERVAL=2 到底是单周还是双周，取决于「这个日期落在学期的第几周」，
     * 所以必须传入学期基准。基准缺失时返回 null 交给用户手工选择，绝不默认取单周。
     */
    fun draftFrom(
        event: IcsEvent,
        term: TermCalendar,
        zone: ZoneId,
    ): IcsScheduleDraft? {
        val notes = ArrayList<String>()
        val startLocal = event.dtStart.toLocalDateTime(zone)
        val endLocal = event.dtEnd?.toLocalDateTime(zone)
        val startDate = startLocal.toLocalDate()

        val weekday = startLocal.dayOfWeek.value
        val startTime = startLocal.toLocalTime()
        // 缺结束时间时给一个 45 分钟的默认值，但必须标注，不能假装文件里写了。
        val endTime = endLocal?.toLocalTime() ?: startTime.plusMinutes(45).also {
            notes += "这条日程没有结束时间，已按 45 分钟暂时估算"
        }

        val recurrence = event.rrule
        if (recurrence != null && recurrence.freq != "WEEKLY") {
            notes += "重复规则 " + recurrence.freq + " 暂不支持，请核对上课周次"
        }

        val weekIndex = term.weekIndexOf(startDate)
        if (weekIndex == null) {
            notes += "这条日程开始于学期第 1 周之前，未纳入课表"
            return null
        }

        val interval = recurrence?.interval ?: 1
        val parity = when (interval) {
            1 -> WeekParity.ALL
            2 -> if (weekIndex % 2 == 1) WeekParity.ODD else WeekParity.EVEN
            else -> {
                notes += "每 " + interval.toString() + " 周一次的规则无法用单双周表示，请手工确认"
                WeekParity.ALL
            }
        }

        val weekEnd = recurrence?.until?.let { term.weekIndexOf(it.toLocalDateTime(zone).toLocalDate()) }
            ?: recurrence?.count?.let { weekIndex + it - 1 }
            ?: term.totalWeeks

        return IcsScheduleDraft(
            summary = event.summary,
            location = event.location,
            weekday = weekday,
            startTime = startTime,
            endTime = endTime,
            weekParity = parity,
            weekStart = weekIndex,
            weekEnd = minOf(maxOf(weekEnd, weekIndex), term.totalWeeks),
            excludedDates = event.exDates.map { it.toLocalDateTime(zone).toLocalDate() },
            notes = notes,
        )
    }
}
