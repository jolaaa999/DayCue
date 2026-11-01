package com.daycue.android.domain.radial

/**
 * 一次点在扇区菜单上的结果。
 *
 * 之所以把它做成纯数据而不是直接在 Compose 里 if/else：
 * 「点球身收起」「点圆心返回」「点扇区执行」三个命中区的优先级已经错过两次
 * （ISSUE-20261029-023、ISSUE-20261029-028），而 Compose 里的手势回调没法写单元测试。
 * 抽到这里以后，边界条件可以用 JVM 测试锁住，真机上只需要确认「有没有反应」。
 */
sealed interface RadialTapOutcome {
    /** 关闭整个菜单。 */
    data object Dismiss : RadialTapOutcome

    /** 退回上一级。 */
    data object Back : RadialTapOutcome

    /** 执行第 [index] 个扇区。 */
    data class Commit(val index: Int) : RadialTapOutcome

    /** 还没接管手势（刚展开的防误触窗口）或正在退场，什么也不做。 */
    data object Ignore : RadialTapOutcome
}

/** 点在球身上算「再点一次收起」的热点半径，相对扇环内半径。 */
const val BALL_HOTSPOT_RATIO = 0.5f

/**
 * 决定一次点击该做什么。
 *
 * 优先级（不要随意调整，每一条都对应一个真机事故）：
 * 1. 未接管手势 / 正在退场 → [RadialTapOutcome.Ignore]；
 * 2. 最外层点球身 → 收起。**只在最外层**：二级菜单圆心写的是「返回」，
 *    如果这里不限层级，热点会把圆心命中区整块吃掉，「返回」永远走不到（ISSUE-028）；
 * 3. 圆心区 → 最外层收起、子级退回上一级；
 * 4. 扇环带 → 执行对应扇区；
 * 5. 环外 → 收起。
 *
 * @param path 当前层级路径，空表示最外层
 */
fun resolveRadialTap(
    path: List<Int>,
    position: RadialPoint,
    center: RadialPoint,
    innerRadius: Float,
    outerRadius: Float,
    count: Int,
    armed: Boolean,
    exiting: Boolean,
): RadialTapOutcome {
    if (!armed || exiting) return RadialTapOutcome.Ignore

    val distance = RadialGeometry.distance(position, center)
    if (path.isEmpty() && distance <= innerRadius * BALL_HOTSPOT_RATIO) {
        return RadialTapOutcome.Dismiss
    }
    return when (val hit = RadialGeometry.hitTest(position, center, innerRadius, outerRadius, count)) {
        is RadialHit.Sector -> RadialTapOutcome.Commit(hit.index)
        // 走到这里说明不在球身热点里：最外层收起，子级退回上一级（与圆心文字一致）
        RadialHit.Center -> if (path.isEmpty()) RadialTapOutcome.Dismiss else RadialTapOutcome.Back
        RadialHit.Outside -> RadialTapOutcome.Dismiss
    }
}
