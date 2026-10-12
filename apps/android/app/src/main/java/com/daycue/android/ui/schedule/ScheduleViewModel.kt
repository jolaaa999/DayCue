package com.daycue.android.ui.schedule

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.CourseRecord
import com.daycue.android.data.local.entity.CourseScheduleRuleRecord
import com.daycue.android.data.repository.IcsImportReport
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.WeekParity
import com.daycue.android.domain.schedule.IcsParser
import com.daycue.android.domain.schedule.IcsScheduleDraft
import com.daycue.android.domain.schedule.TermCalendar
import com.daycue.android.ui.DayCueRoutes
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** 周视图里的一次课。节次只存在于规则里，所以要在这里补上，界面上才看得到「第几节」。 */
data class WeekEntry(
    val instanceId: String,
    val courseId: String,
    val courseName: String,
    val weekday: Int,
    val startsAt: Instant,
    val endsAt: Instant,
    val sectionText: String,
    val status: CourseInstanceStatus,
    val location: String?,
    val originName: String,
    val timezone: String,
)

data class ScheduleUiState(
    /** 为 null 表示还没从 timeSource 取到「现在」；界面不自己读系统时钟。 */
    val monday: LocalDate? = null,
    val weekIndex: Int? = null,
    val term: TermCalendar? = null,
    val courses: List<CourseRecord> = emptyList(),
    val entries: List<WeekEntry> = emptyList(),
    val loading: Boolean = true,
    val notice: String? = null,
    val error: String? = null,
)

/**
 * 周视图。
 *
 * 「展开」只在仓储里发生一次，界面永远读 course_instance——否则用户标过的停课与调课
 * 会在每次进页面时被重新算规则算没。本 ViewModel 只做「取一周 → 展示 → 改状态」。
 */
class ScheduleViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    private val _state = MutableStateFlow(ScheduleUiState())
    val state: StateFlow<ScheduleUiState> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                val term = container.settingsRepository.termCalendar()
                val monday = _state.value.monday
                    ?: DayCueTime.weekStart(DayCueTime.localDateOf(container.timeSource.now(), zone))
                val courses = container.scheduleRepository.listCourses()
                val coursesById = courses.associateBy { it.id }
                // 规则里才有节次，实例上没有这两列，所以按 ruleId 回查一次。
                val rulesById = courses
                    .flatMap { course -> container.scheduleRepository.rulesForCourse(course.id) }
                    .associateBy { it.id }
                val entries = container.scheduleRepository.instancesInWeek(monday, zone).map { instance ->
                    val rule = instance.ruleId?.let { rulesById[it] }
                    WeekEntry(
                        instanceId = instance.id,
                        courseId = instance.courseId,
                        courseName = coursesById[instance.courseId]?.name ?: "已删除的课程",
                        weekday = DayCueTime.localDateOf(instance.startsAtUtc, zone).dayOfWeek.value,
                        startsAt = instance.startsAtUtc,
                        endsAt = instance.endsAtUtc,
                        sectionText = sectionTextOf(rule),
                        status = instance.status,
                        location = instance.location ?: coursesById[instance.courseId]?.location,
                        originName = instance.origin.displayName,
                        timezone = instance.timezone,
                    )
                }
                _state.update {
                    it.copy(
                        monday = monday,
                        term = term,
                        weekIndex = term?.weekIndexOf(monday),
                        courses = courses,
                        entries = entries,
                        loading = false,
                    )
                }
            } catch (error: Exception) {
                _state.update { it.copy(loading = false, error = error.message ?: "读取课表失败") }
            }
        }
    }

    fun shiftWeek(weeks: Long) {
        val monday = _state.value.monday ?: return
        _state.update { it.copy(monday = monday.plusWeeks(weeks), notice = null) }
        load()
    }

    fun goToCurrentWeek() {
        viewModelScope.launch {
            val monday = DayCueTime.weekStart(DayCueTime.localDateOf(container.timeSource.now(), zone))
            _state.update { it.copy(monday = monday, notice = null) }
            load()
        }
    }

    fun clearMessages() {
        _state.update { it.copy(notice = null, error = null) }
    }

    fun saveTerm(firstWeekMondayText: String, totalWeeksText: String) {
        val date = DayCueTime.parseLocalDateOrNull(firstWeekMondayText)
        if (date == null) {
            _state.update { it.copy(error = "第一周周一要写成 2026-09-01 这样的格式。", notice = null) }
            return
        }
        val weeks = totalWeeksText.trim().toIntOrNull()
        if (weeks == null || weeks !in 1..60) {
            _state.update { it.copy(error = "学期周数必须是 1 到 60 之间的整数。", notice = null) }
            return
        }
        viewModelScope.launch {
            runCatching {
                container.settingsRepository.setTermCalendar(TermCalendar(firstWeekMonday = date, totalWeeks = weeks))
            }.onSuccess {
                _state.update {
                    it.copy(
                        monday = date,
                        notice = "学期基准已保存：第 1 周周一 " + DayCueTime.localDateString(date) + "，共 " + weeks.toString() + " 周。",
                        error = null,
                    )
                }
                load()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "保存学期基准失败") }
            }
        }
    }

    fun markCancelled(instanceId: String) = changeStatus(instanceId, cancelled = true)

    fun markScheduled(instanceId: String) = changeStatus(instanceId, cancelled = false)

    private fun changeStatus(instanceId: String, cancelled: Boolean) {
        viewModelScope.launch {
            runCatching {
                if (cancelled) {
                    container.scheduleRepository.markCancelled(instanceId)
                } else {
                    container.scheduleRepository.markScheduled(instanceId)
                }
            }.onSuccess {
                _state.update {
                    it.copy(notice = if (cancelled) "已标记为停课：只改这一次课，课程规则不受影响。" else "已恢复为正常。", error = null)
                }
                load()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "更新课程状态失败") }
            }
        }
    }

    /**
     * 调课：改的是这一次课的时间，不动课程规则。
     * 结束时刻早于开始时刻时顺延到次日，否则跨零点的课会算出 endsAt < startsAt。
     */
    fun reschedule(
        instanceId: String,
        timezoneName: String,
        dateText: String,
        startText: String,
        endText: String,
        note: String,
    ) {
        val date = DayCueTime.parseLocalDateOrNull(dateText)
        val start = parseTimeOrNull(startText)
        val end = parseTimeOrNull(endText)
        if (date == null || start == null || end == null) {
            _state.update { it.copy(error = "调课需要日期（2026-10-16）与起止时刻（20:00）。", notice = null) }
            return
        }
        val instanceZone = runCatching { ZoneId.of(timezoneName) }.getOrDefault(zone)
        viewModelScope.launch {
            runCatching {
                val startsAt = DayCueTime.atLocal(date, start, instanceZone)
                val endsDate = if (end.isBefore(start)) date.plusDays(1) else date
                val endsAt = DayCueTime.atLocal(endsDate, end, instanceZone)
                container.scheduleRepository.reschedule(instanceId, startsAt, endsAt, note.takeIf { it.isNotBlank() })
            }.onSuccess {
                _state.update { it.copy(notice = "已调课：只改这一次课。", error = null) }
                load()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "调课失败") }
            }
        }
    }

    /** 按规则重新展开实例。新增或修改规则之后必须走这一步，否则周视图里看不到课。 */
    fun regenerate(courseId: String) {
        viewModelScope.launch {
            val term = _state.value.term
            if (term == null) {
                _state.update { it.copy(error = "还没有设置学期基准，无法展开课表。请先在课表页填写第 1 周周一与总周数。", notice = null) }
                return@launch
            }
            runCatching { container.scheduleRepository.expandAndPersist(courseId, term, zone) }
                .onSuccess { added ->
                    _state.update {
                        it.copy(
                            notice = if (added == 0) "这门课没有可展开的新实例（可能规则为空，或实例已经全部存在）。" else "本次新增 " + added.toString() + " 个课程实例。",
                            error = null,
                        )
                    }
                    load()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "展开课表失败") }
                }
        }
    }

    fun deleteCourse(courseId: String) {
        viewModelScope.launch {
            runCatching { container.scheduleRepository.deleteCourse(courseId) }
                .onSuccess {
                    _state.update { it.copy(notice = "课程已删除（软删除）。它的历史课程实例不会再出现在周视图里。", error = null) }
                    load()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "删除课程失败") }
                }
        }
    }

    private fun sectionTextOf(rule: CourseScheduleRuleRecord?): String {
        if (rule == null) return "手动添加，没有固定节次"
        if (rule.sectionStart <= 0 || rule.sectionEnd <= 0) return "未标注节次"
        return "第 " + rule.sectionStart.toString() + "–" + rule.sectionEnd.toString() + " 节"
    }

    private fun parseTimeOrNull(text: String): LocalTime? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return runCatching { LocalTime.parse(trimmed.replace('：', ':')) }.getOrNull()
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { ScheduleViewModel(container) }
        }
    }
}

data class CourseEditUiState(
    val courseId: String,
    val isNew: Boolean = true,
    val name: String = "",
    val teacher: String = "",
    val location: String = "",
    val termName: String = "",
    val followUpEnabled: Boolean = false,
    val followUpDelayMinutes: Int = 5,
    val followUpMode: FollowUpMode = FollowUpMode.EVERY_CLASS,
    val rules: List<CourseScheduleRuleRecord> = emptyList(),
    val excludedDatesText: String = "",
    val loading: Boolean = true,
    val notice: String? = null,
    val error: String? = null,
    val deleted: Boolean = false,
)

/**
 * 课程编辑。
 *
 * 追问设置是这一页的重点：课后追问是否发生、延迟多久、按哪种策略，
 * 都由课程级的这三个字段决定，所以它们必须能在界面上改，而不是写死在代码里。
 */
class CourseEditViewModel(
    private val container: AppContainer,
    private val initialCourseId: String,
) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    // 新建课程复用同一条路由，路由常量里那个哨兵值就是判据。
    private val _state = MutableStateFlow(
        CourseEditUiState(courseId = initialCourseId, isNew = initialCourseId == DayCueRoutes.COURSE_ID_NEW),
    )
    val state: StateFlow<CourseEditUiState> = _state.asStateFlow()

    init {
        if (!_state.value.isNew) refresh()
    }

    private fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                val courseId = _state.value.courseId
                val course = container.scheduleRepository.findCourse(courseId)
                if (course == null) {
                    _state.update { it.copy(loading = false, error = "找不到这门课程，它可能已经被删除。") }
                    return@launch
                }
                val rules = container.scheduleRepository.rulesForCourse(courseId)
                _state.update {
                    it.copy(
                        loading = false,
                        name = course.name,
                        teacher = course.teacher.orEmpty(),
                        location = course.location.orEmpty(),
                        termName = course.term.orEmpty(),
                        followUpEnabled = course.followUpEnabled,
                        followUpDelayMinutes = course.followUpDelayMinutes,
                        followUpMode = course.followUpMode,
                        rules = rules,
                        excludedDatesText = course.excludedDates.joinToString("，") { date -> DayCueTime.localDateString(date) },
                    )
                }
            } catch (error: Exception) {
                _state.update { it.copy(loading = false, error = error.message ?: "读取课程失败") }
            }
        }
    }

    fun update(transform: (CourseEditUiState) -> CourseEditUiState) {
        _state.update { transform(it).copy(error = null) }
    }

    fun clearMessages() {
        _state.update { it.copy(notice = null, error = null) }
    }

    fun createCourse() {
        val current = _state.value
        if (current.name.isBlank()) {
            _state.update { it.copy(error = "课程名不能为空。") }
            return
        }
        viewModelScope.launch {
            runCatching {
                container.scheduleRepository.createCourse(
                    name = current.name.trim(),
                    zone = zone,
                    teacher = current.teacher.trim().takeIf { it.isNotEmpty() },
                    location = current.location.trim().takeIf { it.isNotEmpty() },
                    term = current.termName.trim().takeIf { it.isNotEmpty() },
                    followUpEnabled = current.followUpEnabled,
                    followUpDelayMinutes = current.followUpDelayMinutes,
                    followUpMode = current.followUpMode,
                )
            }.onSuccess { createdId ->
                // 建完继续留在本页：接下来要加每周规则，否则周视图里不会有任何课。
                _state.update {
                    it.copy(
                        courseId = createdId,
                        isNew = false,
                        notice = "课程已创建。接着添加每周上课规则，并保存一次课表展开。",
                        error = null,
                    )
                }
                refresh()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "创建课程失败") }
            }
        }
    }

    fun saveFollowUpSettings() {
        val current = _state.value
        if (current.isNew) {
            _state.update { it.copy(error = "请先创建课程，再设置课后追问。") }
            return
        }
        viewModelScope.launch {
            runCatching {
                container.scheduleRepository.updateFollowUpSettings(
                    courseId = current.courseId,
                    enabled = current.followUpEnabled,
                    delayMinutes = current.followUpDelayMinutes,
                    mode = current.followUpMode,
                )
            }.onSuccess {
                _state.update { it.copy(notice = "追问设置已保存。", error = null) }
                refresh()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "保存追问设置失败") }
            }
        }
    }

    fun addRule(
        weekday: Int,
        sectionStartText: String,
        sectionEndText: String,
        startText: String,
        endText: String,
        parity: WeekParity,
        weekStartText: String,
        weekEndText: String,
    ) {
        val current = _state.value
        if (current.isNew) {
            _state.update { it.copy(error = "请先创建课程，再添加上课规则。") }
            return
        }
        val sectionStart = sectionStartText.trim().toIntOrNull() ?: 0
        val sectionEnd = sectionEndText.trim().toIntOrNull() ?: 0
        val start = parseTimeOrNull(startText)
        val end = parseTimeOrNull(endText)
        if (start == null || end == null) {
            _state.update { it.copy(error = "上课与下课时间要写成 08:00 这样的格式。") }
            return
        }
        val weekStart = weekStartText.trim().toIntOrNull() ?: 1
        val weekEnd = weekEndText.trim().toIntOrNull() ?: 30
        if (weekStart < 1 || weekEnd < weekStart) {
            _state.update { it.copy(error = "周次区间不合理：结束周必须不小于开始周。") }
            return
        }
        viewModelScope.launch {
            runCatching {
                container.scheduleRepository.upsertRule(
                    courseId = current.courseId,
                    weekday = weekday,
                    sectionStart = sectionStart,
                    sectionEnd = sectionEnd,
                    startTime = start,
                    endTime = end,
                    weekParity = parity,
                    weekStart = weekStart,
                    weekEnd = weekEnd,
                )
            }.onSuccess {
                _state.update { it.copy(notice = "规则已保存。记得保存课表展开，新规则才会生成实例。", error = null) }
                refresh()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "保存规则失败") }
            }
        }
    }

    /** 停课日：用逗号分隔的日期列表；解析不出来的项直接报错，不静默丢弃。 */
    fun saveExcludedDates() {
        val current = _state.value
        if (current.isNew) {
            _state.update { it.copy(error = "请先创建课程，再设置停课日。") }
            return
        }
        val raw = current.excludedDatesText.trim()
        val dates = if (raw.isEmpty()) {
            emptyList()
        } else {
            raw.split('，', ',', '、', ' ')
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .map { DayCueTime.parseLocalDateOrNull(it) }
        }
        if (dates.any { it == null }) {
            _state.update { it.copy(error = "停课日要写成 2026-10-16 这样的格式，用逗号分隔。") }
            return
        }
        viewModelScope.launch {
            runCatching { container.scheduleRepository.setExcludedDates(current.courseId, dates.filterNotNull()) }
                .onSuccess {
                    _state.update { it.copy(notice = "停课日已保存。重新展开课表后这些日期不会再生成实例。", error = null) }
                    refresh()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "保存停课日失败") }
                }
        }
    }

    fun expandCourse() {
        val current = _state.value
        if (current.isNew) {
            _state.update { it.copy(error = "请先创建课程。") }
            return
        }
        viewModelScope.launch {
            val term = container.settingsRepository.termCalendar()
            if (term == null) {
                _state.update { it.copy(error = "还没有设置学期基准，无法展开课表。请先到课表页填写第 1 周周一与总周数。", notice = null) }
                return@launch
            }
            runCatching { container.scheduleRepository.expandAndPersist(current.courseId, term, zone) }
                .onSuccess { added ->
                    _state.update {
                        it.copy(
                            notice = if (added == 0) "没有新增实例：可能还没有规则，或实例已经全部存在。" else "新增 " + added.toString() + " 个课程实例。",
                            error = null,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "展开课表失败") }
                }
        }
    }

    fun deleteCourse() {
        val current = _state.value
        if (current.isNew) {
            _state.update { it.copy(error = "这门课程还没有创建。") }
            return
        }
        viewModelScope.launch {
            runCatching { container.scheduleRepository.deleteCourse(current.courseId) }
                .onSuccess {
                    _state.update { it.copy(notice = "课程已删除（软删除）。", error = null, deleted = true) }
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "删除课程失败") }
                }
        }
    }

    private fun parseTimeOrNull(text: String): LocalTime? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return runCatching { LocalTime.parse(trimmed.replace('：', ':')) }.getOrNull()
    }

    companion object {
        fun factory(container: AppContainer, courseId: String): ViewModelProvider.Factory = viewModelFactory {
            initializer { CourseEditViewModel(container, courseId) }
        }
    }
}

data class IcsImportUiState(
    val text: String = "",
    val term: TermCalendar? = null,
    val preview: List<IcsScheduleDraft> = emptyList(),
    val warnings: List<String> = emptyList(),
    val previewed: Boolean = false,
    val report: IcsImportReport? = null,
    val busy: Boolean = false,
    val error: String? = null,
)

/**
 * ICS 导入。
 *
 * 必须分两步：先预览（只解析、不落库），用户确认后才真正导入。
 * warnings 只能来自解析器本身——仓储的 previewIcs 只返回草稿，
 * 而那些「读不懂的行、缺结束时间」的提示正是用户确认前必须看到的。
 */
class IcsImportViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    private val _state = MutableStateFlow(IcsImportUiState())
    val state: StateFlow<IcsImportUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val term = runCatching { container.settingsRepository.termCalendar() }.getOrNull()
            _state.update { it.copy(term = term) }
        }
    }

    fun onTextChange(value: String) {
        _state.update { it.copy(text = value, previewed = false, report = null, error = null) }
    }

    fun preview() {
        val current = _state.value
        if (current.text.isBlank()) {
            _state.update { it.copy(error = "请先把 ICS 文本粘贴进来。") }
            return
        }
        val term = current.term
        if (term == null) {
            _state.update { it.copy(error = "还没有设置学期基准。ICS 里的周次要靠「第 1 周周一」换算，请先在课表页设置。") }
            return
        }
        _state.update { it.copy(busy = true, error = null, report = null) }
        val parsed = runCatching { IcsParser.parse(current.text) }
        parsed.onFailure { error ->
            _state.update { it.copy(busy = false, error = error.message ?: "解析 ICS 失败") }
        }.onSuccess { result ->
            val drafts = runCatching { container.scheduleRepository.previewIcs(current.text, term, zone) }.getOrElse { emptyList() }
            _state.update {
                it.copy(
                    busy = false,
                    preview = drafts,
                    warnings = result.warnings,
                    previewed = true,
                )
            }
        }
    }

    fun import() {
        val current = _state.value
        if (!current.previewed) {
            _state.update { it.copy(error = "请先预览，确认内容没有问题了再导入。") }
            return
        }
        val term = current.term
        if (term == null) {
            _state.update { it.copy(error = "缺少学期基准，无法导入。") }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null) }
            runCatching { container.scheduleRepository.importFromIcs(current.text, term, zone) }
                .onSuccess { report -> _state.update { it.copy(busy = false, report = report) } }
                .onFailure { error -> _state.update { it.copy(busy = false, error = error.message ?: "导入失败") } }
        }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { IcsImportViewModel(container) }
        }
    }
}
