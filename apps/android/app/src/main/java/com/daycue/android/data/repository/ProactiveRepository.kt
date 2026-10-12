package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.data.local.dao.ProactiveMessageDao
import com.daycue.android.data.local.entity.ProactiveMessageRecord
import com.daycue.android.domain.location.GeoLedgerRow
import com.daycue.android.domain.location.ProactiveLedger
import com.daycue.android.domain.location.ProactiveReceiptRow
import com.daycue.android.domain.location.ProactiveReceiptStore
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.proactive.BudgetDecision
import com.daycue.android.domain.proactive.BudgetPolicy
import com.daycue.android.domain.proactive.LedgerEntry
import com.daycue.android.domain.proactive.ProactiveBudget
import com.daycue.android.domain.proactive.ProactiveCandidate
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * 主动消息账本（proactive_message）的仓储。
 *
 * 判预算所需的全部依据都从库里读，不缓存进内存：
 * App 被系统杀掉、用户手动清理后台之后，「今天已经打扰过几次」这个事实必须还在。
 *
 * 它是 ProactiveLedger / ProactiveReceiptStore 两个端口的生产实现：
 * 地点提醒链路的编排层只通过端口访问账本，因此判定逻辑可以脱离 Room 被测试。
 */
class ProactiveRepository(
    private val dao: ProactiveMessageDao,
    private val timeSource: TimeSource = SystemTimeSource,
) : ProactiveLedger, ProactiveReceiptStore {

    /** 冷却键复用 target_ref，不额外开列，双端就不会多一处漂移。 */
    private fun ProactiveMessageRecord.toLedgerEntry(): LedgerEntry = LedgerEntry(
        dedupeKey = dedupeKey,
        kind = kind,
        state = state,
        scheduledAt = scheduledAtUtc,
        deliveredAt = deliveredAtUtc,
        cooldownKey = targetRef,
    )

    private fun ProactiveMessageRecord.toLedgerRow(): GeoLedgerRow = GeoLedgerRow(
        id = id,
        dedupeKey = dedupeKey,
        kind = kind,
        state = state,
        cooldownKey = targetRef,
        deliveredAt = deliveredAtUtc,
    )

    /**
     * 判定一条候选能不能发、什么时候发。
     *
     * 账本只读最近 2 天：最小间隔是 90 分钟、日额度按本地日重置，
     * 读更久没有意义，反而在长期使用时把整张表拉进内存。
     */
    override suspend fun evaluate(
        candidate: ProactiveCandidate,
        now: Instant,
        zone: ZoneId,
        policy: BudgetPolicy,
        cooldownMinutes: Long,
    ): BudgetDecision {
        val since = now.minus(2, ChronoUnit.DAYS)
        val ledger = dao.listDeliveredSince(since).map { it.toLedgerEntry() } +
            listOfNotNull(dao.findByDedupeKey(candidate.dedupeKey)?.toLedgerEntry())
        return ProactiveBudget.evaluate(candidate, ledger, now, zone, policy, cooldownMinutes)
    }

    /**
     * 把判定结果落账。
     *
     * pending 行先写进去再等投递：这样即使进程在投递前被杀，
     * dedupe_key 的唯一索引也能保证重启后不会重复打扰。
     */
    override suspend fun record(candidate: ProactiveCandidate, decision: BudgetDecision, now: Instant): String? {
        val id = DayCueId.new()
        val record = when (decision) {
            is BudgetDecision.Deliver -> ProactiveMessageRecord(
                id = id,
                kind = candidate.kind,
                dedupeKey = candidate.dedupeKey,
                targetRef = candidate.cooldownKey,
                state = ProactiveState.PENDING,
                scheduledAtUtc = decision.at,
                expiresAtUtc = candidate.expiresAt,
                createdAt = now,
                updatedAt = now,
            )

            is BudgetDecision.Suppressed -> ProactiveMessageRecord(
                id = id,
                kind = candidate.kind,
                dedupeKey = candidate.dedupeKey,
                targetRef = candidate.cooldownKey,
                state = ProactiveState.SUPPRESSED,
                suppressReason = decision.reason.displayName,
                scheduledAtUtc = decision.until ?: candidate.scheduledAt,
                expiresAtUtc = candidate.expiresAt,
                createdAt = now,
                updatedAt = now,
            )

            is BudgetDecision.Expired -> ProactiveMessageRecord(
                id = id,
                kind = candidate.kind,
                dedupeKey = candidate.dedupeKey,
                targetRef = candidate.cooldownKey,
                state = ProactiveState.EXPIRED,
                suppressReason = decision.reason,
                scheduledAtUtc = candidate.scheduledAt,
                expiresAtUtc = candidate.expiresAt,
                createdAt = now,
                updatedAt = now,
            )
        }
        val rowId = dao.insertIgnoringDuplicate(record)
        // -1 表示 dedupe_key 已存在：这不是错误，正是去重生效。
        return if (rowId == -1L) null else id
    }

    suspend fun markDelivered(dedupeKey: String, at: Instant = timeSource.now()) {
        dao.findByDedupeKey(dedupeKey)?.let { dao.markDelivered(it.id, at) }
    }

    suspend fun markDeliveredById(id: String, at: Instant = timeSource.now()) {
        dao.markDelivered(id, at)
    }

    suspend fun markSuppressed(id: String, reason: String) =
        dao.updateState(id, ProactiveState.SUPPRESSED, reason, timeSource.now())

    override suspend fun markCancelled(id: String) =
        dao.updateState(id, ProactiveState.CANCELLED, null, timeSource.now())

    /** 过期的 pending 一律归档，不补发（设计文档 8.2）。 */
    suspend fun expireOverdue(now: Instant = timeSource.now()): Int {
        val expired = dao.listExpiredPending(now)
        expired.forEach { dao.updateState(it.id, ProactiveState.EXPIRED, "已过有效期，丢弃而不是补发", now) }
        return expired.size
    }

    suspend fun dueForDelivery(now: Instant = timeSource.now()): List<ProactiveMessageRecord> = dao.listDuePending(now)

    suspend fun findByDedupeKey(dedupeKey: String): ProactiveMessageRecord? = dao.findByDedupeKey(dedupeKey)

    suspend fun deliveredSince(since: Instant): List<ProactiveMessageRecord> = dao.listDeliveredSince(since)

    fun observeRecent(limit: Int = 100): Flow<List<ProactiveMessageRecord>> = dao.observeRecent(limit)

    /** 界面用：今天到目前为止已经发出几条自主消息。 */
    suspend fun deliveredToday(dayStart: Instant): Int =
        dao.listDeliveredSince(dayStart).count { it.kind.countsTowardBudget }

    suspend fun pendingCount(): Int = dao.listDuePending(Instant.MAX).size

    // ---- ProactiveLedger ----

    override suspend fun ledgerSince(since: Instant): List<GeoLedgerRow> = deliveredSince(since).map { it.toLedgerRow() }

    override suspend fun pendingForRule(ruleId: String): List<GeoLedgerRow> =
        dao.listPendingForTarget(ruleId).map { it.toLedgerRow() }

    // ---- ProactiveReceiptStore ----

    override suspend fun findReceiptRow(dedupeKey: String): ProactiveReceiptRow? =
        dao.findByDedupeKey(dedupeKey)?.let {
            ProactiveReceiptRow(
                id = it.id,
                dedupeKey = it.dedupeKey,
                kind = it.kind,
                state = it.state,
                deliveredAt = it.deliveredAtUtc,
            )
        }

    /**
     * 回执落库。
     *
     * 两段写入的顺序有讲究：先改状态、再补发出时间。
     * markDelivered 会把状态一并置成 delivered，所以它只用于「真的发出了」这一步；
     * 忽略 / 取消走 updateState，绝不能顺手写一个假的发出时间——那会污染预算统计。
     */
    override suspend fun applyInteraction(
        id: String,
        state: ProactiveState,
        reason: String?,
        deliveredAt: Instant?,
        at: Instant,
    ) {
        dao.updateState(id, state, reason, at)
        if (deliveredAt != null) dao.markDelivered(id, deliveredAt)
    }

    fun candidate(
        kind: ProactiveKind,
        dedupeKey: String,
        scheduledAt: Instant,
        expiresAt: Instant? = null,
        cooldownKey: String? = null,
    ): ProactiveCandidate = ProactiveCandidate(
        dedupeKey = dedupeKey,
        kind = kind,
        scheduledAt = scheduledAt,
        expiresAt = expiresAt,
        cooldownKey = cooldownKey,
    )
}
