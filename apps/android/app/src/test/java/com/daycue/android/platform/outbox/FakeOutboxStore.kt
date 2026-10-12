package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.domain.model.OutboxState
import java.time.Instant

/** 测试用的记录构造器：默认就是一条待执行的 create_reminder。 */
fun outboxOperation(
    id: String = "op_1",
    op: String = OutboxOperationKinds.CREATE_REMINDER,
    entityType: String = "task",
    entityId: String = "task_1",
    payloadJson: String? = """{"task_id":"task_1","list_id":"default"}""",
    attempt: Int = 0,
    state: OutboxState = OutboxState.PENDING,
    nextRetryAt: Instant? = null,
    lastError: String? = null,
    createdAt: Instant = Instant.parse("2026-10-12T02:00:00Z"),
    updatedAt: Instant = createdAt,
): OutboxOperationRecord = OutboxOperationRecord(
    id = id,
    entityType = entityType,
    entityId = entityId,
    op = op,
    idempotencyKey = "key_" + id,
    payloadJson = payloadJson,
    attempt = attempt,
    state = state,
    nextRetryAt = nextRetryAt,
    lastError = lastError,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

/**
 * 纯内存替身。
 *
 * 它模拟的是 DAO 的**可观察行为**（抢占只有一个赢家、可执行只认 pending 且已到点），
 * 不是 SQLite 本身。用它验证的是状态机编排，不是设备验收。
 */
open class FakeOutboxStore(
    records: List<OutboxOperationRecord> = emptyList(),
) : OutboxOperationStore {

    private val byId = LinkedHashMap<String, OutboxOperationRecord>()

    /** 只统计 markFailed：用来断言「结果未知没有被当成确定失败」。 */
    var markFailedCalls = 0
        private set

    init {
        records.forEach { byId[it.id] = it }
    }

    fun put(record: OutboxOperationRecord) {
        byId[record.id] = record
    }

    fun stateOf(id: String): OutboxState? = byId[id]?.state

    fun recordOf(id: String): OutboxOperationRecord? = byId[id]

    fun nextRetryAtOf(id: String): Instant? = byId[id]?.nextRetryAt

    fun lastErrorOf(id: String): String? = byId[id]?.lastError

    override suspend fun executable(now: Instant, limit: Int): List<OutboxOperationRecord> =
        byId.values
            .filter { record ->
                if (record.state != OutboxState.PENDING) return@filter false
                val retryAt: Instant? = record.nextRetryAt
                retryAt == null || !retryAt.isAfter(now)
            }
            .sortedBy { it.createdAt }
            .take(limit)

    override suspend fun claim(id: String, now: Instant): Boolean {
        val record = byId[id] ?: return false
        if (record.state != OutboxState.PENDING) return false
        byId[id] = record.copy(state = OutboxState.RUNNING, attempt = record.attempt + 1, updatedAt = now)
        return true
    }

    override suspend fun find(id: String): OutboxOperationRecord? = byId[id]

    override suspend fun markSucceeded(id: String, now: Instant) {
        byId[id]?.let { current ->
            byId[id] = current.copy(
                state = OutboxState.SUCCEEDED,
                lastError = null,
                nextRetryAt = null,
                updatedAt = now,
            )
        }
    }

    override suspend fun markFailed(id: String, reason: String?, now: Instant) {
        markFailedCalls++
        byId[id]?.let { current ->
            byId[id] = current.copy(
                state = OutboxState.FAILED,
                lastError = reason,
                nextRetryAt = null,
                updatedAt = now,
            )
        }
    }

    override suspend fun markUnknown(id: String, reason: String?, now: Instant) {
        byId[id]?.let { current ->
            byId[id] = current.copy(
                state = OutboxState.UNKNOWN,
                lastError = reason,
                nextRetryAt = null,
                updatedAt = now,
            )
        }
    }

    override suspend fun markDeadLetter(id: String, reason: String, now: Instant) {
        byId[id]?.let { current ->
            byId[id] = current.copy(
                state = OutboxTerminalStates.deadLetter,
                lastError = reason,
                nextRetryAt = null,
                updatedAt = now,
            )
        }
    }

    override suspend fun markCancelled(id: String, reason: String, now: Instant) {
        byId[id]?.let { current ->
            byId[id] = current.copy(
                state = OutboxTerminalStates.cancelled,
                lastError = reason,
                nextRetryAt = null,
                updatedAt = now,
            )
        }
    }

    override suspend fun reschedule(record: OutboxOperationRecord, reason: String?, retryAt: Instant, now: Instant) {
        byId[record.id]?.let { current ->
            byId[record.id] = current.copy(
                state = OutboxState.PENDING,
                lastError = reason,
                nextRetryAt = retryAt,
                updatedAt = now,
            )
        }
    }

    override suspend fun listRunning(): List<OutboxOperationRecord> =
        byId.values.filter { it.state == OutboxState.RUNNING }
}
