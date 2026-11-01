package com.daycue.android.domain.radial

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 扇区几何的回归测试。
 *
 * 这一层出错的后果是「点记录却打开了课表」，而且在真机上很难靠手点定位。
 * 所以这里穷举角度、边界与扇区数量，把「角度 -> 扇区」的映射钉死。
 */
class RadialGeometryTest {

    private val center = RadialPoint(500f, 500f)

    @Test
    fun `四个扇区时正右正下正左正上分别落在预期扇区`() {
        // 起点在正上方（-90 度）顺时针：扇区 0 = 右上，1 = 右下，2 = 左下，3 = 左上
        assertEquals(1, RadialGeometry.sectorForAngle(0f, 4))
        assertEquals(2, RadialGeometry.sectorForAngle(90f, 4))
        assertEquals(3, RadialGeometry.sectorForAngle(180f, 4))
        assertEquals(0, RadialGeometry.sectorForAngle(270f, 4))
    }

    @Test
    fun `任意扇区的中心角度都会落回自己`() {
        for (count in listOf(2, 3, 4, 5, 6, 8)) {
            for (index in 0 until count) {
                val mid = RadialGeometry.sectorMidAngle(index, count)
                assertEquals(
                    "count=" + count + " index=" + index + " mid=" + mid,
                    index,
                    RadialGeometry.sectorForAngle(mid, count),
                )
            }
        }
    }

    @Test
    fun `扇区边界角度归入后一个扇区而不是前一个`() {
        // 4 个扇区、起点 -90：边界依次是 -90 / 0 / 90 / 180
        assertEquals(0, RadialGeometry.sectorForAngle(270f, 4)) // -90 == 270
        assertEquals(1, RadialGeometry.sectorForAngle(0f, 4))
        assertEquals(2, RadialGeometry.sectorForAngle(90f, 4))
        assertEquals(3, RadialGeometry.sectorForAngle(180f, 4))
    }

    @Test
    fun `角度归一化处理负值与超过一圈的值`() {
        assertEquals(270f, RadialGeometry.normalizeAngle(-90f), 0.001f)
        assertEquals(90f, RadialGeometry.normalizeAngle(450f), 0.001f)
        assertEquals(0f, RadialGeometry.normalizeAngle(0f), 0.001f)
        assertEquals(0f, RadialGeometry.normalizeAngle(360f), 0.001f)
    }

    @Test
    fun `只有一个扇区时任何角度都是第 0 个`() {
        assertEquals(0, RadialGeometry.sectorForAngle(0f, 1))
        assertEquals(0, RadialGeometry.sectorForAngle(123.4f, 1))
        assertEquals(0, RadialGeometry.sectorForAngle(359.9f, 1))
    }

    @Test
    fun `圆心以内命中 Center 环外命中 Outside`() {
        assertEquals(RadialHit.Center, RadialGeometry.hitTest(center, center, 50f, 150f, 5))
        assertEquals(
            RadialHit.Center,
            RadialGeometry.hitTest(RadialPoint(529f, 500f), center, 50f, 150f, 5),
        )
        assertEquals(
            RadialHit.Outside,
            RadialGeometry.hitTest(RadialPoint(700f, 500f), center, 50f, 150f, 5),
        )
    }

    @Test
    fun `恰好压在外半径上仍算命中扇区`() {
        val hit = RadialGeometry.hitTest(RadialPoint(650f, 500f), center, 50f, 150f, 4)
        assertTrue("外半径边界应仍可点中：" + hit, hit is RadialHit.Sector)
    }

    @Test
    fun `右侧上方区域命中第一个扇区`() {
        // 半径 100 处、正右偏上 45 度：relative = 135 度 -> 4 扇区里第 1 个之外？
        // 直接按坐标算：dx=70, dy=-70 -> 角度 315 度 -> relative 45 -> 扇区 0
        val hit = RadialGeometry.hitTest(RadialPoint(570f, 430f), center, 50f, 150f, 4)
        assertEquals(RadialHit.Sector(0), hit)
    }

    @Test
    fun `pointAt 与 angleDegrees 互为逆运算`() {
        for (angle in listOf(0f, 45f, 90f, 135f, 180f, 225f, 270f, 315f)) {
            val point = RadialGeometry.pointAt(center, 100f, angle)
            assertEquals(angle, RadialGeometry.angleDegrees(point, center), 0.01f)
            assertEquals(100f, RadialGeometry.distance(point, center), 0.01f)
        }
    }

    @Test
    fun `扇区数量为 0 时明确报错而不是返回垃圾值`() {
        val error = runCatching { RadialGeometry.sectorForAngle(0f, 0) }.exceptionOrNull()
        assertTrue("应以 IllegalArgumentException 失败，实际：" + error, error is IllegalArgumentException)
    }

    @Test
    fun `内外半径颠倒时明确报错`() {
        val error = runCatching { RadialGeometry.hitTest(center, center, 200f, 100f, 4) }.exceptionOrNull()
        assertTrue("应以 IllegalArgumentException 失败，实际：" + error, error is IllegalArgumentException)
    }
}
