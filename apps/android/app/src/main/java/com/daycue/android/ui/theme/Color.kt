package com.daycue.android.ui.theme

import androidx.compose.ui.graphics.Color

// DayCue 的配色令牌。
//
// 为什么把颜色集中成常量而不是散在每个页面里写 Color(0xFF...)：
// 一个页面里临时调一次色值，深色主题下就会漏改，而漏改的颜色在亮色下看着完全正常，
// 只有用户切到深色（本机默认就是深色）才会暴露。这里只留一份真值。

// ---- 亮色 ----

/** 强调色：低饱和青绿。既用于主按钮，也用于导航选中态，两者不再是两种颜色。 */
internal val Teal = Color(0xFF2E6B5C)
internal val TealOn = Color(0xFFFFFFFF)
internal val TealContainer = Color(0xFFCFE9DF)
internal val TealOnContainer = Color(0xFF0A2C24)

/** 次要色：偏灰的同一色相，用在不需要抢注意力的元素上。 */
internal val Sage = Color(0xFF52665F)
internal val SageOn = Color(0xFFFFFFFF)
internal val SageContainer = Color(0xFFDCE7E1)
internal val SageOnContainer = Color(0xFF14261F)

/** 暖色点缀：只用于「时间/地点」这类元信息上的少量强调，不做大面积底色。 */
internal val Amber = Color(0xFF8A6A46)
internal val AmberContainer = Color(0xFFF2E4CE)
internal val AmberOnContainer = Color(0xFF342311)

internal val PaperBackground = Color(0xFFF7F6F1)
internal val PaperSurface = Color(0xFFFFFFFF)
internal val PaperSurfaceLow = Color(0xFFFAF9F5)
internal val PaperSurfaceMuted = Color(0xFFF2F1EB)
internal val PaperSurfaceHigh = Color(0xFFECEBE4)
internal val PaperSurfaceHighest = Color(0xFFE5E4DD)
internal val Ink = Color(0xFF1B1F1C)
internal val InkVariant = Color(0xFF5A645E)
internal val PaperOutline = Color(0xFF8E9791)
internal val PaperOutlineVariant = Color(0xFFDBDED7)

internal val DangerRed = Color(0xFFB3261E)
internal val DangerOn = Color(0xFFFFFFFF)
internal val DangerContainer = Color(0xFFF7DAD7)
internal val DangerOnContainer = Color(0xFF410E0B)

// ---- 深色 ----

internal val TealDark = Color(0xFF8FD3C0)
internal val TealOnDark = Color(0xFF00382D)
internal val TealContainerDark = Color(0xFF1C4A3F)
internal val TealOnContainerDark = Color(0xFFC6EBDE)

internal val SageDark = Color(0xFFB4CBC1)
internal val SageOnDark = Color(0xFF1F352D)
internal val SageContainerDark = Color(0xFF354B43)
internal val SageOnContainerDark = Color(0xFFD0E8DE)

internal val AmberDark = Color(0xFFE0C38E)
internal val AmberContainerDark = Color(0xFF584327)
internal val AmberOnContainerDark = Color(0xFFFBE0B4)

internal val NightBackground = Color(0xFF101413)
internal val NightSurface = Color(0xFF141817)
internal val NightSurfaceLow = Color(0xFF171B1A)
internal val NightSurfaceMuted = Color(0xFF1C201F)
internal val NightSurfaceHigh = Color(0xFF242827)
internal val NightSurfaceHighest = Color(0xFF2C3130)
internal val NightInk = Color(0xFFE4E8E5)
internal val NightInkVariant = Color(0xFFA7B0AA)
internal val NightOutline = Color(0xFF7C8681)
internal val NightOutlineVariant = Color(0xFF333A37)

internal val DangerRedDark = Color(0xFFFFB4AB)
internal val DangerOnDark = Color(0xFF690005)
internal val DangerContainerDark = Color(0xFF5C1A16)
internal val DangerOnContainerDark = Color(0xFFFFDAD5)
