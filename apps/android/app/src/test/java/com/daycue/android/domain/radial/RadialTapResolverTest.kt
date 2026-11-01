package com.daycue.android.domain.radial

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 命中优先级回归。对应 ISSUE-20261029-028（二级菜单点圆心被当收起）与
 * ISSUE-20261029-023（点球身误选扇区）。
 */
class RadialTapResolverTest {

    private val inner = 168f
    private val outer = 432f
    private val center = RadialPoint(540f, 1200f)

    private fun at(degrees: Double, radius: Float): RadialPoint {
        val rad = Math.toRadians(degrees)
        return RadialPoint(
            (center.x + radius * Math.cos(rad)).toFloat(),
            (center.y + radius * Math.sin(rad)).toFloat(),
        )
    }

    private fun resolve(
        path: List<Int>,
        position: RadialPoint,
        count: Int = 5,
        armed: Boolean = true,
        exiting: Boolean = false,
    ) = resolveRadialTap(path, position, center, inner, outer, count, armed, exiting)

    @Test
    fun `最外层点球身收起`() {
        val outcome = resolve(emptyList(), at(0.0, 20f))
        assertEquals(RadialTapOutcome.Dismiss, outcome)
    }

    @Test
    fun `二级点圆心是返回而不是收起`() {
        // 球身热点覆盖的范围（0.5×内半径）在二级里必须让位给「返回」
        for (radius in listOf(0f, 20f, 60f, 83f, 150f)) {
            assertEquals(
                "半径 " + radius + " 处应返回上一级",
                RadialTapOutcome.Back,
                resolve(listOf(1), at(0.0, radius)),
            )
        }
    }

    @Test
    fun `最外层点圆心收起`() {
        assertEquals(RadialTapOutcome.Dismiss, resolve(emptyList(), at(0.0, 150f)))
    }

    @Test
    fun `扇环带命中对应扇区`() {
        // 5 个扇区各 72°：mid 角分别是 -54/-18/18/54/90 再往后
        assertEquals(RadialTapOutcome.Commit(0), resolve(emptyList(), at(-54.0, 300f)))
        assertEquals(RadialTapOutcome.Commit(1), resolve(emptyList(), at(18.0, 300f)))
        assertEquals(RadialTapOutcome.Commit(2), resolve(emptyList(), at(90.0, 300f)))
        assertEquals(RadialTapOutcome.Commit(3), resolve(emptyList(), at(162.0, 300f)))
        assertEquals(RadialTapOutcome.Commit(4), resolve(emptyList(), at(-126.0, 300f)))
    }

    @Test
    fun `二级的扇区照常执行`() {
        assertEquals(RadialTapOutcome.Commit(0), resolve(listOf(1), at(0.0, 300f), count = 2))
        assertEquals(RadialTapOutcome.Commit(1), resolve(listOf(1), at(180.0, 300f), count = 2))
    }

    @Test
    fun `环外点击收起`() {
        assertEquals(RadialTapOutcome.Dismiss, resolve(emptyList(), at(0.0, outer + 40f)))
        assertEquals(RadialTapOutcome.Dismiss, resolve(listOf(1), at(0.0, outer + 40f)))
    }

    @Test
    fun `未接管手势或正在退场时忽略`() {
        assertEquals(RadialTapOutcome.Ignore, resolve(emptyList(), at(18.0, 300f), armed = false))
        assertEquals(RadialTapOutcome.Ignore, resolve(emptyList(), at(18.0, 300f), exiting = true))
        // 忽略优先级最高：连「点球身」也不能在未接管时把菜单关掉
        assertEquals(RadialTapOutcome.Ignore, resolve(emptyList(), at(0.0, 10f), armed = false))
    }
}
