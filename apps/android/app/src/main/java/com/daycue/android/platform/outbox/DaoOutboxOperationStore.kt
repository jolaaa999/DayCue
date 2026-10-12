package com.daycue.android.platform.outbox

import com.daycue.android.data.local.dao.OutboxDao
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.domain.model.OutboxState
import java.time.Instant

/**
 * OutboxOperationStore 的生产实现。
 *
 * 这里只做「端口方法 → DAO 调用」的映射，不含任何决策：
 * 决策留在 OutboxProcessor，才能被 JVM 单测覆盖。
 */
class DaoOutboxOperationStore(
    private val outboxDao: OutboxDao,
) : OutboxOperationStore {

    override suspend fun executable(now: Instant, limit: Int): List<OutboxOperationRecord> =
        outboxDao.listExecutable(now, limit)

    override suspend fun claim(id: String, now: Instant): Boolean = outboxDao.markRunning(id, now) == 1

    override suspend fun find(id: String): OutboxOperationRecord? = outboxDao.findById(id)

    override suspend fun markSucceeded(id: String, now: Instant) = outboxDao.markSucceeded(id, now)

    override suspend fun markFailed(id: String, reason: String?, now: Instant) =
        outboxDao.markFailed(id, OutboxState.FAILED, reason, null, now)

    override suspend fun markUnknown(id: String, reason: String?, now: Instant) =
        outboxDao.markFailed(id, OutboxState.UNKNOWN, reason, null, now)

    override suspend fun markDeadLetter(id: String, reason: String, now: Instant) =
        outboxDao.markFailed(id, OutboxTerminalStates.deadLetter, reason, null, now)

    override suspend fun markCancelled(id: String, reason: String, now: Instant) =
        outboxDao.markFailed(id, OutboxTerminalStates.cancelled, reason, null, now)

    override suspend fun reschedule(record: OutboxOperationRecord, reason: String?, retryAt: Instant, now: Instant) =
        outboxDao.update(
            record.copy(
                state = OutboxState.PENDING,
                lastError = reason,
                nextRetryAt = retryAt,
                updatedAt = now,
            ),
        )

    override suspend fun listRunning(): List<OutboxOperationRecord> = outboxDao.listByState(OutboxState.RUNNING)
}
