package com.daycue.android.platform.outbox

import com.daycue.android.platform.OutboxExecution
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * App 内待办处理者。
 *
 * 用替身 InAppTodoStore 验证：create 会登记、delete 会撤回、任务缺失/已取消是**不可重试**失败、
 * payload 坏掉不会让操作卡住。真实 Room 写入不在本测试范围内。
 */
class InAppTodoReminderHandlerTest {

    private class FakeTodoStore(
        private val outcome: InAppTodoOutcome = InAppTodoOutcome.Done("app://todo/task_1"),
    ) : InAppTodoStore {
        val ensured = mutableListOf<Pair<String, String>>()
        val removed = mutableListOf<Pair<String, String?>>()

        override suspend fun ensureTodo(taskId: String, listId: String): InAppTodoOutcome {
            ensured += taskId to listId
            return outcome
        }

        override suspend fun removeTodo(taskId: String, externalId: String?) {
            removed += taskId to externalId
        }
    }

    @Test
    fun createReminderRegistersTodoAndSucceeds() = runTest {
        val store = FakeTodoStore()
        val handler = InAppTodoReminderHandler(store)

        val outcome = handler.execute(outboxOperation())

        assertEquals(OutboxExecution.Succeeded, outcome)
        assertEquals(1, store.ensured.size)
        assertEquals("task_1", store.ensured.single().first)
    }

    @Test
    fun createReminderUsesListIdFromPayload() = runTest {
        val store = FakeTodoStore()
        val handler = InAppTodoReminderHandler(store)

        handler.execute(outboxOperation(payloadJson = """{"task_id":"task_1","list_id":"list_9"}"""))

        assertEquals("list_9", store.ensured.single().second)
    }

    @Test
    fun createReminderFallsBackToDefaultListWhenPayloadMissing() = runTest {
        val store = FakeTodoStore()
        val handler = InAppTodoReminderHandler(store)

        handler.execute(outboxOperation(payloadJson = null))

        assertEquals("default", store.ensured.single().second)
    }

    @Test
    fun malformedPayloadIsTolerated() = runTest {
        val store = FakeTodoStore()
        val handler = InAppTodoReminderHandler(store)

        val outcome = handler.execute(outboxOperation(payloadJson = "这不是 JSON"))

        assertEquals(OutboxExecution.Succeeded, outcome)
        assertEquals("default", store.ensured.single().second)
    }

    @Test
    fun createReminderForMissingTaskIsNonRetryableFailure() = runTest {
        val store = FakeTodoStore(InAppTodoOutcome.Missing)
        val handler = InAppTodoReminderHandler(store)

        val outcome = handler.execute(outboxOperation())

        assertTrue(outcome is OutboxExecution.Failed)
        assertTrue((outcome as OutboxExecution.Failed).message.contains("已不存在"))
    }

    @Test
    fun createReminderForCancelledTaskIsNonRetryableFailure() = runTest {
        val store = FakeTodoStore(InAppTodoOutcome.Cancelled)
        val handler = InAppTodoReminderHandler(store)

        val outcome = handler.execute(outboxOperation())

        assertTrue(outcome is OutboxExecution.Failed)
        assertTrue((outcome as OutboxExecution.Failed).message.contains("已取消"))
    }

    @Test
    fun deleteReminderRemovesProjectionAndSucceeds() = runTest {
        val store = FakeTodoStore()
        val handler = InAppTodoReminderHandler(store)

        val outcome = handler.execute(
            outboxOperation(
                op = OutboxOperationKinds.DELETE_REMINDER,
                payloadJson = """{"task_id":"task_1","external_id":"app://todo/task_1"}""",
            ),
        )

        assertEquals(OutboxExecution.Succeeded, outcome)
        assertEquals("task_1", store.removed.single().first)
        assertEquals("app://todo/task_1", store.removed.single().second)
    }

    @Test
    fun unsupportedOperationIsNonRetryableFailure() = runTest {
        val store = FakeTodoStore()
        val handler = InAppTodoReminderHandler(store)

        val outcome = handler.execute(outboxOperation(op = OutboxOperationKinds.UPDATE_REMINDER))

        assertTrue(outcome is OutboxExecution.Failed)
        assertTrue(store.ensured.isEmpty())
        assertTrue(store.removed.isEmpty())
    }
}
