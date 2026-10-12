package com.daycue.android.ui.task

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.data.repository.NewTask
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.TaskStatus
import com.daycue.android.domain.reminder.LocalDelivery
import com.daycue.android.domain.reminder.ReminderAction
import com.daycue.android.domain.reminder.ReminderOwner
import com.daycue.android.domain.reminder.ReminderOwnership
import com.daycue.android.domain.reminder.TaskReminderSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/**
 * 新建任务的表单。
 *
 * 日期型与时间型分成不同的字段：date 型只有 dueDate，绝不允许顺带读一个时刻，
 * 否则「周五之前」会被悄悄变成「周五 00:00 提醒」。
 */
data class NewTaskDraft(
    val title: String = "",
    val detail: String = "",
    val dueKind: DueKind = DueKind.NONE,
    val dueDate: String = "",
    val dueTime: String = "",
    val courseHint: String = "",
    val remindEnabled: Boolean = false,
    val remindDate: String = "",
    val remindTime: String = "",
)

/**
 * 是否为这次新建请求外部写入。
 *
 * 只有带提醒的任务需要它：没有提醒的任务在 App 内待办里本来就已经存在，
 * 一次 create_reminder 的往返只会把状态标成"已写入"，却没有任何东西被真正交付。
 * 抽成顶层纯函数是为了让这条规则能在 JVM 单测里被直接验证，而不必把依赖 AppContainer 的 ViewModel 拖进测试。
 */
fun shouldRequestExternalWrite(remindAt: Instant?): Boolean = remindAt != null

data class TaskUiState(
    val filter: TaskStatus = TaskStatus.OPEN,
    val tasks: List<TaskRecord> = emptyList(),
    val loading: Boolean = true,
    val dialogOpen: Boolean = false,
    val draft: NewTaskDraft = NewTaskDraft(),
    val notice: String? = null,
    val error: String? = null,
)

/**
 * 待办列表与新建。
 *
 * 新建后如果能力允许，会按 ReminderOwnership 的语义安排本地闹钟：
 * 决策（该不该响、准点还是可能延迟）全部交给那个纯函数对象，界面只负责把结论显示给用户，
 * 这样「同一条任务只能有一个执行方」这条铁律不会在界面层被绕开。
 */
class TaskViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    private val _state = MutableStateFlow(TaskUiState())
    val state: StateFlow<TaskUiState> = _state.asStateFlow()

    private var openTasks: List<TaskRecord> = emptyList()

    init {
        viewModelScope.launch {
            container.taskRepository.observeOpen().collect { records ->
                openTasks = records
                if (_state.value.filter == TaskStatus.OPEN) {
                    _state.update { it.copy(tasks = records, loading = false) }
                }
            }
        }
    }

    fun setFilter(status: TaskStatus) {
        _state.update { it.copy(filter = status, loading = true, notice = null, error = null) }
        if (status == TaskStatus.OPEN) {
            _state.update { it.copy(tasks = openTasks, loading = false) }
        } else {
            viewModelScope.launch { loadClosed(status) }
        }
    }

    /**
     * 已完成 / 已取消的列表。
     *
     * 为什么直接读 DAO：TaskRepository 只向界面暴露了「待办」这一个列表（observeOpen），
     * 而这一页要求按状态过滤。在不改动已冻结的 data 层的前提下，这两类状态只能做只读查询；
     * 所有写入仍然走仓储，界面不直接改表。
     */
    private suspend fun loadClosed(status: TaskStatus) {
        runCatching { container.database.taskDao().listByStatus(status) }
            .onSuccess { records -> _state.update { it.copy(tasks = records, loading = false) } }
            .onFailure { error ->
                _state.update { it.copy(loading = false, error = error.message ?: "读取任务失败") }
            }
    }

    fun openDialog() {
        _state.update { it.copy(dialogOpen = true, draft = NewTaskDraft(), error = null, notice = null) }
    }

    fun closeDialog() {
        _state.update { it.copy(dialogOpen = false) }
    }

    fun updateDraft(transform: (NewTaskDraft) -> NewTaskDraft) {
        _state.update { it.copy(draft = transform(it.draft), error = null) }
    }

    fun clearMessages() {
        _state.update { it.copy(notice = null, error = null) }
    }

    fun createTask() {
        val draft = _state.value.draft
        val title = draft.title.trim()
        if (title.isEmpty()) {
            _state.update { it.copy(error = "任务标题不能为空。") }
            return
        }

        val dueLocalDate = when (draft.dueKind) {
            DueKind.DATE -> {
                val date = DayCueTime.parseLocalDateOrNull(draft.dueDate)
                if (date == null) {
                    _state.update { it.copy(error = "日期型截止日要写成 2026-10-16 这样的格式。") }
                    return
                }
                date
            }
            else -> null
        }

        val dueInstant = when (draft.dueKind) {
            DueKind.DATETIME -> {
                val date = DayCueTime.parseLocalDateOrNull(draft.dueDate)
                val time = parseTimeOrNull(draft.dueTime)
                if (date == null || time == null) {
                    _state.update { it.copy(error = "时间型截止需要填写日期（2026-10-16）与时刻（20:00）。") }
                    return
                }
                DayCueTime.atLocal(date, time, zone)
            }
            else -> null
        }

        // 提醒是可选项；没勾选就真的没有提醒，而不是替用户挑一个时刻。
        val remindAt = if (draft.remindEnabled) {
            val date = DayCueTime.parseLocalDateOrNull(draft.remindDate)
            val time = parseTimeOrNull(draft.remindTime)
            if (date == null || time == null) {
                _state.update { it.copy(error = "提醒时刻需要填写日期（2026-10-16）与时刻（19:30）。") }
                return
            }
            DayCueTime.atLocal(date, time, zone)
        } else {
            null
        }

        viewModelScope.launch {
            val created = runCatching {
                container.taskRepository.create(
                    NewTask(
                        title = title,
                        detail = draft.detail.trim().takeIf { it.isNotEmpty() },
                        dueKind = draft.dueKind,
                        dueLocalDate = dueLocalDate,
                        dueInstant = dueInstant,
                        remindAt = remindAt,
                        zone = zone,
                        courseHint = draft.courseHint.trim().takeIf { it.isNotEmpty() },
                        // 带提醒的任务在保存时真的入队 create_reminder；不带提醒的不入队，理由见上面那条纯函数。
                        requestExternalWrite = shouldRequestExternalWrite(remindAt),
                    ),
                )
            }
            created.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "创建任务失败") }
            }.onSuccess { taskId ->
                val notices = if (remindAt == null) {
                    emptyList()
                } else {
                    scheduleReminder(taskId, title, remindAt, draft.detail.trim())
                }
                _state.update {
                    it.copy(
                        dialogOpen = false,
                        draft = NewTaskDraft(),
                        notice = (listOf("任务已保存到本机。") + notices).joinToString(" "),
                    )
                }
                reload()
            }
        }
    }

    /**
     * 只安排本地闹钟，并返回必须展示给用户的降级说明。
     *
     * 外部提供方（如 iPhone 提醒事项）在 Android 端没有对应实现，所以这里只执行本地动作；
     * 计划里其余动作有意忽略，而不是假装执行成功。
     */
    private suspend fun scheduleReminder(taskId: String, title: String, remindAt: Instant, detail: String): List<String> {
        val capability = runCatching { container.capabilities().reminderCapability }.getOrNull()
            ?: return listOf("无法读取提醒能力状态，这条任务没有安排提醒。")

        val snapshot = TaskReminderSnapshot(
            taskId = taskId,
            remindAt = remindAt,
            currentOwner = ReminderOwner.APP_LOCAL,
            localAlarmScheduled = false,
        )
        val plan = ReminderOwnership.plan(ReminderOwner.APP_LOCAL, snapshot, capability)

        plan.actions.forEach { action ->
            when (action) {
                is ReminderAction.ScheduleLocalAlarm -> container.reminderScheduler.scheduleLocalAlarm(
                    taskId = action.taskId,
                    at = action.at,
                    exact = action.exact,
                    title = title,
                    body = detail.takeIf { it.isNotBlank() } ?: "来自 DayCue 的待办提醒",
                )

                is ReminderAction.CancelLocalAlarm -> container.reminderScheduler.cancelLocalAlarm(action.taskId)
                else -> Unit
            }
        }

        val notices = ArrayList(plan.notices)
        if (capability.localDelivery == LocalDelivery.NONE) {
            // 通知权限没开时留下「等待授权」，用户以后开权限就能看出这条还没落地。
            runCatching { container.taskRepository.markWaitingForPermission(taskId) }
        }
        return notices
    }

    fun complete(taskId: String) = mutate(taskId) { container.taskRepository.complete(taskId) }

    fun reopen(taskId: String) = mutate(taskId) { container.taskRepository.reopen(taskId) }

    fun cancel(taskId: String) = mutate(taskId) { container.taskRepository.cancel(taskId) }

    fun delete(taskId: String) = mutate(taskId) { container.taskRepository.softDelete(taskId) }

    /** 清掉提醒：仓储抹掉提醒时刻并排队 delete_reminder 撤回 App 内待办投影，这里再撤掉本地闹钟。 */
    fun clearReminder(taskId: String) = mutate(taskId) { container.taskRepository.clearReminder(taskId) }

    /**
     * 改状态后总是取消本地闹钟。
     *
     * 已完成或已删除的任务如果还留着闹钟，用户会在几天后被一条已经不存在的待办叫醒；
     * 重新打开时若还想要提醒，需要显式再设一次，这比「静默保留」更不容易搞错。
     *
     * 取消必须发生在写库成功之后：反过来的话，写库失败时闹钟已经没了，用户以为提醒还在却不会响。
     */
    private fun mutate(taskId: String, action: suspend () -> Unit) {
        viewModelScope.launch {
            runCatching {
                action()
                container.reminderScheduler.cancelLocalAlarm(taskId)
            }.onSuccess {
                reload()
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "更新任务失败") }
            }
        }
    }

    private fun reload() {
        viewModelScope.launch {
            if (_state.value.filter == TaskStatus.OPEN) {
                _state.update { it.copy(tasks = openTasks, loading = false) }
            } else {
                loadClosed(_state.value.filter)
            }
        }
    }

    private fun parseTimeOrNull(text: String): LocalTime? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return runCatching { LocalTime.parse(trimmed.replace('：', ':')) }.getOrNull()
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { TaskViewModel(container) }
        }
    }
}
