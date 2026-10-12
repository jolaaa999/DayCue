package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.data.local.dao.MemoryDao
import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * 记忆仓储。
 *
 * 一条不可让步的规则：**推断只能记为候选，不能直接成为事实**。
 * 因此 write(...) 里 sourceKind == INFERRED 时强制 status = CANDIDATE，
 * 调用方即使传了 CONFIRMED 也会被改回来——这条规则放在类型能拦住的地方，
 * 而不是指望每个调用点都记得。
 */
class MemoryRepository(
    private val dao: MemoryDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    fun observeAll(): Flow<List<MemoryItemRecord>> = dao.observeAll()

    suspend fun find(id: String): MemoryItemRecord? = dao.findById(id)

    suspend fun write(
        kind: String,
        statement: String,
        sourceKind: MemorySourceKind,
        sourceCaptureId: String? = null,
        requestedStatus: MemoryStatus = MemoryStatus.CANDIDATE,
        reviewInDays: Long? = 30,
        occurredAt: Instant = timeSource.now(),
    ): String {
        require(statement.isNotBlank()) { "记忆内容不能为空" }
        val status = if (sourceKind == MemorySourceKind.INFERRED) {
            MemoryStatus.CANDIDATE
        } else {
            requestedStatus
        }
        val id = DayCueId.new()
        dao.insert(
            MemoryItemRecord(
                id = id,
                kind = kind,
                statement = statement.trim(),
                status = status,
                sourceKind = sourceKind,
                sourceCaptureId = sourceCaptureId,
                reviewAt = reviewInDays?.let { occurredAt.plus(it, ChronoUnit.DAYS) },
                createdAt = occurredAt,
            ),
        )
        return id
    }

    suspend fun confirm(id: String) = dao.updateStatus(id, MemoryStatus.CONFIRMED)

    suspend fun retire(id: String) = dao.updateStatus(id, MemoryStatus.RETIRED)

    suspend fun markConflict(id: String) = dao.updateStatus(id, MemoryStatus.CONFLICT)

    suspend fun softDelete(id: String) = dao.softDelete(id, timeSource.now())

    suspend fun dueForReview(now: Instant = timeSource.now()): List<MemoryItemRecord> = dao.listDueForReview(now)

    suspend fun listByStatus(status: MemoryStatus): List<MemoryItemRecord> = dao.listByStatus(status)

    suspend fun search(keyword: String): List<MemoryItemRecord> {
        val trimmed = keyword.trim()
        if (trimmed.isEmpty()) return emptyList()
        return dao.search("%" + trimmed + "%")
    }

    /** 到了复核时间且还没被用户处理过的候选：界面应把它们顶到最上面。 */
    suspend fun candidatesNeedingAttention(now: Instant = timeSource.now()): List<MemoryItemRecord> =
        dao.listByStatus(MemoryStatus.CANDIDATE).filter { it.reviewAt == null || !it.reviewAt.isAfter(now) }
}
