package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.repository.TaskRepository
import com.daycue.android.domain.model.TaskStatus

/**
 * 用任务当前状态判断 outbox 操作是否已被取消。
 *
 * 为什么需要它：用户在后台排队期间取消或删除了任务，如果照旧执行，
 * 会把一条已经被放弃的任务写进待办分区，之后对账还会把它当成「外部多了东西」。
 * 只对 task 实体判断；其他实体（例如 capture）没有取消语义，一律不拦。
 */
class TaskStatusOutboxCancellationGate(
    private val tasks: TaskRepository,
) : OutboxCancellationGate {

    override suspend fun isCancelled(operation: OutboxOperationRecord): Boolean {
        if (operation.entityType != ENTITY_TASK) return false
        // 撤回类操作永远不该被拦：任务被删/被取消，恰恰是它要去把已经排队的投影撤掉的时候。
        // 在这里拦下的话 delete_reminder 会被标成 cancelled 而永不执行，到点提醒就撤不掉了。
        if (operation.op == OutboxOperationKinds.DELETE_REMINDER) return false
        // find 不返回已软删除的任务：任务没了，这条对外写入也就失去了对象。
        val task = tasks.find(operation.entityId) ?: return true
        return task.status == TaskStatus.CANCELLED
    }

    private companion object {
        const val ENTITY_TASK = "task"
    }
}
