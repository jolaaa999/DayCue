package com.daycue.android.ui.theme

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/**
 * 外观偏好。
 *
 * 只有三档：跟随系统 / 固定浅色 / 固定深色。不做「跟随壁纸动态取色」：
 * 同一份界面在两种设备上会变成完全不同的品牌观感，而课表与记录是用户长时间盯着的信息密集界面，
 * 稳定的低饱和配色比「跟随壁纸」更重要。
 */
enum class ThemeMode(val raw: String, val displayName: String) {
    SYSTEM("system", "跟随系统"),
    LIGHT("light", "浅色"),
    DARK("dark", "深色"),
    ;

    companion object {
        /** 库里存的是字符串（旧值或脏数据都可能出现），解析失败一律退回「跟随系统」。 */
        fun fromRaw(raw: String?): ThemeMode =
            entries.firstOrNull { it.raw == raw } ?: SYSTEM
    }
}

private val LightColors = lightColorScheme(
    primary = Teal,
    onPrimary = TealOn,
    primaryContainer = TealContainer,
    onPrimaryContainer = TealOnContainer,
    inversePrimary = TealDark,
    secondary = Sage,
    onSecondary = SageOn,
    secondaryContainer = SageContainer,
    onSecondaryContainer = SageOnContainer,
    tertiary = Amber,
    onTertiary = Color.White,
    tertiaryContainer = AmberContainer,
    onTertiaryContainer = AmberOnContainer,
    background = PaperBackground,
    onBackground = Ink,
    surface = PaperSurface,
    onSurface = Ink,
    surfaceVariant = PaperSurfaceMuted,
    onSurfaceVariant = InkVariant,
    surfaceTint = Teal,
    surfaceBright = PaperSurface,
    surfaceDim = PaperSurfaceHighest,
    surfaceContainerLowest = PaperSurface,
    surfaceContainerLow = PaperSurfaceLow,
    surfaceContainer = PaperSurfaceMuted,
    surfaceContainerHigh = PaperSurfaceHigh,
    surfaceContainerHighest = PaperSurfaceHighest,
    inverseSurface = NightSurfaceHighest,
    inverseOnSurface = NightInk,
    error = DangerRed,
    onError = DangerOn,
    errorContainer = DangerContainer,
    onErrorContainer = DangerOnContainer,
    outline = PaperOutline,
    outlineVariant = PaperOutlineVariant,
    scrim = Color.Black,
)

private val DarkColors = darkColorScheme(
    primary = TealDark,
    onPrimary = TealOnDark,
    primaryContainer = TealContainerDark,
    onPrimaryContainer = TealOnContainerDark,
    inversePrimary = Teal,
    secondary = SageDark,
    onSecondary = SageOnDark,
    secondaryContainer = SageContainerDark,
    onSecondaryContainer = SageOnContainerDark,
    tertiary = AmberDark,
    onTertiary = Color(0xFF3F2E0E),
    tertiaryContainer = AmberContainerDark,
    onTertiaryContainer = AmberOnContainerDark,
    background = NightBackground,
    onBackground = NightInk,
    surface = NightSurface,
    onSurface = NightInk,
    surfaceVariant = NightSurfaceMuted,
    onSurfaceVariant = NightInkVariant,
    surfaceTint = TealDark,
    surfaceBright = NightSurfaceHighest,
    surfaceDim = NightBackground,
    surfaceContainerLowest = Color(0xFF0C0F0E),
    surfaceContainerLow = NightSurfaceLow,
    surfaceContainer = NightSurfaceMuted,
    surfaceContainerHigh = NightSurfaceHigh,
    surfaceContainerHighest = NightSurfaceHighest,
    inverseSurface = NightInk,
    inverseOnSurface = NightSurfaceLow,
    error = DangerRedDark,
    onError = DangerOnDark,
    errorContainer = DangerContainerDark,
    onErrorContainer = DangerOnContainerDark,
    outline = NightOutline,
    outlineVariant = NightOutlineVariant,
    scrim = Color.Black,
)

/**
 * 全局主题。
 *
 * 亮色是「先做完整」的那一套，深色是它的等价映射（同一组色相，只调明度与饱和度），
 * 两者的层级关系必须一致：用户在深色下认出的结构，切到亮色后不该变。
 */
@Composable
fun DayCueTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    // 状态栏/导航栏图标颜色必须跟「当前渲染的主题」走，而不是跟系统深色开关走：
    // 用户把 App 固定成浅色、系统仍是深色时，不接管就会出现白底白字的状态栏。
    SystemBarAppearance(darkTheme = darkTheme)
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = DayCueTypography,
        shapes = DayCueShapes,
        content = content,
    )
}

/** 按外观偏好求值出「这次到底用不用深色」。放在这里而不是各页面里，避免两处给出不同结论。 */
@Composable
fun ThemeMode.resolveDark(systemDark: Boolean = isSystemInDarkTheme()): Boolean = when (this) {
    ThemeMode.SYSTEM -> systemDark
    ThemeMode.LIGHT -> false
    ThemeMode.DARK -> true
}

@Composable
private fun SystemBarAppearance(darkTheme: Boolean) {
    val view = LocalView.current
    if (view.isInEditMode) return
    SideEffect {
        val window = view.context.findActivity()?.window ?: return@SideEffect
        WindowCompat.getInsetsController(window, view).apply {
            isAppearanceLightStatusBars = !darkTheme
            isAppearanceLightNavigationBars = !darkTheme
        }
    }
}

/** Compose 里拿到的 Context 往往被主题包装过，必须一层层剥到 Activity 才能拿到 window。 */
private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return current as? Activity
}
