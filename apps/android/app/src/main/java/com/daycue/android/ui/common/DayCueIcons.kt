package com.daycue.android.ui.common

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * App 自绘的线性图标（麦克风、相机）。
 *
 * 为什么不引 material-icons-extended：那是个几 MB 的依赖，只为两个图标不值得，
 * 而且它整包都会进方法数统计。底栏与其它动作图标直接用 material-icons-core 里
 * 已有的 Outlined 版本（线框风格），与这里的两个自绘图标保持同一套描边宽度与风格。
 *
 * 描边统一 1.8f、端点圆角，视觉上与其他线性图标一致；颜色交给 Icon 的 tint，
 * 所以这里统一用黑色描边，实际显示时会被着色成当前内容色。
 */
object DayCueIcons {

    private const val STROKE = 1.8f

    /** 麦克风：胶囊 + 支架。用于「说一句」这个主入口。 */
    val Mic: ImageVector by lazy {
        ImageVector.Builder(
            name = "DayCueMic",
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = STROKE,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            ) {
                // 麦克风主体：上方半圆、下方半圆，中间两条竖边。
                moveTo(8.75f, 7f)
                lineTo(8.75f, 10.5f)
                quadTo(8.75f, 13.25f, 12f, 13.25f)
                quadTo(15.25f, 13.25f, 15.25f, 10.5f)
                lineTo(15.25f, 7f)
                quadTo(15.25f, 3.75f, 12f, 3.75f)
                quadTo(8.75f, 3.75f, 8.75f, 7f)
                close()
                // 拾音支架与底座。
                moveTo(6f, 10.75f)
                quadTo(6f, 16.75f, 12f, 16.75f)
                quadTo(18f, 16.75f, 18f, 10.75f)
                moveTo(12f, 16.75f)
                lineTo(12f, 20.25f)
                moveTo(9.25f, 20.25f)
                lineTo(14.75f, 20.25f)
            }
        }.build()
    }

    /**
     * 书签：底栏「记忆」用。
     *
     * 为什么不用 material-icons-core 的 Outlined.Star：core 里那一套的 Star 实际是实心星，
     * 和旁边三个线框图标放在一起会显得「只有它是实心的」。
     */
    val Bookmark: ImageVector by lazy {
        ImageVector.Builder(
            name = "DayCueBookmark",
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = STROKE,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            ) {
                moveTo(6.5f, 4.5f)
                lineTo(17.5f, 4.5f)
                lineTo(17.5f, 19.5f)
                lineTo(12f, 15f)
                lineTo(6.5f, 19.5f)
                close()
            }
        }.build()
    }

    /** 相机：机身 + 顶部取景凸起 + 镜头。用于「拍一张」。 */
    val Camera: ImageVector by lazy {
        ImageVector.Builder(
            name = "DayCueCamera",
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = STROKE,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            ) {
                // 机身：圆角矩形，四角用二次贝塞尔近似。
                moveTo(6f, 8f)
                lineTo(18f, 8f)
                quadTo(20.5f, 8f, 20.5f, 10.5f)
                lineTo(20.5f, 16.5f)
                quadTo(20.5f, 19f, 18f, 19f)
                lineTo(6f, 19f)
                quadTo(3.5f, 19f, 3.5f, 16.5f)
                lineTo(3.5f, 10.5f)
                quadTo(3.5f, 8f, 6f, 8f)
                close()
                // 顶部取景凸起。
                moveTo(9f, 8f)
                lineTo(10.4f, 5.25f)
                lineTo(13.6f, 5.25f)
                lineTo(15f, 8f)
                // 镜头：两个半圆拼成一个整圆。
                moveTo(9.4f, 13.5f)
                arcTo(2.6f, 2.6f, 0f, true, true, 14.6f, 13.5f)
                arcTo(2.6f, 2.6f, 0f, true, true, 9.4f, 13.5f)
                close()
            }
        }.build()
    }
}
