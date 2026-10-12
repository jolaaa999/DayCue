package com.daycue.android.data.repository

import com.daycue.android.domain.location.ProactiveReceiptRow
import com.daycue.android.domain.location.ProactiveReceiptStore
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.proactive.ProactiveInteraction
import com.daycue.android.domain.proactive.ProactiveInteractionReceipt
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * 通知交互回执的落账语义。
 *
 * 这里最要紧的一条是**预算**：把「用户划掉已收到的通知」当成「投递前被应用取消」，
 * 会让 deliveredAt 留空、当日额度被退还，于是用户越划掉越被同类提醒打扰。
 * 两个方向都要锁死：dismissed 必须占预算，cancelled 必须释放预算。
 */
class ProactiveReceiptServiceTest {

    private val at: Instant = Instant.parse("2026-10-12T02:10:00Z")

    private class FakeReceiptStore(
        var row: ProactiveReceiptRow?,
    ) : ProactiveReceiptStore {

        var appliedState: ProactiveState? = null
        var appliedReason: String? = null
        var appliedDeliveredAt: Instant? = null
        var applyCount = 0

        override suspend fun findReceiptRow(dedupeKey: String): ProactiveReceiptRow? = row

        override suspend fun applyInteraction(
            id: String,
            state: ProactiveState,
            reason: String?,
            deliveredAt: Instant?,
            at: Instant,
        ) {
            applyCount += 1
            appliedState = state
            appliedReason = reason
            appliedDeliveredAt = deliveredAt
        }
    }

    private fun pendingRow(state: ProactiveState = ProactiveState.PENDING) = ProactiveReceiptRow(
        id = "row-1",
        dedupeKey = "geo:r1:2026-10-12",
        kind = ProactiveKind.GEO,
        state = state,
        deliveredAt = null,
    )

    private fun receipt(interaction: ProactiveInteraction) = ProactiveInteractionReceipt(
        dedupeKey = "geo:r1:2026-10-12",
        interaction = interaction,
        at = at,
    )

    @Test
    fun dismissedCountsAsDeliveredAndKeepsBudget() = runTest {
        val store = FakeReceiptStore(pendingRow())

        val outcome = ProactiveReceiptService(store).apply(receipt(ProactiveInteraction.DISMISSED))

        assertTrue(outcome.applied)
        assertEquals("划掉的是已经收到的通知，不是没发出去", ProactiveState.DELIVERED, outcome.state)
        // deliveredAt 的含义是「交互时确认它已经到达设备」，不是系统展示时刻（系统不给这个回执）。
        assertEquals(at, outcome.deliveredAt)
        assertEquals(ProactiveState.DELIVERED, store.appliedState)
        assertTrue(
            "用户关闭已收到的通知不应返还预算，否则会继续被同类提醒打扰",
            ProactiveState.DELIVERED.blocksNewCandidate,
        )
        // 状态本身会显示成「已发出」，靠 reason 保留「用户是划掉而不是点开」的区别。
        assertEquals(ProactiveInteraction.DISMISSED.stateReason, store.appliedReason)
    }

    @Test
    fun appCancelledBeforeDeliveryReleasesBudget() = runTest {
        val store = FakeReceiptStore(pendingRow())

        val outcome = ProactiveReceiptService(store).apply(receipt(ProactiveInteraction.CANCELLED))

        assertTrue(outcome.applied)
        assertEquals(ProactiveState.CANCELLED, outcome.state)
        assertNull("没发出去就没有到达时刻", outcome.deliveredAt)
        assertNull(store.appliedDeliveredAt)
        assertFalse(
            "确实没发出去的提醒不该继续占用当日额度",
            ProactiveState.CANCELLED.blocksNewCandidate,
        )
    }

    @Test
    fun expiredNeverClaimsTheDeviceWasReached() = runTest {
        val store = FakeReceiptStore(pendingRow())

        val outcome = ProactiveReceiptService(store).apply(receipt(ProactiveInteraction.EXPIRED))

        assertEquals(ProactiveState.EXPIRED, outcome.state)
        assertNull("系统过期可能根本没显示过，不能写 deliveredAt", outcome.deliveredAt)
    }

    @Test
    fun openedMarksDeliveredWithTheInteractionTime() = runTest {
        val store = FakeReceiptStore(pendingRow())

        val outcome = ProactiveReceiptService(store).apply(receipt(ProactiveInteraction.OPENED))

        assertEquals(ProactiveState.DELIVERED, outcome.state)
        assertEquals(at, outcome.deliveredAt)
        assertNull("点开不需要额外解释", store.appliedReason)
    }

    @Test
    fun missingLedgerRowIsNeverFabricated() = runTest {
        val store = FakeReceiptStore(null)

        val outcome = ProactiveReceiptService(store).apply(receipt(ProactiveInteraction.OPENED))

        assertFalse("账本里没有这条就不能凭空记一条已发出", outcome.applied)
        assertEquals(0, store.applyCount)
    }

    @Test
    fun terminalRowIsNotReversedByALateReceipt() = runTest {
        // 已经取消的提醒又收到一个迟到的「点开」：不能复活成 delivered 再占预算。
        val store = FakeReceiptStore(pendingRow(ProactiveState.CANCELLED))

        val outcome = ProactiveReceiptService(store).apply(receipt(ProactiveInteraction.OPENED))

        assertFalse(outcome.applied)
        assertEquals(ProactiveState.CANCELLED, outcome.state)
        assertEquals(0, store.applyCount)
    }
}
