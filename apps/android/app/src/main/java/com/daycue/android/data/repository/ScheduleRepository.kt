package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.DayCueConverters
import com.daycue.android.data.local.dao.CourseDao
import com.daycue.android.data.local.dao.CourseInstanceDao
import com.daycue.android.data.local.dao.CourseScheduleRuleDao
import com.daycue.android.data.local.entity.CourseInstanceRecord
import com.daycue.android.data.local.entity.CourseRecord
import com.daycue.android.data.local.entity.CourseScheduleRuleRecord
import com.daycue.android.domain.followup.CourseFollowUpSpec
import com.daycue.android.domain.model.CourseInstanceOrigin
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.WeekParity
import com.daycue.android.domain.schedule.CourseInstanceExpander
import com.daycue.android.domain.schedule.ExpandedOccurrence
import com.daycue.android.domain.schedule.IcsParser
import com.daycue.android.domain.schedule.IcsScheduleDraft
import com.daycue.android.domain.schedule.IcsScheduleImporter
import com.daycue.android.domain.schedule.ScheduleRuleSpec
import com.daycue.android.domain.schedule.TermCalendar
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** ICS 导入的结果。warnings / notes 必须原样显示给用户，不能只写日志。 */
data class IcsImportReport(
    val courseCount: Int,
    val ruleCount: Int,
    val instanceCount: Int,
    val warnings: List<String>,
    val notes: List<String>,
)

/**
 * 课表仓储：课程、规则、实例。
 *
 * 「展开」这件事只在这里发生一次：界面永远读 course_instance，
 * 而不是每次进周视图都重新算规则——否则用户标过的停课/调课会被算没。
 */
class ScheduleRepository(
    private val courseDao: CourseDao,
    private val ruleDao: CourseScheduleRuleDao,
    private val instanceDao: CourseInstanceDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    // ---- 课程 ----

    suspend fun createCourse(
        name: String,
        zone: ZoneId,
        teacher: String? = null,
        location: String? = null,
        term: String? = null,
        color: String? = null,
        followUpEnabled: Boolean = false,
        followUpDelayMinutes: Int = 5,
        followUpMode: FollowUpMode = FollowUpMode.EVERY_CLASS,
    ): String {
        val now = timeSource.now()
        val id = DayCueId.new()
        courseDao.insert(
            CourseRecord(
                id = id,
                name = name.trim(),
                teacher = teacher,
                location = location,
                term = term,
                color = color,
                followUpEnabled = followUpEnabled,
                followUpDelayMinutes = followUpDelayMinutes.coerceIn(5, 15),
                followUpMode = followUpMode,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    fun observeCourses(): Flow<List<CourseRecord>> = courseDao.observeActive()

    suspend fun listCourses(): List<CourseRecord> = courseDao.listActive()

    suspend fun findCourse(courseId: String): CourseRecord? = courseDao.findById(courseId)

    suspend fun updateFollowUpSettings(courseId: String, enabled: Boolean, delayMinutes: Int, mode: FollowUpMode) {
        courseDao.updateFollowUpSettings(courseId, enabled, delayMinutes.coerceIn(5, 15), mode.raw, timeSource.now())
    }

    suspend fun setExcludedDates(courseId: String, dates: List<LocalDate>) {
        // 与 DayCueConverters 用同一套序列化，保证「迁移/仓储/转换器」三条路径写出的 TEXT 完全一致。
        val json = DayCueConverters().localDateListToJson(dates)
        courseDao.updateExcludedDates(courseId, json, timeSource.now())
    }

    suspend fun deleteCourse(courseId: String) = courseDao.softDelete(courseId, timeSource.now())

    fun courseFollowUpSpec(course: CourseRecord): CourseFollowUpSpec = CourseFollowUpSpec(
        courseId = course.id,
        enabled = course.followUpEnabled,
        delayMinutes = course.followUpDelayMinutes,
        mode = course.followUpMode,
    )

    // ---- 规则 ----

    suspend fun upsertRule(
        courseId: String,
        weekday: Int,
        sectionStart: Int,
        sectionEnd: Int,
        startTime: LocalTime,
        endTime: LocalTime,
        weekParity: WeekParity = WeekParity.ALL,
        weekStart: Int = 1,
        weekEnd: Int = 30,
        effectiveFrom: LocalDate? = null,
        effectiveTo: LocalDate? = null,
        ruleId: String = DayCueId.new(),
    ): String {
        val now = timeSource.now()
        ruleDao.upsert(
            CourseScheduleRuleRecord(
                id = ruleId,
                courseId = courseId,
                weekday = weekday.coerceIn(1, 7),
                sectionStart = sectionStart,
                sectionEnd = sectionEnd,
                startTimeLocal = startTime,
                endTimeLocal = endTime,
                weekParity = weekParity,
                weekStart = weekStart,
                weekEnd = weekEnd,
                effectiveFrom = effectiveFrom,
                effectiveTo = effectiveTo,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return ruleId
    }

    suspend fun rulesForCourse(courseId: String): List<CourseScheduleRuleRecord> = ruleDao.listByCourse(courseId)

    fun toSpec(rule: CourseScheduleRuleRecord): ScheduleRuleSpec = ScheduleRuleSpec(
        id = rule.id,
        courseId = rule.courseId,
        weekday = rule.weekday,
        sectionStart = rule.sectionStart,
        sectionEnd = rule.sectionEnd,
        startTimeLocal = rule.startTimeLocal,
        endTimeLocal = rule.endTimeLocal,
        weekParity = rule.weekParity,
        weekStart = rule.weekStart,
        weekEnd = rule.weekEnd,
        effectiveFrom = rule.effectiveFrom,
        effectiveTo = rule.effectiveTo,
    )

    // ---- 实例 ----

    /**
     * 展开并持久化。
     *
     * 幂等性来自两处：实例 id 由 (规则, 开始时刻) 确定性生成；插入用 IGNORE，
     * 因此重复执行只会保留用户已有的停课/调课状态，不会把它们覆盖回 scheduled。
     * 返回新插入的条数，便于界面提示「本次同步新增了几节课」。
     */
    suspend fun expandAndPersist(
        courseId: String,
        term: TermCalendar,
        zone: ZoneId,
        range: ClosedRange<LocalDate>? = null,
    ): Int {
        val course = courseDao.findById(courseId) ?: return 0
        val rules = ruleDao.listByCourse(courseId)
        if (rules.isEmpty()) return 0
        val excluded = course.excludedDates.toSet()

        val occurrences = rules.flatMap { rule ->
            CourseInstanceExpander.expand(
                rule = toSpec(rule),
                term = term,
                zone = zone,
                excludedDates = excluded,
                location = course.location,
            )
        }.filter { occurrence ->
            range == null || (occurrence.startDate in range)
        }

        if (occurrences.isEmpty()) return 0
        val now = timeSource.now()
        val inserted = instanceDao.insertAllIgnoringExisting(
            occurrences.map { it.toRecord(timezone = zone.id, now = now) },
        )
        return inserted.count { it != -1L }
    }

    /** 先按日期范围清掉「机器生成且用户没动过」的实例，再重新展开。手工添加/调课的记录不受影响。 */
    suspend fun regenerate(
        courseId: String,
        term: TermCalendar,
        zone: ZoneId,
        from: Instant,
        to: Instant,
    ): Int {
        ruleDao.listByCourse(courseId).forEach { rule ->
            instanceDao.deleteGeneratedScheduled(rule.id, from, to)
        }
        return expandAndPersist(courseId, term, zone)
    }

    suspend fun instancesOn(date: LocalDate, zone: ZoneId): List<CourseInstanceRecord> =
        instanceDao.listBetween(
            DayCueTime.startOfLocalDay(date, zone),
            DayCueTime.startOfNextLocalDay(date, zone),
        )

    /** 周视图：一整周的实例，按开始时刻排序。 */
    suspend fun instancesInWeek(monday: LocalDate, zone: ZoneId): List<CourseInstanceRecord> =
        instanceDao.listBetween(
            DayCueTime.startOfLocalDay(monday, zone),
            DayCueTime.startOfLocalDay(monday.plusDays(7), zone),
        )

    suspend fun instancesBetween(from: Instant, to: Instant): List<CourseInstanceRecord> =
        instanceDao.listBetween(from, to)

    suspend fun findInstance(instanceId: String): CourseInstanceRecord? = instanceDao.findById(instanceId)

    suspend fun markCancelled(instanceId: String) =
        instanceDao.updateStatus(instanceId, CourseInstanceStatus.CANCELLED, timeSource.now())

    suspend fun markScheduled(instanceId: String) =
        instanceDao.updateStatus(instanceId, CourseInstanceStatus.SCHEDULED, timeSource.now())

    suspend fun reschedule(instanceId: String, startsAt: Instant, endsAt: Instant, note: String?) =
        instanceDao.reschedule(instanceId, startsAt, endsAt, note, timeSource.now())

    suspend fun addManualInstance(
        courseId: String,
        startsAt: Instant,
        endsAt: Instant,
        zone: ZoneId,
        location: String? = null,
        note: String? = null,
    ): String {
        val now = timeSource.now()
        val id = DayCueId.new()
        instanceDao.insertIgnoringExisting(
            CourseInstanceRecord(
                id = id,
                courseId = courseId,
                ruleId = null,
                startsAtUtc = startsAt,
                endsAtUtc = endsAt,
                timezone = zone.id,
                status = CourseInstanceStatus.SCHEDULED,
                location = location,
                note = note,
                origin = CourseInstanceOrigin.MANUAL,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    // ---- ICS 导入 ----

    /**
     * 导入 ICS：解析 → 转成课程规则草稿 → 建课/补规则 → 展开实例。
     *
     * 这里不做任何猜测：解析器读不懂的行、缺结束时间的日程、无法用单双周表示的重复规则，
     * 全部进 warnings / notes 交给用户在预览页确认。返回的报告就是界面要显示的内容。
     */
    suspend fun importFromIcs(text: String, term: TermCalendar, zone: ZoneId): IcsImportReport {
        val parsed = IcsParser.parse(text)
        val warnings = ArrayList(parsed.warnings)
        val notes = ArrayList<String>()
        var courseCount = 0
        var ruleCount = 0
        var instanceCount = 0

        for (event in parsed.events) {
            val draft = IcsScheduleImporter.draftFrom(event, term, zone) ?: continue
            notes += draft.notes

            val course = courseDao.findByName(draft.summary) ?: run {
                courseCount += 1
                val id = createCourse(
                    name = draft.summary,
                    zone = zone,
                    location = draft.location,
                    term = DayCueTime.localDateString(term.firstWeekMonday),
                )
                requireNotNull(courseDao.findById(id))
            }

            upsertRule(
                courseId = course.id,
                weekday = draft.weekday,
                sectionStart = 0,
                sectionEnd = 0,
                startTime = draft.startTime,
                endTime = draft.endTime,
                weekParity = draft.weekParity,
                weekStart = draft.weekStart,
                weekEnd = draft.weekEnd,
            )
            ruleCount += 1

            if (draft.excludedDates.isNotEmpty()) {
                setExcludedDates(course.id, (course.excludedDates + draft.excludedDates).distinct())
            }
            instanceCount += expandAndPersist(course.id, term, zone)
        }

        if (parsed.events.isEmpty()) warnings += "没有从文件里读到任何日程，课表没有变化"
        return IcsImportReport(
            courseCount = courseCount,
            ruleCount = ruleCount,
            instanceCount = instanceCount,
            warnings = warnings.distinct(),
            notes = notes.distinct(),
        )
    }

    /** ICS 预览：只解析不落库，供导入页在用户确认前展示。 */
    fun previewIcs(text: String, term: TermCalendar, zone: ZoneId): List<IcsScheduleDraft> =
        IcsParser.parse(text).events.mapNotNull { IcsScheduleImporter.draftFrom(it, term, zone) }

    private fun ExpandedOccurrence.toRecord(timezone: String, now: Instant): CourseInstanceRecord =
        CourseInstanceRecord(
            id = id,
            courseId = courseId,
            ruleId = ruleId,
            startsAtUtc = startsAt,
            endsAtUtc = endsAt,
            timezone = timezone,
            status = status,
            location = location,
            note = null,
            origin = CourseInstanceOrigin.RULE,
            createdAt = now,
            updatedAt = now,
        )
}
