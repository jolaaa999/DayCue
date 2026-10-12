package com.daycue.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// DayCue 的主色是固定的靛蓝，而不是跟随系统壁纸的动态取色。
// 为什么：动态取色只在 Android 12+ 生效，同一份界面在两种设备上会变成完全不同的品牌观感，
// 而课表与记录是用户要长时间盯着的信息密集界面，稳定的低饱和配色比「跟随壁纸」更重要。
private val IndigoLight = Color(0xFF3B5BA5)
private val IndigoDark = Color(0xFFB3C4FF)
private val TealLight = Color(0xFF2F6F63)
private val TealDark = Color(0xFF9BD3C6)

private val LightColors = lightColorScheme(
    primary = IndigoLight,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDCE1FF),
    onPrimaryContainer = Color(0xFF001551),
    secondary = TealLight,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFBFEAE0),
    onSecondaryContainer = Color(0xFF00201B),
    tertiary = Color(0xFF7A5900),
    background = Color(0xFFFBF8FD),
    surface = Color(0xFFFBF8FD),
    error = Color(0xFFBA1A1A),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
)

private val DarkColors = darkColorScheme(
    primary = IndigoDark,
    onPrimary = Color(0xFF08218A),
    primaryContainer = Color(0xFF253D8E),
    onPrimaryContainer = Color(0xFFDCE1FF),
    secondary = TealDark,
    onSecondary = Color(0xFF00382F),
    secondaryContainer = Color(0xFF175045),
    onSecondaryContainer = Color(0xFFBFEAE0),
    tertiary = Color(0xFFF0C048),
    background = Color(0xFF1B1B1F),
    surface = Color(0xFF1B1B1F),
    error = Color(0xFFFFB4AB),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
)

/**
 * 全局主题。
 *
 * 排版沿用 Material3 默认值：界面文案全是简体中文，字体族交给系统提供，
 * 硬指定一个西文字体族只会让中文回退时字重与标点都变难看。
 * 浅色与深色两套配色是手写的，不依赖动态取色，保证「没有 GMS 的设备」也拿到同一套观感。
 */
@Composable
fun DayCueTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = Typography(),
        content = content,
    )
}
