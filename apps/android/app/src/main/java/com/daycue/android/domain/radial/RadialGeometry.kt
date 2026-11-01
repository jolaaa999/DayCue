package com.daycue.android.domain.radial

import kotlin.math.atan2
import kotlin.math.floor
import kotlin.math.hypot

/**
 * 屏幕坐标点。
 *
 * y 轴向下为正（与 View / Compose 的坐标系一致），角度 0 度指向正右、顺时针增加。
 * 这一定义必须写死在一个地方：悬浮球的绘制与命中测试若各自换算角度，
 * 画出来的扇区和能点中的扇区会错开，且只在真机上才看得出来。
 */
data class RadialPoint(val x: Float, val y: Float)

/** 一次命中的结果。 */
sealed interface RadialHit {
    /** 圆心区域：一级菜单里是「关闭」，多级菜单里是「返回上一级」。 */
    data object Center : RadialHit

    /** 命中了第 [index] 个扇区。 */
    data class Sector(val index: Int) : RadialHit

    /** 落在环外：视为取消（松手在空白处不应该误触发任何动作）。 */
    data object Outside : RadialHit
}

/**
 * 环形扇区菜单的几何计算。
 *
 * 全部是纯函数，不含任何 Android 类型，因此可以在 JVM 单测里穷举角度与边界。
 * 这一层必须可测：扇区偏移错 45 度这类问题在真机上表现成「点记录却打开了课表」，
 * 靠手工点是点不准的。
 */
object RadialGeometry {

    /** 第一个扇区的起始角度：-90 度 = 正上方。菜单从头顶开始顺时针排布。 */
    const val START_ROTATION_DEGREES: Float = -90f

    /** 把任意角度归一到 [0, 360)。 */
    fun normalizeAngle(degrees: Float): Float {
        val mod = degrees % 360f
        return if (mod < 0f) mod + 360f else mod
    }

    /** 每个扇区占用的角度。 */
    fun sectorSweepDegrees(count: Int): Float {
        require(count > 0) { "扇区数量必须为正数，实际为 " + count }
        return 360f / count
    }

    /** 点到圆心的角度（度）。 */
    fun angleDegrees(point: RadialPoint, center: RadialPoint): Float {
        val dx = (point.x - center.x).toDouble()
        val dy = (point.y - center.y).toDouble()
        return normalizeAngle(Math.toDegrees(atan2(dy, dx)).toFloat())
    }

    /** 点到圆心的距离。 */
    fun distance(point: RadialPoint, center: RadialPoint): Float =
        hypot(point.x - center.x, point.y - center.y)

    /**
     * 给定角度落在第几个扇区。
     *
     * 起点是 [rotationDegrees]，顺时针切分。用 floor 而不是四舍五入：
     * 扇区是左闭右开区间，否则每个边界都会有一个角度的重复归属。
     */
    fun sectorForAngle(
        angleDegrees: Float,
        count: Int,
        rotationDegrees: Float = START_ROTATION_DEGREES,
    ): Int {
        val sweep = sectorSweepDegrees(count)
        val relative = normalizeAngle(angleDegrees - rotationDegrees)
        // 整除保护：relative 恰好接近 360 时 floor 可能给出 count，夹回最后一个扇区
        return floor(relative / sweep).toInt().coerceIn(0, count - 1)
    }

    /** 某个扇区的中心角度，绘制文字与高亮时用同一个来源。 */
    fun sectorMidAngle(
        index: Int,
        count: Int,
        rotationDegrees: Float = START_ROTATION_DEGREES,
    ): Float {
        require(index in 0 until count) { "扇区下标越界：" + index + " / " + count }
        return normalizeAngle(rotationDegrees + sectorSweepDegrees(count) * (index + 0.5f))
    }

    /** 以圆心、半径、角度求一个点，绘制扇区标签位置时用。 */
    fun pointAt(center: RadialPoint, radius: Float, angleDegrees: Float): RadialPoint {
        val radians = Math.toRadians(angleDegrees.toDouble())
        return RadialPoint(
            x = center.x + (radius * kotlin.math.cos(radians)).toFloat(),
            y = center.y + (radius * kotlin.math.sin(radians)).toFloat(),
        )
    }

    /**
     * 命中测试：内圈是圆心按钮，环带里按角度分扇区，环外是取消区。
     *
     * [innerRadius] 与 [outerRadius] 用像素传入，调用方负责 dp 换算，
     * 这样这一层完全不依赖 Density。
     */
    fun hitTest(
        point: RadialPoint,
        center: RadialPoint,
        innerRadius: Float,
        outerRadius: Float,
        count: Int,
        rotationDegrees: Float = START_ROTATION_DEGREES,
    ): RadialHit {
        require(count > 0) { "扇区数量必须为正数，实际为 " + count }
        require(outerRadius > innerRadius) {
            "外半径必须大于内半径：inner=" + innerRadius + " outer=" + outerRadius
        }
        val distance = distance(point, center)
        return when {
            distance < innerRadius -> RadialHit.Center
            distance > outerRadius -> RadialHit.Outside
            else -> RadialHit.Sector(
                sectorForAngle(angleDegrees(point, center), count, rotationDegrees),
            )
        }
    }
}
