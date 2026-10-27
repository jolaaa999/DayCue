package com.daycue.android.ui.theme

import androidx.compose.ui.unit.dp

/**
 * 尺寸规范。
 *
 * 为什么做成常量而不是随手写 dp：这一轮的目标之一是「间距统一」，
 * 而间距不一致从来不是有人故意写错，是每处都各自写了一个「差不多」的数字。
 */
object DayCueSpacing {
    /** 页面左右边距。 */
    val Screen: androidx.compose.ui.unit.Dp = 20.dp

    /** 分组区块之间的间距。 */
    val Section: androidx.compose.ui.unit.Dp = 24.dp

    val XSmall: androidx.compose.ui.unit.Dp = 4.dp
    val Small: androidx.compose.ui.unit.Dp = 8.dp
    val Medium: androidx.compose.ui.unit.Dp = 12.dp
    val Large: androidx.compose.ui.unit.Dp = 16.dp
    val XLarge: androidx.compose.ui.unit.Dp = 20.dp
    val XXLarge: androidx.compose.ui.unit.Dp = 28.dp
}

/** 可交互元素的最小触控区域。低于 48dp 的点击目标在单手操作时命中率会明显下降。 */
val MinTouchTarget = 48.dp

/** 列表行最小高度：容纳两行文字（标题 + 辅助信息）后仍不小于触控最小尺寸。 */
val MinListRowHeight = 56.dp
