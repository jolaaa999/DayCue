package com.daycue.android.data.repository

import com.daycue.android.core.DayCueJson
import com.daycue.android.core.IdempotencyKey
import com.daycue.android.data.local.dao.OutboxDao
import com.daycue.android.data.local.dao.TaskDao
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.OutboxState
import com.daycue.android.domain.model.TaskStatus
import com.daycue.android.platform.outbox.AppOutboxExecutor
import com.daycue.android.platform.outbox.FakeOutboxStore
import com.daycue.android.platform.outbox.InAppTodoOutcome
import com.daycue.android.platform.outbox.InAppTodoReminderHandler
import com.daycue.android.platform.outbox.InAppTodoStore
import com.daycue.android.platform.outbox.OutboxOperationKinds
import com.daycue.android.platform.outbox.OutboxProcessor
import com.daycue.android.platform.outbox.TaskStatusOutboxCancellationGate
import com.daycue.android.ui.task.shouldRequestExternalWrite
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

private val FIXED_NOW: Instant = Instant.parse("2026-10-12T04:00:00Z")
private val REMIND_AT: Instant = Instant.parse("2026-10-12T12:00:00Z")
private val ZONE: ZoneId = ZoneId.of("Asia/Shanghai")

private fun newTask(
    title: String = "交实验报告",
    remindAt: Instant? = null,
    requestExternalWrite: Boolean = false,
): NewTask = NewTask(
    title = title,
    remindAt = remindAt,
    zone = ZONE,
    requestExternalWrite = requestExternalWrite,
)

private fun payloadOf(record: OutboxOperationRecord): Map<String, String> {
    val raw = record.payloadJson ?: return emptyMap()
    return DayCueJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), raw)
}

/**
 * 生产入队点的编排测试。
 *
 * 这是**替身验证编排**，不是设备验收：用内存版 DAO/Store 断言"入队了什么载荷、走到哪个执行者"，
 * 真实 Room 写入与 WorkManager 唤醒不在本测试范围内（本机没有 Android SDK/Gradle，无法编译与运行）。
 */
class TaskRepositoryOutboxEnqueueTest {

    private class Fixture {
        val tasks = FakeTaskDao()
        val outbox = RecordingOutboxDao()
        val repository = TaskRepository(tasks, outbox, TimeSource { FIXED_NOW })
    }

    /** 只统计与删除/撤回有关的操作，避免把 create 也算进去。 */
    private fun Fixture.deleteOperations(): List<OutboxOperationRecord> =
        outbox.enqueued.filter { it.op == OutboxOperationKinds.DELETE_REMINDER }

    @Test
    fun saveWithReminderEnqueuesCreateReminderWithDeterministicKey() = runTest {
        val fx = Fixture()

        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        assertEquals(1, fx.outbox.enqueued.size)
        val op = fx.outbox.enqueued.single()
        assertEquals(OutboxOperationKinds.CREATE_REMINDER, op.op)
        assertEquals("task", op.entityType)
        assertEquals(taskId, op.entityId)
        // 幂等键必须由 taskId + list_id 决定性地算出来，否则重试会变成新建。
        assertEquals(IdempotencyKey.createReminder(taskId, TaskRepository.DEFAULT_LIST), op.idempotencyKey)
        assertEquals(taskId, payloadOf(op)["task_id"])
        assertEquals(TaskRepository.DEFAULT_LIST, payloadOf(op)["list_id"])
        // 入队后先标 pending；真正的 written 只能由回执推进。
        assertEquals(ExternalWriteState.PENDING, fx.tasks.recordOf(taskId)?.externalWriteState)
    }

    @Test
    fun saveWithoutReminderDoesNotEnqueueAnything() = runTest {
        val fx = Fixture()

        val taskId = fx.repository.create(newTask(remindAt = null))

        assertTrue(fx.outbox.enqueued.isEmpty())
        assertEquals(ExternalWriteState.NOT_REQUESTED, fx.tasks.recordOf(taskId)?.externalWriteState)
    }

    @Test
    fun completeEnqueuesDeleteReminder() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        fx.repository.complete(taskId)

        val op = fx.deleteOperations().single()
        assertEquals(taskId, op.entityId)
        assertEquals(TaskRepository.APP_TODO_ID_PREFIX + taskId, payloadOf(op)["external_id"])
        assertEquals(
            IdempotencyKey.deleteReminder(taskId, TaskRepository.APP_TODO_ID_PREFIX + taskId),
            op.idempotencyKey,
        )
    }

    @Test
    fun cancelEnqueuesDeleteReminder() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        fx.repository.cancel(taskId)

        assertEquals(taskId, fx.deleteOperations().single().entityId)
    }

    @Test
    fun softDeleteEnqueuesDeleteReminder() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        fx.repository.softDelete(taskId)

        assertEquals(taskId, fx.deleteOperations().single().entityId)
    }

    @Test
    fun clearReminderClearsReminderFieldsAndEnqueuesDelete() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        fx.repository.clearReminder(taskId)

        val record = fx.tasks.recordOf(taskId)!!
        assertNull(record.remindUtc)
        assertNull(record.remindLocal)
        assertEquals(taskId, fx.deleteOperations().single().entityId)
    }

    @Test
    fun taskWithoutReminderDoesNotEnqueueDelete() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = null))

        fx.repository.complete(taskId)

        // 从未投影过的任务没有外部对象可撤，多一条 delete 就是无意义往返。
        assertTrue(fx.deleteOperations().isEmpty())
    }

    @Test
    fun repeatedWithdrawalCollapsesToOneOperation() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        fx.repository.complete(taskId)
        fx.repository.complete(taskId)

        // 同一个 (taskId, external_id) 的幂等键相同，唯一索引会把第二条挡掉。
        assertEquals(1, fx.deleteOperations().size)
    }

    @Test
    fun externalWriteIsRequestedOnlyWhenReminderPresent() {
        assertTrue(shouldRequestExternalWrite(REMIND_AT))
        assertFalse(shouldRequestExternalWrite(null))
    }

    @Test
    fun enqueuedCreateReminderRunsThroughProcessorAndSucceeds() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))

        val todoStore = RecordingTodoStore()
        val summary = runProcessor(fx, todoStore)

        assertEquals(1, summary.succeeded)
        assertEquals(listOf(taskId to TaskRepository.DEFAULT_LIST), todoStore.ensured)
    }

    @Test
    fun createThenCompleteRunsBothOperationsThroughProcessor() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))
        fx.repository.complete(taskId)

        val todoStore = RecordingTodoStore()
        val summary = runProcessor(fx, todoStore)

        // create 先于 delete（按 created_at 排序），两条都真的走到了执行者并结束。
        assertEquals(2, summary.succeeded)
        assertEquals(listOf(taskId), todoStore.removed.map { it.first })
    }

    @Test
    fun deleteReminderSurvivesCancellationGateForCancelledTask() = runTest {
        val fx = Fixture()
        val taskId = fx.repository.create(newTask(remindAt = REMIND_AT, requestExternalWrite = true))
        fx.repository.cancel(taskId)
        val gate = TaskStatusOutboxCancellationGate(fx.repository)

        val deleteOp = fx.deleteOperations().single()
        val createOp = fx.outbox.enqueued.single { it.op == OutboxOperationKinds.CREATE_REMINDER }

        // 撤回操作不能被取消闸门拦下，否则 delete_reminder 永远不会执行；create 仍应被拦。
        assertFalse(gate.isCancelled(deleteOp))
        assertTrue(gate.isCancelled(createOp))
    }

    /** 复用既有 FakeOutboxStore 风格：把真实入队的记录喂给状态机，再走到真实处理者 + 替身待办存储。 */
    private suspend fun runProcessor(fx: Fixture, todoStore: RecordingTodoStore) = OutboxProcessor(
        store = FakeOutboxStore().also { store -> fx.outbox.enqueued.forEach { store.put(it) } },
        executor = AppOutboxExecutor(
            handlers = mapOf(
                OutboxOperationKinds.CREATE_REMINDER to InAppTodoReminderHandler(todoStore),
                OutboxOperationKinds.DELETE_REMINDER to InAppTodoReminderHandler(todoStore),
            ),
        ),
        timeSource = TimeSource { FIXED_NOW },
    ).runOnce()
}

/** 替身待办存储：只记录被要求登记/撤回的任务，返回稳定的 App 内待办 id。 */
private class RecordingTodoStore : InAppTodoStore {
    val ensured = mutableListOf<Pair<String, String>>()
    val removed = mutableListOf<Pair<String, String?>>()

    override suspend fun ensureTodo(taskId: String, listId: String): InAppTodoOutcome {
        ensured += taskId to listId
        return InAppTodoOutcome.Done(TaskRepository.APP_TODO_ID_PREFIX + taskId)
    }

    override suspend fun removeTodo(taskId: String, externalId: String?) {
        removed += taskId to externalId
    }
}

/**
 * 内存版 TaskDao。
 *
 * 只实现本测试真正会走到的读写；生产代码一旦意外调用别的查询，测试会立刻以异常指出，
 * 而不是静默返回空值让人以为通过。
 */
private class FakeTaskDao : TaskDao {
    private val byId = LinkedHashMap<String, TaskRecord>()

    override suspend fun insert(record: TaskRecord) {
        byId[record.id] = record
    }

    override suspend fun update(record: TaskRecord) {
        byId[record.id] = record
    }

    override suspend fun findById(id: String): TaskRecord? = byId[id]?.takeIf { it.deletedAt == null }

    override suspend fun findByIdIncludingDeleted(id: String): TaskRecord? = byId[id]

    override fun observeOpen(): Flow<List<TaskRecord>> = flowOf(emptyList())

    override suspend fun listByStatus(status: TaskStatus): List<TaskRecord> =
        byId.values.filter { it.status == status && it.deletedAt == null }

    override suspend fun listDueBetween(from: Instant, to: Instant): List<TaskRecord> =
        byId.values.filter { it.deletedAt == null && it.dueUtc != null && it.dueUtc!! >= from && it.dueUtc!! < to }

    override suspend fun listUpcomingReminders(from: Instant): List<TaskRecord> =
        byId.values.filter {
            it.deletedAt == null && it.status == TaskStatus.OPEN && it.remindUtc != null && it.remindUtc!! >= from
        }

    override suspend fun listByExternalWriteState(state: ExternalWriteState): List<TaskRecord> =
        byId.values.filter { it.externalWriteState == state && it.deletedAt == null }

    override fun observeExternalIssues(): Flow<List<TaskRecord>> = flowOf(emptyList())

    override suspend fun listPendingExternalWrites(): List<TaskRecord> =
        byId.values.filter { it.externalWriteState == ExternalWriteState.PENDING && it.deletedAt == null }

    override suspend fun listByOriginCapture(captureId: String): List<TaskRecord> =
        byId.values.filter { it.originCaptureId == captureId && it.deletedAt == null }

    override suspend fun updateStatus(id: String, status: TaskStatus, updatedAt: Instant) {
        byId[id]?.let { byId[id] = it.copy(status = status, updatedAt = updatedAt) }
    }

    override suspend fun updateExternalWriteState(
        id: String,
        state: ExternalWriteState,
        receiptAt: Instant?,
        updatedAt: Instant,
    ) {
        byId[id]?.let { byId[id] = it.copy(externalWriteState = state, lastReceiptAt = receiptAt, updatedAt = updatedAt) }
    }

    override suspend fun softDelete(id: String, deletedAt: Instant) {
        byId[id]?.let { byId[id] = it.copy(deletedAt = deletedAt, updatedAt = deletedAt) }
    }

    override fun observeOpenCount(): Flow<Int> = flowOf(0)

    fun recordOf(id: String): TaskRecord? = byId[id]
}

/**
 * 内存版 OutboxDao。
 *
 * 关键是模拟 idempotency_key 唯一索引：重复插入返回 -1 且不入库。
 * 用它验证的是"入队了什么"，不是 SQLite 行为。
 */
private class RecordingOutboxDao : OutboxDao {
    val enqueued = mutableListOf<OutboxOperationRecord>()

    override suspend fun enqueue(record: OutboxOperationRecord): Long {
        if (enqueued.any { it.idempotencyKey == record.idempotencyKey }) return -1L
        enqueued += record
        return enqueued.size.toLong()
    }

    override suspend fun update(record: OutboxOperationRecord) {
        val index = enqueued.indexOfFirst { it.id == record.id }
        if (index >= 0) enqueued[index] = record
    }

    override suspend fun findById(id: String): OutboxOperationRecord? = enqueued.firstOrNull { it.id == id }

    override suspend fun findByIdempotencyKey(key: String): OutboxOperationRecord? =
        enqueued.firstOrNull { it.idempotencyKey == key }

    override suspend fun listByEntity(entityType: String, entityId: String): List<OutboxOperationRecord> =
        enqueued.filter { it.entityType == entityType && it.entityId == entityId }.sortedByDescending { it.createdAt }

    override suspend fun listExecutable(now: Instant, limit: Int): List<OutboxOperationRecord> =
        enqueued
            .filter { it.state == OutboxState.PENDING && (it.nextRetryAt == null || !it.nextRetryAt!!.isAfter(now)) }
            .sortedBy { it.createdAt }
            .take(limit)

    override suspend fun listByState(state: OutboxState): List<OutboxOperationRecord> =
        enqueued.filter { it.state == state }

    override fun observePendingCount(): Flow<Int> = flowOf(enqueued.count { it.state == OutboxState.PENDING })

    override suspend fun markFailed(
        id: String,
        state: OutboxState,
        lastError: String?,
        nextRetryAt: Instant?,
        updatedAt: Instant,
    ) {
        val index = enqueued.indexOfFirst { it.id == id }
        if (index >= 0) {
            enqueued[index] = enqueued[index].copy(
                state = state,
                lastError = lastError,
                nextRetryAt = nextRetryAt,
                updatedAt = updatedAt,
            )
        }
    }

    override suspend fun markRunning(id: String, updatedAt: Instant): Int {
        val index = enqueued.indexOfFirst { it.id == id && it.state == OutboxState.PENDING }
        if (index < 0) return 0
        val current = enqueued[index]
        enqueued[index] = current.copy(state = OutboxState.RUNNING, attempt = current.attempt + 1, updatedAt = updatedAt)
        return 1
    }

    override suspend fun markSucceeded(id: String, updatedAt: Instant) {
        val index = enqueued.indexOfFirst { it.id == id }
        if (index >= 0) {
            enqueued[index] = enqueued[index].copy(
                state = OutboxState.SUCCEEDED,
                lastError = null,
                nextRetryAt = null,
                updatedAt = updatedAt,
            )
        }
    }
}
