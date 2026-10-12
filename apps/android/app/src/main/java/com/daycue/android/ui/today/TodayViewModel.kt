package com.daycue.android.ui.today

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.domain.model.TaskStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** 「今天」页的一块行程。课程名从课表仓储现查，而不是让界面自己持有 map。 */
data class TodayCourseItem(
    val instanceId: String,
    val courseName: String,
    val startsAt: Instant,
    val endsAt: Instant,
    val location: String?,
    val status: CourseInstanceStatus,
)

/** 待回复的追问。只包含已经打扰过用户的（delivered / snoozed），未到点的不该出现在「待回复」里。 */
data class TodayFollowUpItem(
    val followUpId: String,
    val courseName: String,
    val at: Instant,
    val state: FollowUpState,
    val attempt: Int,
)

/** 待处理记录：还没解析完成或解析失败的捕获项。 */
data class TodayCaptureItem(
    val captureId: String,
    val kindName: String,
    val status: CaptureStatus,
    val recordedAt: Instant,
    val preview: String,
)

data class TodayUiState(
    val loading: Boolean = true,
    val now: Instant? = null,
    val nextCourse: TodayCourseItem? = null,
    val laterCourseHint: String? = null,
    val dueTodayTasks: List<TaskRecord> = emptyList(),
    val todayNotes: List<NoteRecord> = emptyList(),
    val pendingFollowUps: List<TodayFollowUpItem> = emptyList(),
    val syncIssues: List<TaskRecord> = emptyList(),
    val outboxPending: Int = 0,
    val pendingCaptures: List<TodayCaptureItem> = emptyList(),
    val notice: String? = null,
)

/**
 * 「今天」页的聚合。
 *
 * 这一页的所有内容都来自仓储：流式的部分（同步异常、outbox、记录、追问）直接收集，
 * 需要按「现在」计算的（下一节课、今天到期）在 refresh() 里用 timeSource 现算。
 * 之所以不把「现在」缓存成常量：跨零点或用户在前台停留很久时，
 * 缓存的时刻会让「下一个行程」一直指向已经上完的课。
 */
class TodayViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()
    private val courseNames = mutableMapOf<String, String>()

    private val _state = MutableStateFlow(TodayUiState())
    val state: StateFlow<TodayUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            container.taskRepository.observeExternalIssues().collect { issues ->
                _state.update { it.copy(syncIssues = issues) }
            }
        }
        viewModelScope.launch {
            container.syncRepository.observePendingCount().collect { pending ->
                _state.update { it.copy(outboxPending = pending) }
            }
        }
        viewModelScope.launch {
            container.captureRepository.observeRecent(30).collect { records ->
                val pending = records
                    .filter { it.status != CaptureStatus.EXTRACTED }
                    .map { record ->
                        TodayCaptureItem(
                            captureId = record.id,
                            kindName = record.kind.displayName,
                            status = record.status,
                            recordedAt = record.recordedAt,
                            preview = container.captureRepository.displayText(record) ?: "这条记录还没有文字内容",
                        )
                    }
                _state.update { it.copy(pendingCaptures = pending) }
            }
        }
        viewModelScope.launch {
            container.followUpRepository.observeOutstanding().collect { records ->
                val waiting = records
                    .filter { it.state == FollowUpState.DELIVERED || it.state == FollowUpState.SNOOZED }
                    .map { record ->
                        TodayFollowUpItem(
                            followUpId = record.id,
                            courseName = courseNameOf(record.courseId),
                            at = record.snoozeUntilUtc ?: record.deliveredAtUtc ?: record.scheduledAtUtc,
                            state = record.state,
                            attempt = record.attempt,
                        )
                    }
                _state.update { it.copy(pendingFollowUps = waiting) }
            }
        }
        refresh()
    }

    /** 重新计算「相对现在」的部分：下一个行程与今天到期的待办。 */
    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, notice = null) }
            val now = container.timeSource.now()
            val today = DayCueTime.localDateOf(now, zone)

            val outcome = runCatching {
                val todays = container.scheduleRepository.instancesOn(today, zone)
                // 正在上的课也算「下一个行程」：endsAt 还没到就说明人还坐在教室里。
                // 正在上的课也算「下一个行程」，所以判据是「还没结束」而不是「还没开始」。
                val upcoming = todays
                    .filter { it.status != CourseInstanceStatus.CANCELLED && it.endsAtUtc.isAfter(now) }
                    .minByOrNull { it.startsAtUtc }

                val later = if (upcoming == null) {
                    container.scheduleRepository
                        .instancesBetween(now, now.plus(7, ChronoUnit.DAYS))
                        .firstOrNull { it.status != CourseInstanceStatus.CANCELLED && it.startsAtUtc.isAfter(now) }
                } else {
                    null
                }

                val tasks = container.taskRepository.dueOnLocalDate(today, zone)
                    .filter { it.status == TaskStatus.OPEN }

                // 今天写下的笔记：按用户时区的闭开区间查，跨零点时不会把昨天的算进来。
                val notes = container.noteRepository.listOnLocalDate(today, zone)

                Triple(upcoming, later, tasks to notes)
            }

            outcome.onSuccess { (upcoming, later, tasksAndNotes) ->
                val (tasks, notes) = tasksAndNotes
                _state.update {
                    it.copy(
                        loading = false,
                        now = now,
                        nextCourse = upcoming?.let { instance ->
                            TodayCourseItem(
                                instanceId = instance.id,
                                courseName = courseNameOf(instance.courseId),
                                startsAt = instance.startsAtUtc,
                                endsAt = instance.endsAtUtc,
                                location = instance.location,
                                status = instance.status,
                            )
                        },
                        laterCourseHint = later?.let { instance ->
                            courseNameOf(instance.courseId) + " · " + DayCueTime.displayDateTime(instance.startsAtUtc, zone)
                        },
                        dueTodayTasks = tasks,
                        todayNotes = notes,
                    )
                }
            }.onFailure { error ->
                _state.update { it.copy(loading = false, notice = error.message ?: "读取今天的内容失败") }
            }
        }
    }

    /** 完成一条今天到期的待办：状态落库后再取消可能存在的本地闹钟，不能反过来。 */
    fun completeTask(taskId: String) {
        viewModelScope.launch {
            runCatching {
                container.taskRepository.complete(taskId)
                container.reminderScheduler.cancelLocalAlarm(taskId)
            }.onSuccess {
                refresh()
            }.onFailure { error ->
                _state.update { it.copy(notice = error.message ?: "标记完成失败") }
            }
        }
    }

    private suspend fun courseNameOf(courseId: String): String {
        courseNames[courseId]?.let { return it }
        val name = runCatching { container.scheduleRepository.findCourse(courseId)?.name }.getOrNull()
        val resolved = name?.takeIf { it.isNotBlank() } ?: "已删除的课程"
        courseNames[courseId] = resolved
        return resolved
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { TodayViewModel(container) }
        }
    }
}
