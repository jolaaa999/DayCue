package com.daycue.android.platform.outbox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * 重试策略：次数上限与指数退避。
 *
 * 纯函数，不碰协程与数据库；它决定的是「还能不能再试」「下次什么时候试」。
 */
class OutboxRetryPolicyTest {

    private val policy = OutboxRetryPolicy.DEFAULT

    @Test
    fun attemptsAreAllowedUntilMax() {
        assertTrue(policy.hasAttemptsLeft(0))
        assertTrue(policy.hasAttemptsLeft(1))
        assertTrue(policy.hasAttemptsLeft(4))
        assertFalse(policy.hasAttemptsLeft(5))
        assertFalse(policy.hasAttemptsLeft(6))
    }

    @Test
    fun delayGrowsExponentially() {
        assertEquals(60L, policy.retryDelaySeconds(1))
        assertEquals(120L, policy.retryDelaySeconds(2))
        assertEquals(240L, policy.retryDelaySeconds(3))
        assertEquals(480L, policy.retryDelaySeconds(4))
    }

    @Test
    fun delayIsCappedAtOneHour() {
        assertEquals(3600L, policy.retryDelaySeconds(100))
    }

    @Test
    fun zeroOrNegativeAttemptTreatedAsFirstDelay() {
        assertEquals(60L, policy.retryDelaySeconds(0))
        assertEquals(60L, policy.retryDelaySeconds(-3))
    }

    @Test
    fun nextRetryAtAddsDelayToNow() {
        val now = Instant.parse("2026-10-12T02:00:00Z")
        assertEquals(now.plusSeconds(120), policy.nextRetryAt(2, now))
    }

    @Test
    fun customPolicyIsRespected() {
        val custom = OutboxRetryPolicy(
            maxAttempts = 2,
            baseDelaySeconds = 5,
            maxDelaySeconds = 20,
            multiplier = 3,
        )
        assertTrue(custom.hasAttemptsLeft(1))
        assertFalse(custom.hasAttemptsLeft(2))
        assertEquals(5L, custom.retryDelaySeconds(1))
        assertEquals(15L, custom.retryDelaySeconds(2))
        assertEquals(20L, custom.retryDelaySeconds(3))
    }
}
