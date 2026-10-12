package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.domain.model.OutboxState
import com.daycue.android.platform.OutboxExecution
import com.daycue.android.platform.OutboxOperationExecutor
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import java.time.Instant

/**
 * outbox 状态机编排。
 *
 * 这是用假执行者/假存储做的**替身验证**：证明「谁在什么时候被调用、状态最后落在哪」，
 * 不是设备验收。真机上的 Room 写入、WorkManager 唤醒仍需仪器测试与人工验证。
 */
class OutboxProcessorTest {

    private val base: Instant = Instant.parse("2026-10-12T02:00:00Z")
    private val timeSource: TimeSource = TimeSource { base }

    private class RecordingExecutor(
        private val outcome: (OutboxOperationRecord) -> OutboxExecution = { OutboxExecution.Succeeded },
    ) : OutboxOperationExecutor {
        val calls = mutableListOf<OutboxOperationRecord>()

        override suspend fun execute(operation: OutboxOperationRecord): OutboxExecution {
            calls += operation
            return outcome(operation)
        }
    }

    private class ThrowingExecutor : OutboxOperationExecutor {
        override suspend fun execute(operation: OutboxOperationRecord): OutboxExecution =
            throw IllegalStateException("替身炸了")
    }

    private class NeverWinsStore(records: List<OutboxOperationRecord>) : FakeOutboxStore(records) {
        override suspend fun claim(id: String, now: Instant): Boolean = false
    }

    private class AlwaysCancelled : OutboxCancellationGate {
        override suspend fun isCancelled(operation: OutboxOperationRecord): Boolean = true
    }

    private fun processor(
        store: OutboxOperationStore,
        executor: OutboxOperationExecutor,
        policy: OutboxRetryPolicy = OutboxRetryPolicy.DEFAULT,
        cancellation: OutboxCancellationGate = OutboxCancellationGate.NeverCancelled,
    ) = OutboxProcessor(
        store = store,
        executor = executor,
        timeSource = timeSource,
        policy = policy,
        cancellation = cancellation,
        staleRunningAfter = Duration.ofMinutes(15),
    )

    @Test
    fun executorIsCalledAndRecordEndsSucceeded() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor()

        val summary = processor(store, executor).runOnce()

        assertEquals(1, executor.calls.size)
        assertEquals(OutboxState.SUCCEEDED, store.stateOf("op_1"))
        assertEquals(1, summary.succeeded)
        assertEquals(base, store.recordOf("op_1")?.updatedAt)
    }

    @Test
    fun executorSeesClaimedRecordWithIncrementedAttempt() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor()

        processor(store, executor).runOnce()

        val seen = executor.calls.single()
        assertEquals(1, seen.attempt)
        assertEquals(OutboxState.RUNNING, seen.state)
        assertEquals("task_1", seen.entityId)
    }

    @Test
    fun unknownOperationGoesToDeadLetterWithoutBeingExecuted() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation(op = "mystery_op")))
        val executor = RecordingExecutor()

        val summary = processor(store, executor).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(OutboxTerminalStates.deadLetter, store.stateOf("op_1"))
        assertEquals(1, summary.deadLettered)
        assertEquals(1, summary.processed)
    }

    @Test
    fun deadLetteredOperationIsNotPickedUpAgain() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation(op = "mystery_op")))
        val executor = RecordingExecutor()

        processor(store, executor).runOnce()
        val second = processor(store, executor).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(0, second.processed)
        assertEquals(OutboxTerminalStates.deadLetter, store.stateOf("op_1"))
    }

    @Test
    fun declaredButUnavailableOperationIsTerminatedWithReason() = runTest {
        val store = FakeOutboxStore(
            listOf(
                outboxOperation(
                    op = OutboxOperationKinds.EXTRACT_CAPTURE,
                    entityType = "capture",
                    entityId = "capture_1",
                    payloadJson = null,
                ),
            ),
        )
        val executor = RecordingExecutor()

        processor(store, executor).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(OutboxTerminalStates.deadLetter, store.stateOf("op_1"))
        val reason = store.lastErrorOf("op_1") ?: ""
        assertTrue(reason.contains("未启用"))
    }

    @Test
    fun unknownOutcomeGoesToReconciliationAndIsNotRetried() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor { OutboxExecution.Unknown("连接中断，无法确认是否写入") }

        val summary = processor(store, executor).runOnce()

        assertEquals(OutboxState.UNKNOWN, store.stateOf("op_1"))
        assertNull(store.nextRetryAtOf("op_1"))
        assertEquals(1, summary.unknown)
        assertEquals(0, store.markFailedCalls)

        val retryExecutor = RecordingExecutor()
        val second = processor(store, retryExecutor).runOnce()
        assertTrue(retryExecutor.calls.isEmpty())
        assertEquals(0, second.processed)
    }

    @Test
    fun retryableFailureIsRescheduledWithBackoff() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor { OutboxExecution.Retryable("网络不可用") }

        val summary = processor(store, executor).runOnce()

        assertEquals(OutboxState.PENDING, store.stateOf("op_1"))
        assertEquals(base.plusSeconds(60), store.nextRetryAtOf("op_1"))
        assertTrue((store.lastErrorOf("op_1") ?: "").contains("网络不可用"))
        assertEquals(1, summary.retried)
        assertTrue(summary.retryNeeded)
    }

    @Test
    fun retryBackoffGrowsWithAttemptCount() = runTest {
        // 抢占后 attempt = 2，退避应为 60 * 2 = 120 秒。
        val store = FakeOutboxStore(listOf(outboxOperation(attempt = 1)))
        val executor = RecordingExecutor { OutboxExecution.Retryable("网络不可用") }

        processor(store, executor).runOnce()

        assertEquals(base.plusSeconds(120), store.nextRetryAtOf("op_1"))
    }

    @Test
    fun retryableOutcomeHonoursExplicitRetryAt() = runTest {
        val explicit = base.plusSeconds(900)
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor { OutboxExecution.Retryable("被限流", explicit) }

        processor(store, executor).runOnce()

        assertEquals(explicit, store.nextRetryAtOf("op_1"))
    }

    @Test
    fun retryStopsAtMaxAttemptsAndBecomesTerminal() = runTest {
        // maxAttempts=5：抢占后 attempt=5，已经用满，不能再排回 pending。
        val store = FakeOutboxStore(listOf(outboxOperation(attempt = 4)))
        val executor = RecordingExecutor { OutboxExecution.Retryable("还是不通") }

        val summary = processor(store, executor).runOnce()

        assertEquals(OutboxState.FAILED, store.stateOf("op_1"))
        assertNull(store.nextRetryAtOf("op_1"))
        assertTrue((store.lastErrorOf("op_1") ?: "").contains("上限"))
        assertEquals(1, summary.failed)
        assertEquals(0, summary.retried)
    }

    @Test
    fun nonRetryableFailureIsTerminalAndNotExecutedAgain() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor { OutboxExecution.Failed("参数非法") }

        val summary = processor(store, executor).runOnce()

        assertEquals(OutboxState.FAILED, store.stateOf("op_1"))
        assertEquals(1, summary.failed)

        val retryExecutor = RecordingExecutor()
        val second = processor(store, retryExecutor).runOnce()
        assertTrue(retryExecutor.calls.isEmpty())
        assertEquals(0, second.processed)
    }

    @Test
    fun cancelledOperationIsNotExecutedAndIsTerminal() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))
        val executor = RecordingExecutor()

        val summary = processor(store, executor, cancellation = AlwaysCancelled()).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(OutboxTerminalStates.cancelled, store.stateOf("op_1"))
        assertEquals(1, summary.cancelled)

        val retryExecutor = RecordingExecutor()
        val second = processor(store, retryExecutor, cancellation = AlwaysCancelled()).runOnce()
        assertTrue(retryExecutor.calls.isEmpty())
        assertEquals(0, second.processed)
    }

    @Test
    fun executorThrowBecomesUnknownNotFailed() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation()))

        processor(store, ThrowingExecutor()).runOnce()

        assertEquals(OutboxState.UNKNOWN, store.stateOf("op_1"))
        assertTrue((store.lastErrorOf("op_1") ?: "").contains("替身炸了"))
        assertEquals(0, store.markFailedCalls)
    }

    @Test
    fun lostClaimIsSkippedWithoutExecuting() = runTest {
        val store = NeverWinsStore(listOf(outboxOperation()))
        val executor = RecordingExecutor()

        val summary = processor(store, executor).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(1, summary.claimed)
        assertEquals(1, summary.skipped)
        assertEquals(OutboxState.PENDING, store.stateOf("op_1"))
    }

    @Test
    fun staleRunningIsRecoveredAsUnknown() = runTest {
        val stale = outboxOperation(
            state = OutboxState.RUNNING,
            attempt = 1,
            updatedAt = base.minusSeconds(16 * 60),
        )
        val store = FakeOutboxStore(listOf(stale))

        val summary = processor(store, RecordingExecutor()).runOnce()

        assertEquals(OutboxState.UNKNOWN, store.stateOf("op_1"))
        assertEquals(1, summary.unknown)
        assertNull(store.nextRetryAtOf("op_1"))
    }

    @Test
    fun freshRunningIsLeftUntouched() = runTest {
        val fresh = outboxOperation(
            state = OutboxState.RUNNING,
            attempt = 1,
            updatedAt = base.minusSeconds(60),
        )
        val store = FakeOutboxStore(listOf(fresh))

        val summary = processor(store, RecordingExecutor()).runOnce()

        assertEquals(OutboxState.RUNNING, store.stateOf("op_1"))
        assertEquals(0, summary.unknown)
    }

    @Test
    fun succeededOperationIsNotExecutedAgain() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation(state = OutboxState.SUCCEEDED, attempt = 1)))
        val executor = RecordingExecutor()

        val summary = processor(store, executor).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(0, summary.processed)
    }

    @Test
    fun pendingWithFutureRetryAtIsNotPicked() = runTest {
        val store = FakeOutboxStore(listOf(outboxOperation(nextRetryAt = base.plusSeconds(30))))
        val executor = RecordingExecutor()

        val summary = processor(store, executor).runOnce()

        assertTrue(executor.calls.isEmpty())
        assertEquals(0, summary.processed)
    }

    @Test
    fun runOnceRespectsLimit() = runTest {
        val store = FakeOutboxStore((1..5).map { outboxOperation(id = "op_" + it) })
        val executor = RecordingExecutor()

        processor(store, executor).runOnce(limit = 2)

        assertEquals(2, executor.calls.size)
        assertEquals(OutboxState.SUCCEEDED, store.stateOf("op_1"))
        assertEquals(OutboxState.PENDING, store.stateOf("op_3"))
    }
}
