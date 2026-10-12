package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.platform.OutboxExecution
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 执行者分发层。
 *
 * 用替身处理者验证「按 op 路由」以及三条兜底：没有处理者、次数用满、处理者抛异常。
 * 它不验证 App 内待办的真实写入——那需要设备。
 */
class AppOutboxExecutorTest {

    private class RecordingHandler(private val outcome: OutboxExecution) : OutboxOperationHandler {
        val calls = mutableListOf<OutboxOperationRecord>()

        override suspend fun execute(operation: OutboxOperationRecord): OutboxExecution {
            calls += operation
            return outcome
        }
    }

    private class ThrowingHandler : OutboxOperationHandler {
        override suspend fun execute(operation: OutboxOperationRecord): OutboxExecution =
            throw IllegalStateException("处理者炸了")
    }

    @Test
    fun dispatchesToHandlerRegisteredForOperation() = runTest {
        val handler = RecordingHandler(OutboxExecution.Succeeded)
        val executor = AppOutboxExecutor(mapOf(OutboxOperationKinds.CREATE_REMINDER to handler))

        val outcome = executor.execute(outboxOperation())

        assertEquals(1, handler.calls.size)
        assertEquals("task_1", handler.calls.single().entityId)
        assertEquals(OutboxExecution.Succeeded, outcome)
    }

    @Test
    fun missingHandlerIsNonRetryableFailure() = runTest {
        val executor = AppOutboxExecutor(emptyMap())

        val outcome = executor.execute(outboxOperation(op = OutboxOperationKinds.UPDATE_REMINDER))

        assertTrue(outcome is OutboxExecution.Failed)
        assertTrue((outcome as OutboxExecution.Failed).message.contains(OutboxOperationKinds.UPDATE_REMINDER))
    }

    @Test
    fun exhaustedAttemptsFailWithoutCallingHandler() = runTest {
        val handler = RecordingHandler(OutboxExecution.Succeeded)
        val executor = AppOutboxExecutor(mapOf(OutboxOperationKinds.CREATE_REMINDER to handler))

        val outcome = executor.execute(outboxOperation(attempt = 5, lastError = "上次超时"))

        assertTrue(handler.calls.isEmpty())
        assertTrue(outcome is OutboxExecution.Failed)
        assertTrue((outcome as OutboxExecution.Failed).message.contains("上限"))
    }

    @Test
    fun handlerExceptionBecomesUnknown() = runTest {
        val executor = AppOutboxExecutor(mapOf(OutboxOperationKinds.CREATE_REMINDER to ThrowingHandler()))

        val outcome = executor.execute(outboxOperation())

        assertTrue(outcome is OutboxExecution.Unknown)
        assertTrue((outcome as OutboxExecution.Unknown).message.contains("处理者炸了"))
    }

    @Test
    fun retryableOutcomePassesThroughUnchanged() = runTest {
        val retry = OutboxExecution.Retryable("网络不通")
        val handler = RecordingHandler(retry)
        val executor = AppOutboxExecutor(mapOf(OutboxOperationKinds.CREATE_REMINDER to handler))

        val outcome = executor.execute(outboxOperation())

        assertEquals(retry, outcome)
    }
}
