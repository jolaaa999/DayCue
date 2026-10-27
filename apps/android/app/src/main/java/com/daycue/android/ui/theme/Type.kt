package com.daycue.android.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// 排版规范。
//
// 字体族交给系统：中文没有内置字体时系统会回退到厂商字体，硬指定西文字体族只会让
// 中文回退后的字重与标点变难看。用户若在系统里换了字体（本机就是手写体），界面会跟着变，
// 这是系统级设置，App 不去覆盖它——覆盖的代价是要内置一套中文字体（体积与授权都要另议）。
//
// 字号尺度按「正文 16sp、辅助信息不低于 13sp」定，比 Material 默认更大一档：
// 原界面大量使用 12sp 说明文字，在深色背景上长时间看很吃力。
// 全部样式都不设固定行高上限以外的约束，也不给行高以外的高度，系统字号放大时不会被裁切。

private val Default = FontFamily.SansSerif

/** 统一关掉平台默认的 includeFontPadding 残留，让中英文混排的行高可控。 */
private fun base(size: Int, lineHeight: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
    fontFamily = Default,
    fontSize = size.sp,
    lineHeight = lineHeight.sp,
    fontWeight = weight,
    platformStyle = PlatformTextStyle(includeFontPadding = false),
)

val DayCueTypography = Typography(
    // 页面主标题（今天/记录/记忆/设置）
    headlineSmall = base(24, 32, FontWeight.SemiBold),
    // 二级标题：分组标题、详情页大标题
    titleLarge = base(20, 28, FontWeight.SemiBold),
    titleMedium = base(17, 24, FontWeight.SemiBold),
    titleSmall = base(15, 22, FontWeight.Medium),
    // 正文
    bodyLarge = base(16, 24),
    bodyMedium = base(15, 22),
    bodySmall = base(13, 19),
    // 按钮与标签
    labelLarge = base(15, 20, FontWeight.Medium),
    labelMedium = base(13, 18, FontWeight.Medium),
    labelSmall = base(12, 16, FontWeight.Medium),
)
