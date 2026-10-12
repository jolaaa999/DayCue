package com.daycue.android.domain.proactive

import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/**
 * 主动消息预算。
 *
 * 全部用上海时区的固定时刻，重点覆盖三件容易写错的事：
 * 静默时段是顺延不是丢弃、预算跨零点重置、任务提醒不受预算约束。
 */
class ProactiveBudgetTest {

    private val shanghai: ZoneId = ZoneId.of("Asia/Shanghai")

    private fun candidate(
        at: String,
        kind: ProactiveKind = ProactiveKind.REVIEW,
        dedupeKey: String = "review:2026-10-12",
        expiresAt: String? = null,
        cooldownKey: String? = null,
    ) = ProactiveCandidate(
        dedupeKey = dedupeKey,
        kind = kind,
        scheduledAt = Instant.parse(at),
        expiresAt = expiresAt?.let { Instant.parse(it) },
        cooldownKey = cooldownKey,
    )

    private fun delivered(
        at: String,
        kind: ProactiveKind = ProactiveKind.REVIEW,
        dedupeKey: String = "x",
        cooldownKey: String? = null,
    ) = LedgerEntry(
        dedupeKey = dedupeKey,
        kind = kind,
        state = ProactiveState.DELIVERED,
        scheduledAt = Instant.parse(at),
        deliveredAt = Instant.parse(at),
        cooldownKey = cooldownKey,
    )

    @Test
    fun duplicateDedupeKeyIsSuppressed() {
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T02:00:00Z"),
            ledger = listOf(
                LedgerEntry(
                    dedupeKey = "review:2026-10-12",
                    kind = ProactiveKind.REVIEW,
                    state = ProactiveState.PENDING,
                    scheduledAt = Instant.parse("2026-10-12T02:00:00Z"),
                ),
            ),
            now = Instant.parse("2026-10-12T01:59:00Z"),
            zone = shanghai,
        )
        assertEquals(BudgetDecision.Suppressed(SuppressReason.DUPLICATE), decision)
    }

    @Test
    fun expiredLedgerEntryDoesNotBlockANewCandidate() {
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T02:00:00Z"),
            ledger = listOf(
                LedgerEntry(
                    dedupeKey = "review:2026-10-12",
                    kind = ProactiveKind.REVIEW,
                    state = ProactiveState.EXPIRED,
                    scheduledAt = Instant.parse("2026-10-12T02:00:00Z"),
                    deliveredAt = Instant.parse("2026-10-12T02:00:00Z"),
                ),
            ),
            now = Instant.parse("2026-10-12T02:00:00Z"),
            zone = shanghai,
        )
        assertTrue(decision is BudgetDecision.Deliver)
    }

    @Test
    fun quietHoursDeferInsteadOfDropping() {
        // 上海 22:40 落在静默时段，应顺延到次日 08:00（UTC 2026-10-13T00:00:00Z），而不是丢掉。
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T14:40:00Z"),
            ledger = emptyList(),
            now = Instant.parse("2026-10-12T14:40:00Z"),
            zone = shanghai,
        )
        assertEquals(
            BudgetDecision.Deliver(Instant.parse("2026-10-13T00:00:00Z"), deferred = true),
            decision,
        )
    }

    @Test
    fun deferredPastItsExpiryIsExpiredNotDelivered() {
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T14:40:00Z", expiresAt = "2026-10-12T16:00:00Z"),
            ledger = emptyList(),
            now = Instant.parse("2026-10-12T14:40:00Z"),
            zone = shanghai,
        )
        assertTrue(decision is BudgetDecision.Expired)
    }

    @Test
    fun earlyMorningQuietDefersToSameDayMorning() {
        // 上海 00:30 属于静默时段的另一半，应顺延到当天 08:00。
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-11T16:30:00Z"),
            ledger = emptyList(),
            now = Instant.parse("2026-10-11T16:30:00Z"),
            zone = shanghai,
        )
        assertEquals(Instant.parse("2026-10-12T00:00:00Z"), (decision as BudgetDecision.Deliver).at)
    }

    @Test
    fun dailyLimitSuppressesFurtherMessages() {
        val day = "2026-10-12T"
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T06:00:00Z"),
            ledger = listOf(
                delivered(day + "01:00:00Z", dedupeKey = "a"),
                delivered(day + "02:30:00Z", dedupeKey = "b"),
                delivered(day + "04:00:00Z", dedupeKey = "c"),
            ),
            now = Instant.parse("2026-10-12T06:00:00Z"),
            zone = shanghai,
        )
        assertEquals(BudgetDecision.Suppressed(SuppressReason.DAILY_LIMIT), decision)
    }

    @Test
    fun budgetResetsAfterLocalMidnight() {
        // 三条都发在 10-12 的本地日；候选落在 10-13 上午，额度必须重新算。
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-13T01:00:00Z", dedupeKey = "review:2026-10-13"),
            ledger = listOf(
                delivered("2026-10-12T01:00:00Z", dedupeKey = "a"),
                delivered("2026-10-12T03:00:00Z", dedupeKey = "b"),
                delivered("2026-10-12T05:00:00Z", dedupeKey = "c"),
            ),
            now = Instant.parse("2026-10-13T01:00:00Z"),
            zone = shanghai,
        )
        assertTrue(decision is BudgetDecision.Deliver)
    }

    @Test
    fun followUpHasItsOwnDailyLimit() {
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T06:00:00Z", kind = ProactiveKind.FOLLOW_UP, dedupeKey = "follow_up:1"),
            ledger = listOf(delivered("2026-10-12T01:00:00Z", kind = ProactiveKind.FOLLOW_UP, dedupeKey = "follow_up:0")),
            now = Instant.parse("2026-10-12T06:00:00Z"),
            zone = shanghai,
        )
        assertEquals(BudgetDecision.Suppressed(SuppressReason.KIND_LIMIT), decision)
    }

    @Test
    fun minimumIntervalDefersTheNextMessage() {
        // 上一条 10:00（本地）发出，间隔 90 分钟，所以 10:30 的候选要顺延到 11:30。
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T02:30:00Z"),
            ledger = listOf(delivered("2026-10-12T02:00:00Z")),
            now = Instant.parse("2026-10-12T02:30:00Z"),
            zone = shanghai,
        )
        assertEquals(Instant.parse("2026-10-12T03:30:00Z"), (decision as BudgetDecision.Deliver).at)
        assertTrue(decision.deferred)
    }

    @Test
    fun cooldownSuppressesRepeatedLocationRule() {
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T02:30:00Z", kind = ProactiveKind.GEO, dedupeKey = "geo:2", cooldownKey = "rule_1"),
            ledger = listOf(delivered("2026-10-12T02:00:00Z", kind = ProactiveKind.GEO, dedupeKey = "geo:1", cooldownKey = "rule_1")),
            now = Instant.parse("2026-10-12T02:30:00Z"),
            zone = shanghai,
            cooldownMinutes = 60,
        )
        assertTrue(decision is BudgetDecision.Suppressed)
        assertEquals(SuppressReason.COOLDOWN, (decision as BudgetDecision.Suppressed).reason)
    }

    @Test
    fun userSetTaskReminderIgnoresBudgetAndQuietHours() {
        // 用户自己要的到点提醒不受静默时段与额度约束：替他静音属于越权。
        val decision = ProactiveBudget.evaluate(
            candidate = candidate("2026-10-12T14:40:00Z", kind = ProactiveKind.REMINDER, dedupeKey = "reminder:task_1"),
            ledger = listOf(
                delivered("2026-10-12T01:00:00Z", dedupeKey = "a"),
                delivered("2026-10-12T03:00:00Z", dedupeKey = "b"),
                delivered("2026-10-12T05:00:00Z", dedupeKey = "c"),
            ),
            now = Instant.parse("2026-10-12T14:40:00Z"),
            zone = shanghai,
        )
        assertEquals(BudgetDecision.Deliver(Instant.parse("2026-10-12T14:40:00Z"), false), decision)
    }

    @Test
    fun quietWindowBoundaries() {
        val policy = BudgetPolicy()
        assertTrue(ProactiveBudget.isQuiet(LocalTime.of(22, 30), policy))
        assertTrue(ProactiveBudget.isQuiet(LocalTime.of(23, 59), policy))
        assertTrue(ProactiveBudget.isQuiet(LocalTime.of(0, 0), policy))
        assertTrue(ProactiveBudget.isQuiet(LocalTime.of(7, 59), policy))
        assertFalse(ProactiveBudget.isQuiet(LocalTime.of(8, 0), policy))
        assertFalse(ProactiveBudget.isQuiet(LocalTime.of(12, 0), policy))
        assertFalse(ProactiveBudget.isQuiet(LocalTime.of(22, 29), policy))
    }
}
