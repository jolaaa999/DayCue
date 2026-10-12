package com.daycue.android.platform.outbox

import java.time.Instant

/**
 * outbox 重试策略：次数上限 + 指数退避。
 *
 * 为什么要上限：没有上限时，一条「一直失败但被判成可重试」的操作会跟着周期作业
 * 永远排队，界面上的待同步条数永远不归零，而且永远没有结论。
 * 到顶后转入终止失败态（failed），把原因留在 last_error 里，由用户或运维决定。
 */
data class OutboxRetryPolicy(
    /** 含首次执行在内的尝试总次数。 */
    val maxAttempts: Int = DEFAULT_MAX_ATTEMPTS,
    val baseDelaySeconds: Long = DEFAULT_BASE_DELAY_SECONDS,
    val maxDelaySeconds: Long = DEFAULT_MAX_DELAY_SECONDS,
    val multiplier: Long = DEFAULT_MULTIPLIER,
) {

    /** attempt 是「已经执行过几次」：抢占时 DAO 会先自增，所以执行前 attempt 至少是 1。 */
    fun hasAttemptsLeft(attempt: Int): Boolean = attempt < maxAttempts

    /**
     * 第 attempt 次执行失败后的等待秒数：base、base*2、base*4……
     *
     * 用循环而不是幂运算：attempt 理论上可能被脏数据写得很大，
     * 幂运算会先溢出成负数，再被 coerceAtMost 变成一个荒唐的负延迟。
     */
    fun retryDelaySeconds(attempt: Int): Long {
        var seconds = baseDelaySeconds
        val doublings = (attempt - 1).coerceIn(0, MAX_DOUBLINGS)
        repeat(doublings) {
            seconds = (seconds * multiplier).coerceAtMost(maxDelaySeconds)
        }
        return seconds.coerceAtMost(maxDelaySeconds)
    }

    fun nextRetryAt(attempt: Int, now: Instant): Instant = now.plusSeconds(retryDelaySeconds(attempt))

    companion object {
        const val DEFAULT_MAX_ATTEMPTS = 5
        const val DEFAULT_BASE_DELAY_SECONDS = 60L
        const val DEFAULT_MAX_DELAY_SECONDS = 3600L
        const val DEFAULT_MULTIPLIER = 2L

        /** 2^20 已经远超任何上限，再乘下去只会溢出。 */
        private const val MAX_DOUBLINGS = 20

        val DEFAULT = OutboxRetryPolicy()
    }
}
