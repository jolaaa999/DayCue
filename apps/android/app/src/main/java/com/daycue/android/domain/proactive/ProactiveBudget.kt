package com.daycue.android.domain.proactive

import com.daycue.android.core.DayCueTime
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/**
 * 打扰预算。
 *
 * 默认值全部来自设计文档 8.2：自主追问与建议合计每天最多 3 次、两次间隔至少 90 分钟、
 * 课后追问每天最多 1 次、静默 22:30–08:00。
 */
data class BudgetPolicy(
    val dailyLimit: Int = 3,
    val kindDailyLimit: Map<ProactiveKind, Int> = mapOf(ProactiveKind.FOLLOW_UP to 1),
    val minIntervalMinutes: Long = 90,
    val quietStart: LocalTime = LocalTime.of(22, 30),
    val quietEnd: LocalTime = LocalTime.of(8, 0),
)

/** 账本里的一行。对应 proactive_message 表，判断依据全部落库，不靠内存状态。 */
data class LedgerEntry(
    val dedupeKey: String,
    val kind: ProactiveKind,
    val state: ProactiveState,
    val scheduledAt: Instant,
    val deliveredAt: Instant? = null,
    val cooldownKey: String? = null,
)

data class ProactiveCandidate(
    val dedupeKey: String,
    val kind: ProactiveKind,
    val scheduledAt: Instant,
    val expiresAt: Instant? = null,
    /** 冷却维度的键，例如同一条 geo_rule 的 id。为 null 表示这条候选不参与冷却。 */
    val cooldownKey: String? = null,
)

enum class SuppressReason(val displayName: String) {
    DUPLICATE("同一条消息已经安排过了"),
    DAILY_LIMIT("今天的自主消息额度已用完"),
    KIND_LIMIT("这类消息今天的额度已用完"),
    COOLDOWN("仍在冷却期内"),
}

sealed interface BudgetDecision {
    /** at 可能被推迟到静默时段之后；deferred 用来告诉界面「不是准点，是被顺延了」。 */
    data class Deliver(val at: Instant, val deferred: Boolean) : BudgetDecision

    data class Suppressed(val reason: SuppressReason, val until: Instant? = null) : BudgetDecision

    data class Expired(val reason: String) : BudgetDecision
}

/**
 * 主动消息预算判定。
 *
 * 三处刻意的设计：
 * - 静默时段是**顺延**不是丢弃：夜里 22:30 生成的回顾会在次日 08:00 发出，
 *   但超过 expiresAt 就丢弃（用户不需要昨天的天气提醒）；
 * - 预算按**投递时刻所在的那个本地日**统计，所以跨零点会自然重置；
 * - 用户明确设定时刻的任务提醒（REMINDER）不计入预算，也不受静默时段约束——
 *   那是用户自己要的闹钟，替他静音属于越权。
 */
object ProactiveBudget {

    fun evaluate(
        candidate: ProactiveCandidate,
        ledger: List<LedgerEntry>,
        now: Instant,
        zone: ZoneId,
        policy: BudgetPolicy = BudgetPolicy(),
        cooldownMinutes: Long = 0,
    ): BudgetDecision {

        // 1. 去重：同一个 dedupe_key 已经有待发/已发/被抑制的记录，就不再产生第二条。
        if (ledger.any { it.dedupeKey == candidate.dedupeKey && it.state.blocksNewCandidate }) {
            return BudgetDecision.Suppressed(SuppressReason.DUPLICATE)
        }

        // 2. 用户在设置里明确要求到点提醒的任务：预算与静默都不适用。
        if (!candidate.kind.countsTowardBudget) {
            return BudgetDecision.Deliver(candidate.scheduledAt, deferred = false)
        }

        // 3. 冷却：同一地点规则刚触发过就不再打扰。
        if (candidate.cooldownKey != null && cooldownMinutes > 0) {
            val lastSameCooldown = ledger
                .filter { it.cooldownKey == candidate.cooldownKey && it.deliveredAt != null }
                .maxByOrNull { it.deliveredAt!! }
            if (lastSameCooldown != null) {
                val until = lastSameCooldown.deliveredAt!!.plus(cooldownMinutes, ChronoUnit.MINUTES)
                if (until.isAfter(now)) {
                    return BudgetDecision.Suppressed(SuppressReason.COOLDOWN, until)
                }
            }
        }

        // 4. 不能发在过去：候选时刻已过就现在发。
        var at = if (candidate.scheduledAt.isBefore(now)) now else candidate.scheduledAt
        val originalAt = at

        // 5. 静默时段顺延到下一个可发时刻。
        at = shiftOutOfQuietHours(at, zone, policy)

        // 6. 每日总额度。注意统计口径是「投递时刻所在的那个本地日」，
        //    所以夜里顺延到次日 08:00 的那条会算到次日头上——这正是跨零点重置。
        val deliveryDay = DayCueTime.localDateOf(at, zone)
        val deliveredThatDay = ledger.filter { entry ->
            entry.deliveredAt != null && DayCueTime.localDateOf(entry.deliveredAt, zone) == deliveryDay
        }
        if (deliveredThatDay.size >= policy.dailyLimit) {
            return BudgetDecision.Suppressed(SuppressReason.DAILY_LIMIT)
        }
        val kindLimit = policy.kindDailyLimit[candidate.kind]
        if (kindLimit != null && deliveredThatDay.count { it.kind == candidate.kind } >= kindLimit) {
            return BudgetDecision.Suppressed(SuppressReason.KIND_LIMIT)
        }

        // 7. 最小间隔：顺延而不是丢弃，但顺延后可能又落进静默时段，所以再规范化一次。
        val lastDelivered = ledger
            .filter { it.deliveredAt != null && it.kind.countsTowardBudget }
            .maxByOrNull { it.deliveredAt!! }
        if (lastDelivered != null) {
            val earliest = lastDelivered.deliveredAt!!.plus(policy.minIntervalMinutes, ChronoUnit.MINUTES)
            if (earliest.isAfter(at)) {
                at = shiftOutOfQuietHours(earliest, zone, policy)
            }
        }

        // 8. 过期一律丢弃，不补发。
        val expiresAt = candidate.expiresAt
        if (expiresAt != null && at.isAfter(expiresAt)) {
            return BudgetDecision.Expired("已过有效期，丢弃而不是补发")
        }

        return BudgetDecision.Deliver(at = at, deferred = at != candidate.scheduledAt)
    }

    /** 是否处于静默时段。静默区间可以跨零点（22:30–08:00），所以必须分两种情形判断。 */
    fun isQuiet(time: LocalTime, policy: BudgetPolicy): Boolean {
        val start = policy.quietStart
        val end = policy.quietEnd
        if (start == end) return false
        return if (start.isBefore(end)) {
            !time.isBefore(start) && time.isBefore(end)
        } else {
            !time.isBefore(start) || time.isBefore(end)
        }
    }

    /** 落在静默时段就顺延到下一个静默结束时刻；否则原样返回。 */
    fun shiftOutOfQuietHours(at: Instant, zone: ZoneId, policy: BudgetPolicy): Instant {
        val zoned = ZonedDateTime.ofInstant(at, zone)
        if (!isQuiet(zoned.toLocalTime(), policy)) return at
        val endToday = zoned.toLocalDate().atTime(policy.quietEnd)
        return if (zoned.toLocalTime().isBefore(policy.quietEnd)) {
            // 凌晨（00:00–08:00）：当天早晨就能发。
            endToday.atZone(zone).toInstant()
        } else {
            // 夜里（22:30–24:00）：次日早晨。
            endToday.plusDays(1).atZone(zone).toInstant()
        }
    }
}
