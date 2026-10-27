package com.daycue.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

// 圆角规范：只保留三档，避免「每个区块一个半径」的随机感。
// small 给标签与输入框，medium 给按钮与列表分组，large 给快速记录区与底部弹层。
val DayCueShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)
