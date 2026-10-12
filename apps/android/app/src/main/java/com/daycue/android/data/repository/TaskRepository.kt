package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.dao.OutboxDao
import com.daycue.android.data.local.dao.TaskDao
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.TaskStatus
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 新建任务时界面能给的全部信息。dueInstant 与 dueLocalDate 互斥，由 dueKind 决定。 */
data class NewTask(
    val title: String,
    val detail: String? = null,
    val dueKind: DueKind = DueKind.NONE,
    val dueLocalDate: LocalDate? = null,
    val dueInstant: Instant? = null,
    val remindAt: Instant? = null,
    val zone: ZoneId,
    val courseHint: String? = null,
    val originCaptureId: String? = null,
    val originItemId: String? = null,
    /** 是否立刻排队写入外部提供方（例如 iPhone 上的提醒事项桥接）。默认否：不擅自替用户做系统写。 */
    val requestExternalWrite: Boolean = false,
    val externalListId: String? = null,
)

/**
 * 任务（task）的仓储。
 *
 * Android 端不假定任何系统级待办 API，这里就是主库；外部写入只是个可选的投影。
 * 两条不变式：
 * 1. due_kind=date 时 due_utc 必须为 null（否则「周五之前」会变成「周五 00:00 提醒」）；
 * 2. 外部写入状态只能由「外部回执」推进，界面上的「写入成功」必须以回执为依据。
 */
class TaskRepository(
    private val dao: TaskDao,
    private val outboxDao: OutboxDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    suspend fun create(task: NewTask): String {
        val now = timeSource.now()
        require(task.title.isNotBlank()) { "任务标题不能为空" }
        val dueLocal = when (task.dueKind) {
            DueKind.NONE -> null
            DueKind.DATE -> requireNotNull(task.dueLocalDate?.let { DayCueTime.localDateString(it) }) {
                "日期型截止日必须给出日期"
            }.also {
                require(task.dueInstant == null) { "日期型截止日不允许有绝对时刻，禁止伪造 UTC 午夜" }
            }

            DueKind.DATETIME -> requireNotNull(task.dueInstant) { "时间型截止必须给出绝对时刻" }
                .let { DayCueTime.localDateTimeString(it, task.zone) }
        }

        val record = TaskRecord(
            id = DayCueId.new(),
            title = task.title.trim(),
            detail = task.detail,
            status = TaskStatus.OPEN,
            dueKind = task.dueKind,
            dueLocal = dueLocal,
            dueUtc = if (task.dueKind == DueKind.DATETIME) task.dueInstant else null,
            timezone = task.zone.id,
            remindLocal = task.remindAt?.let { DayCueTime.localDateTimeString(it, task.zone) },
            remindUtc = task.remindAt,
            courseHint = task.courseHint,
            originCaptureId = task.originCaptureId,
            originItemId = task.originItemId,
            externalWriteState = if (task.requestExternalWrite) {
                ExternalWriteState.PENDING
            } else {
                ExternalWriteState.NOT_REQUESTED
            },
            createdAt = now,
            updatedAt = now,
        )
        dao.insert(record)

        if (task.requestExternalWrite) {
            enqueueExternalWrite(record, task.externalListId, now)
        }
        return record.id
    }

    /** 写任务与写 outbox 在同一次调用里完成：先落本地再对外动作，中途崩溃也不会丢「要写外部」这件事。 */
    private suspend fun enqueueExternalWrite(task: TaskRecord, listId: String?, now: Instant) {
        outboxDao.enqueue(
            OutboxOperations.createReminder(
                taskId = task.id,
                listId = listId ?: DEFAULT_LIST,
                now = now,
            ),
        )
    }

    /**
     * 完成一条任务：落状态之后撤回 App 内待办投影。
     *
     * 为什么完成也要撤回：提醒的意义是"提醒你去做这件还没做完的事"，
     * 任务已经完成还留着外部对象，就是一条永远不该再响的提醒。
     */
    suspend fun complete(taskId: String) {
        setStatus(taskId, TaskStatus.DONE)
        withdrawReminderIfProjected(taskId)
    }

    /** 重新打开只改状态，不自动补投影：要提醒需要显式再设一次，避免静默复活一条旧的外部对象。 */
    suspend fun reopen(taskId: String) = setStatus(taskId, TaskStatus.OPEN)

    suspend fun cancel(taskId: String) {
        setStatus(taskId, TaskStatus.CANCELLED)
        withdrawReminderIfProjected(taskId)
    }

    suspend fun setStatus(taskId: String, status: TaskStatus) {
        dao.updateStatus(taskId, status, timeSource.now())
    }

    /**
     * 用户清掉提醒：抹掉提醒时刻，并撤回 App 内待办投影。
     *
     * 先改库再排队：提醒时刻落库成功才代表"用户要取消"这件事成立；
     * 排队失败时至少时刻已经没了，不会出现"界面显示无提醒、闹钟照响"。
     */
    suspend fun clearReminder(taskId: String) {
        val now = timeSource.now()
        val task = dao.findById(taskId) ?: return
        val wasProjected = needsWithdrawal(task)
        dao.update(task.copy(remindLocal = null, remindUtc = null, updatedAt = now))
        if (wasProjected) enqueueReminderDeletion(taskId, now)
    }

    /**
     * "这条任务是否真的被投影出去过"。
     *
     * 没有提醒、也从未请求过外部写入的任务根本不存在外部对象，
     * 对它排队 delete_reminder 就是一次无意义的往返——这与 create 端"只有带提醒才入队"是同一条规则。
     */
    private fun needsWithdrawal(task: TaskRecord?): Boolean =
        task != null && (task.remindUtc != null || task.externalWriteState != ExternalWriteState.NOT_REQUESTED)

    private suspend fun withdrawReminderIfProjected(taskId: String) {
        if (!needsWithdrawal(dao.findById(taskId))) return
        enqueueReminderDeletion(taskId, timeSource.now())
    }

    /**
     * 排队撤回 App 内待办投影。
     *
     * external_id 用与 TaskBackedInAppTodoStore 相同的确定性前缀：Android 唯一的外部目标就是
     * App 内待办，它的 id 由 taskId 决定，不需要（也没有）一张单独的外部 id 表。
     */
    private suspend fun enqueueReminderDeletion(taskId: String, now: Instant) {
        outboxDao.enqueue(
            OutboxOperations.deleteReminder(
                taskId = taskId,
                externalId = APP_TODO_ID_PREFIX + taskId,
                now = now,
            ),
        )
    }

    suspend fun softDelete(taskId: String) {
        val now = timeSource.now()
        // 先读后删：软删除之后 findById 就查不到了，而"要不要撤回投影"必须依据删除前的状态判断。
        val wasProjected = needsWithdrawal(dao.findById(taskId))
        dao.softDelete(taskId, now)
        if (wasProjected) enqueueReminderDeletion(taskId, now)
        // 删除也要传播：没有 tombstone，别的设备会把这条任务「复活」。
        tombstoneRecorder?.invoke(taskId, now)
    }

    fun observeOpen(): Flow<List<TaskRecord>> = dao.observeOpen()

    fun observeOpenCount(): Flow<Int> = dao.observeOpenCount()

    fun observeExternalIssues(): Flow<List<TaskRecord>> = dao.observeExternalIssues()

    suspend fun find(taskId: String): TaskRecord? = dao.findById(taskId)

    suspend fun listOpen(): List<TaskRecord> = dao.listByStatus(TaskStatus.OPEN)

    suspend fun dueOnLocalDate(date: LocalDate, zone: ZoneId): List<TaskRecord> =
        dao.listDueBetween(DayCueTime.startOfLocalDay(date, zone), DayCueTime.startOfNextLocalDay(date, zone))

    suspend fun listUpcomingReminders(from: Instant): List<TaskRecord> = dao.listUpcomingReminders(from)

    suspend fun listByOriginCapture(captureId: String): List<TaskRecord> = dao.listByOriginCapture(captureId)

    /**
     * 外部回执：只有拿到明确的成功回执才能把状态推到 written。
     * 拿不到回执时一律 unknown / needs_reconciliation，绝不能显示「已写入」。
     */
    suspend fun applyExternalReceipt(taskId: String, written: Boolean, externalId: String?) {
        val now = timeSource.now()
        val state = if (written) ExternalWriteState.WRITTEN else ExternalWriteState.UNKNOWN
        dao.updateExternalWriteState(taskId, state, now, now)
        if (externalId != null) {
            syncSnapshotWriter?.invoke(taskId, externalId, now)
        }
    }

    suspend fun markNeedsReconciliation(taskId: String) {
        val now = timeSource.now()
        dao.updateExternalWriteState(taskId, ExternalWriteState.NEEDS_RECONCILIATION, null, now)
    }

    suspend fun markWaitingForPermission(taskId: String) {
        val now = timeSource.now()
        dao.updateExternalWriteState(taskId, ExternalWriteState.WAITING_FOR_PERMISSION, null, now)
    }

    /** 由 Application 装配时注入，避免仓储之间互相持有实例。 */
    var tombstoneRecorder: (suspend (String, Instant) -> Unit)? = null
    var syncSnapshotWriter: (suspend (String, String, Instant) -> Unit)? = null

    companion object {
        /** 未选择清单时的默认键。契约里 create_reminder 的幂等键需要它。 */
        const val DEFAULT_LIST = "default"

        /** App 内待办投影的对外标识前缀。TaskBackedInAppTodoStore 直接引用它，两处不能各抄一份。 */
        const val APP_TODO_ID_PREFIX = "app://todo/"
    }
}
