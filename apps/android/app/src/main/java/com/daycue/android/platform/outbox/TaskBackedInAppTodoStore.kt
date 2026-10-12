package com.daycue.android.platform.outbox

import com.daycue.android.data.local.dao.TaskDao
import com.daycue.android.data.repository.TaskRepository
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.TaskStatus

/**
 * 以 task 表为 App 内待办的实现。
 *
 * 「App 内待办」就是本机的 task 行。因此 create_reminder 不是新建一条待办，
 * 而是把这条任务登记为已投影到 App 内待办并写下回执时间；
 * delete_reminder 撤回这个投影（回到 not_requested），任务本身仍然保留。
 *
 * 为什么这么做：Android 端没有系统级待办可供写入。伪造一个「已写入外部提供方」
 * 才是真正的错误；如实把本地待办当作投影目标，界面与对账都能得到正确的结论。
 */
class TaskBackedInAppTodoStore(
    private val tasks: TaskRepository,
    private val taskDao: TaskDao,
    private val timeSource: TimeSource,
) : InAppTodoStore {

    override suspend fun ensureTodo(taskId: String, listId: String): InAppTodoOutcome {
        val task = tasks.find(taskId) ?: return InAppTodoOutcome.Missing
        if (task.status == TaskStatus.CANCELLED) return InAppTodoOutcome.Cancelled

        // 回执只能由「真的做完了」推进：这里已经确认本地待办存在，所以写到 written。
        tasks.applyExternalReceipt(taskId, written = true, externalId = todoId(taskId))
        return InAppTodoOutcome.Done(todoId(taskId))
    }

    override suspend fun removeTodo(taskId: String, externalId: String?) {
        val task = tasks.find(taskId) ?: return
        // 任务本身是主库，不能删；这里只撤回「对外投影」的状态。
        taskDao.updateExternalWriteState(
            id = task.id,
            state = ExternalWriteState.NOT_REQUESTED,
            receiptAt = null,
            updatedAt = timeSource.now(),
        )
    }

    private fun todoId(taskId: String): String = TODO_ID_PREFIX + taskId

    companion object {
        /**
         * App 内待办的稳定标识前缀：与真正的系统提供方区分开，便于对账时肉眼分辨。
         *
         * 直接引用仓储层常量而不是再抄一份字符串：删除排队的幂等键依赖"前缀 + task id"这个组合，
         * 两处一旦漂移，delete_reminder 就会变成一条永远删不到对象的队列记录。
         */
        const val TODO_ID_PREFIX = TaskRepository.APP_TODO_ID_PREFIX
    }
}
