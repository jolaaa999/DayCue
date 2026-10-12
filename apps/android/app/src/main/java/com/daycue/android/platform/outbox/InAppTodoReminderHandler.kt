package com.daycue.android.platform.outbox

import com.daycue.android.core.DayCueJson
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.platform.OutboxExecution
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/** App 内待办的落地结果。Missing / Cancelled 都是「确定不该写」，调用方据此给出不可重试失败。 */
sealed interface InAppTodoOutcome {
    data class Done(val todoId: String) : InAppTodoOutcome

    data object Missing : InAppTodoOutcome

    data object Cancelled : InAppTodoOutcome
}

/**
 * App 内待办存储。
 *
 * Android 的主库 task 表就是待办本体，没有苹果提醒事项桥接；
 * 所以这里的「对外投影」指的是 App 自己的待办分区。
 * 抽成接口是为了让处理者不依赖 Room 与 Repository，可以在纯 JVM 单测里用替身验证编排。
 */
interface InAppTodoStore {
    suspend fun ensureTodo(taskId: String, listId: String): InAppTodoOutcome

    suspend fun removeTodo(taskId: String, externalId: String?)
}

/**
 * create_reminder / delete_reminder 的落地实现。
 *
 * 它做的事很窄：只维护「这条任务在 App 内待办里存在」这件事与回执。
 * 到点提醒由 ReminderScheduler 独占（见 ReminderOwnership：同一条任务只能有一个执行方），
 * 这里绝不再排一次闹钟，否则用户会听到两次。
 */
class InAppTodoReminderHandler(
    private val todos: InAppTodoStore,
) : OutboxOperationHandler {

    override suspend fun execute(operation: OutboxOperationRecord): OutboxExecution =
        when (operation.op) {
            OutboxOperationKinds.CREATE_REMINDER -> create(operation)
            OutboxOperationKinds.DELETE_REMINDER -> delete(operation)
            else -> OutboxExecution.Failed("InAppTodoReminderHandler 不支持的操作：" + operation.op)
        }

    private suspend fun create(operation: OutboxOperationRecord): OutboxExecution {
        val listId = listIdOf(operation) ?: DEFAULT_LIST
        return when (val outcome = todos.ensureTodo(operation.entityId, listId)) {
            is InAppTodoOutcome.Done -> OutboxExecution.Succeeded

            // 任务已经不在库里：重试一万次也不会出现，必须终止而不是排队。
            is InAppTodoOutcome.Missing ->
                OutboxExecution.Failed("任务 " + operation.entityId + " 已不存在，无法登记为 App 内待办。")

            is InAppTodoOutcome.Cancelled ->
                OutboxExecution.Failed("任务 " + operation.entityId + " 已取消，不再登记 App 内待办。")
        }
    }

    private suspend fun delete(operation: OutboxOperationRecord): OutboxExecution {
        todos.removeTodo(operation.entityId, externalIdOf(operation))
        // 删除是幂等的：目标已经不存在也算目标达成，不能因为「没东西可删」而失败重试。
        return OutboxExecution.Succeeded
    }

    /** payload 里解析不出的字段一律不当致命错误：create_reminder 只把 list_id 当提示。 */
    private fun listIdOf(operation: OutboxOperationRecord): String? = payloadOf(operation)["list_id"]

    private fun externalIdOf(operation: OutboxOperationRecord): String? = payloadOf(operation)["external_id"]

    private fun payloadOf(operation: OutboxOperationRecord): Map<String, String> {
        val payload = operation.payloadJson ?: return emptyMap()
        return runCatching {
            DayCueJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), payload)
        }.getOrDefault(emptyMap<String, String>())
    }

    private companion object {
        /** 与 TaskRepository.DEFAULT_LIST 保持一致；这里刻意不引用它，避免平台层反向依赖仓储常量。 */
        const val DEFAULT_LIST = "default"
    }
}
