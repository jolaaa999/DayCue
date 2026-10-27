package com.daycue.android.ui.common

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinListRowHeight
import com.daycue.android.ui.theme.MinTouchTarget
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

// ---------------------------------------------------------------------------
// 这一层是界面的公共语言：外壳、分组、行、按钮、输入、状态标签、空态、提示。
// 之所以收敛成组件而不是各页各写：上一版最明显的问题是同一个「空状态」在四个页面
// 有四种留白和字号，用户感受不到这是一套界面。
// ---------------------------------------------------------------------------

/**
 * 页面外壳：标题栏 + 可选返回 + 可选动作。
 *
 * showTopBar = false 时只保留安全区，交给页面自己画页头（今天页用紧凑问候头，
 * 不需要再叠一条 64dp 的标题栏）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DayCueScreen(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    showTopBar: Boolean = true,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            if (showTopBar) {
                TopAppBar(
                    title = { Text(title, style = MaterialTheme.typography.titleLarge) },
                    navigationIcon = {
                        if (onBack != null) {
                            IconButton(onClick = onBack) {
                                Icon(
                                    imageVector = Icons.Outlined.KeyboardArrowLeft,
                                    contentDescription = "返回",
                                    modifier = Modifier.size(26.dp),
                                )
                            }
                        }
                    },
                    actions = actions,
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        titleContentColor = MaterialTheme.colorScheme.onSurface,
                        actionIconContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    ),
                )
            }
        },
        content = content,
    )
}

/**
 * 分区标题。
 *
 * subtitle 写的是这一块的口径（例如「按截止时刻过滤」），不是产品说明：
 * 用户需要知道结论是怎么来的，不需要知道代码怎么写的。
 */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = DayCueSpacing.XLarge, bottom = DayCueSpacing.Small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        trailing?.invoke()
    }
}

/** 分组标题：比分区标题轻，用在设置这类「一组行」前面。 */
@Composable
fun GroupLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = DayCueSpacing.XSmall, top = DayCueSpacing.XLarge, bottom = DayCueSpacing.Small),
    )
}

/**
 * 空态图标：柔和主色圆底 + 线性图标。
 *
 * 空态最容易被做成「一段灰字」，加一个图标能一眼带出「这里本来是做什么的」；
 * 用主色而不是灰，是因为「还没有内容」不等于「出错了」。
 */
@Composable
fun EmptyStateGlyph(icon: ImageVector, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.size(56.dp),
        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.6f),
        shape = CircleShape,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(26.dp),
            )
        }
    }
}

/**
 * 空态：标题 + 一句说明 + 可选动作。
 *
 * 留白比上一版收紧了一半：一屏里出现三个空态时，原来的版本会把可用内容顶到屏幕外。
 */
@Composable
fun EmptyState(
    title: String,
    description: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = DayCueSpacing.Large, horizontal = DayCueSpacing.Small),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleSmall, textAlign = TextAlign.Center)
        Spacer(Modifier.height(DayCueSpacing.XSmall))
        Text(
            text = description,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(DayCueSpacing.Small))
            TextButton(onClick = onAction, modifier = Modifier.heightIn(min = MinTouchTarget)) {
                Text(actionLabel, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

/**
 * 外部写入状态标签。
 *
 * needsAttention 的状态必须用警示色：一旦渲染成和「已写入」一样，
 * 就等于在界面上虚报同步成功。
 */
@Composable
fun WriteStateBadge(state: ExternalWriteState, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val containerColor = if (state.needsAttention) colors.errorContainer else colors.secondaryContainer
    val contentColor = if (state.needsAttention) colors.onErrorContainer else colors.onSecondaryContainer
    Surface(color = containerColor, contentColor = contentColor, shape = MaterialTheme.shapes.extraSmall, modifier = modifier) {
        Text(
            text = state.displayName,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = DayCueSpacing.Small, vertical = 3.dp),
        )
    }
}

/** 轻量标签：类型、来源这类「一个词」的标注，不用容器色，避免满屏色块。 */
@Composable
fun MiniTag(text: String, modifier: Modifier = Modifier, tone: MiniTagTone = MiniTagTone.Neutral) {
    val colors = MaterialTheme.colorScheme
    val (container, content) = when (tone) {
        MiniTagTone.Neutral -> colors.surfaceContainerHigh to colors.onSurfaceVariant
        MiniTagTone.Accent -> colors.primaryContainer to colors.onPrimaryContainer
        MiniTagTone.Warning -> colors.errorContainer to colors.onErrorContainer
    }
    Surface(color = container, contentColor = content, shape = MaterialTheme.shapes.extraSmall, modifier = modifier) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = DayCueSpacing.Small, vertical = 2.dp),
        )
    }
}

enum class MiniTagTone { Neutral, Accent, Warning }

/** 一行「标签 : 值」，用于详情页的字段展示。 */
@Composable
fun KeyValueLine(label: String, value: String, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = MinTouchTarget)
            .padding(vertical = DayCueSpacing.XSmall),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(text = value, style = MaterialTheme.typography.bodyMedium)
    }
}

/**
 * 提示条：正常提示用主色容器，错误用错误色。真实错误信息必须原样显示。
 *
 * 不做成整块卡片：提示是「一句话的插话」，不是内容，所以只画一条左侧色条 + 文字。
 */
@Composable
fun MessageCard(text: String, modifier: Modifier = Modifier, isError: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    val containerColor = if (isError) colors.errorContainer else colors.primaryContainer
    val contentColor = if (isError) colors.onErrorContainer else colors.onPrimaryContainer
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = containerColor,
        contentColor = contentColor,
        shape = MaterialTheme.shapes.medium,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = DayCueSpacing.Medium, vertical = DayCueSpacing.Medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                color = contentColor.copy(alpha = 0.5f),
                shape = CircleShape,
                modifier = Modifier.size(6.dp),
                content = {},
            )
            Spacer(Modifier.width(DayCueSpacing.Small))
            Text(text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        }
    }
}

/**
 * 需要用户注意的一件事：一行文字 + 一个动作。
 *
 * 用于「有几条同步异常」「N 条记录待处理」这种「有内容但不占正文」的提示：
 * 上一版把每一类问题都铺成一个完整分区，空的时候各占一屏，异常的时候反而更难找。
 */
@Composable
fun NoticeRow(
    text: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    tone: MiniTagTone = MiniTagTone.Warning,
) {
    val colors = MaterialTheme.colorScheme
    val containerColor = if (tone == MiniTagTone.Warning) colors.errorContainer else colors.surfaceContainer
    val contentColor = if (tone == MiniTagTone.Warning) colors.onErrorContainer else colors.onSurface
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = containerColor,
        contentColor = contentColor,
        shape = MaterialTheme.shapes.medium,
        border = if (tone == MiniTagTone.Warning) {
            null
        } else {
            BorderStroke(1.dp, colors.outlineVariant.copy(alpha = 0.7f))
        },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = MinListRowHeight)
                .padding(start = DayCueSpacing.Medium, end = DayCueSpacing.Small, top = DayCueSpacing.XSmall, bottom = DayCueSpacing.XSmall),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            if (actionLabel != null && onAction != null) {
                TextButton(onClick = onAction, modifier = Modifier.heightIn(min = MinTouchTarget)) {
                    Text(actionLabel, style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 分组与列表行（设置页与列表页共用）
// ---------------------------------------------------------------------------

/** 一组行：圆角容器 + 行间细分割线。整页用「分组块」而不是「每行一张卡片」。 */
@Composable
fun SettingGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.large,
    ) {
        Column(Modifier.padding(vertical = DayCueSpacing.XSmall), content = content)
    }
}

/** 组内分割线：只在两行之间画，且刻意做浅，不抢视觉。 */
@Composable
fun RowDivider() {
    HorizontalDivider(
        modifier = Modifier.padding(start = DayCueSpacing.Large, end = DayCueSpacing.Large),
        thickness = 1.dp,
        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
    )
}

/**
 * 可导航行：图标 + 标题 + 说明 + 右箭头。
 *
 * 触控高度不小于 56dp；说明文字用两行以内，因为我们不加省略号的时机比加更难解释。
 */
@Composable
fun NavigationRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    icon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
    showDivider: Boolean = false,
) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = MinListRowHeight)
                .then(
                    if (onClick != null) {
                        Modifier.clickableRow(onClick = onClick)
                    } else {
                        Modifier
                    },
                )
                .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (icon != null) {
                // 固定 24dp 图标槽：不同图标的实际绘制宽度不同，直接排会让每行标题的起点
                // 错开 1–2dp，一列六行看下来就是「文字在轻微抖动」。
                Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(21.dp),
                    )
                }
                Spacer(Modifier.width(DayCueSpacing.Large))
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                if (subtitle != null) {
                    Text(
                        subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (onClick != null) {
                Icon(
                    imageVector = Icons.Outlined.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        if (showDivider) RowDivider()
    }
}

/** 键值行：左侧标签、右侧值，可选点击进入编辑。 */
@Composable
fun ValueRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    showDivider: Boolean = false,
) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = MinTouchTarget)
                .then(if (onClick != null) Modifier.clickableRow(onClick = onClick) else Modifier)
                .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = value,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (onClick != null) {
                Icon(
                    imageVector = Icons.Outlined.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .padding(start = DayCueSpacing.XSmall)
                        .size(18.dp),
                )
            }
        }
        if (showDivider) RowDivider()
    }
}

/** 开关行。整行可点：只有开关本身可点时，手指要精确命中 52x32 的区域。 */
@Composable
fun SwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    enabled: Boolean = true,
    showDivider: Boolean = false,
) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = MinListRowHeight)
                .clickableRow(enabled = enabled, onClick = { onCheckedChange(!checked) })
                .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (enabled) {
                        MaterialTheme.colorScheme.onSurface
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
                if (subtitle != null) {
                    Text(
                        subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.width(DayCueSpacing.Medium))
            Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
        }
        if (showDivider) RowDivider()
    }
}

/**
 * 状态行：名称 + 当前状态 + 右侧动作。
 *
 * 权限、连接这类「只读状态 + 一个出口」的信息都用它，
 * 这样状态始终在同一个位置，用户扫一眼就知道哪几项还没给。
 */
@Composable
fun StatusRow(
    title: String,
    status: String,
    modifier: Modifier = Modifier,
    statusOk: Boolean? = null,
    subtitle: String? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    showDivider: Boolean = false,
) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
            verticalAlignment = Alignment.Top,
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                if (subtitle != null) {
                    Text(
                        subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            // 状态做成右侧标签、动作跟在标签下面：原来状态单独占一行藏在说明下面，
            // 五项权限排下来要逐行读到第三行才知道哪几项没给。
            Column(
                horizontalAlignment = Alignment.End,
                modifier = Modifier.padding(start = DayCueSpacing.Small, top = 2.dp),
            ) {
                MiniTag(
                    text = status,
                    tone = when (statusOk) {
                        true -> MiniTagTone.Accent
                        false -> MiniTagTone.Warning
                        null -> MiniTagTone.Neutral
                    },
                )
                if (actionLabel != null && onAction != null) {
                    TextButton(
                        onClick = onAction,
                        modifier = Modifier.heightIn(min = MinTouchTarget),
                        contentPadding = PaddingValues(horizontal = DayCueSpacing.Medium),
                    ) {
                        Text(actionLabel, style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
        if (showDivider) RowDivider()
    }
}

// ---------------------------------------------------------------------------
// 按钮
// ---------------------------------------------------------------------------

/** 按钮样式。三档就够：主操作、次操作、文字操作。 */
enum class DayCueButtonStyle { Primary, Tonal, Outline, Text }

/**
 * 统一按钮。
 *
 * 所有样式的最小高度都是 48dp：Material 的 TextButton 默认只有 40dp，
 * 放在页脚那种位置单手很难点中。
 */
@Composable
fun DayCueButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    style: DayCueButtonStyle = DayCueButtonStyle.Primary,
    icon: ImageVector? = null,
    enabled: Boolean = true,
) {
    val colors = MaterialTheme.colorScheme
    val content: @Composable () -> Unit = {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (icon != null) {
                Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(DayCueSpacing.Small))
            }
            Text(text, style = MaterialTheme.typography.labelLarge)
        }
    }
    val base = modifier.defaultMinSize(minHeight = MinTouchTarget)
    when (style) {
        DayCueButtonStyle.Primary -> androidx.compose.material3.Button(
            onClick = onClick,
            modifier = base,
            enabled = enabled,
            shape = MaterialTheme.shapes.medium,
            contentPadding = PaddingValues(horizontal = DayCueSpacing.XLarge, vertical = DayCueSpacing.Medium),
            content = { content() },
        )
        DayCueButtonStyle.Tonal -> androidx.compose.material3.FilledTonalButton(
            onClick = onClick,
            modifier = base,
            enabled = enabled,
            shape = MaterialTheme.shapes.medium,
            contentPadding = PaddingValues(horizontal = DayCueSpacing.XLarge, vertical = DayCueSpacing.Medium),
            content = { content() },
        )
        DayCueButtonStyle.Outline -> androidx.compose.material3.OutlinedButton(
            onClick = onClick,
            modifier = base,
            enabled = enabled,
            shape = MaterialTheme.shapes.medium,
            contentPadding = PaddingValues(horizontal = DayCueSpacing.XLarge, vertical = DayCueSpacing.Medium),
            content = { content() },
        )
        DayCueButtonStyle.Text -> TextButton(
            onClick = onClick,
            modifier = base,
            enabled = enabled,
            content = { content() },
        )
    }
}

// ---------------------------------------------------------------------------
// 输入与筛选
// ---------------------------------------------------------------------------

/**
 * 搜索框。
 *
 * 用「填充式无边框」而不是全宽描边输入框：描边框在深色背景上会形成一整个亮框，
 * 把本页最该突出的记录列表压成背景。
 */
@Composable
fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "搜索",
    onSearch: (() -> Unit)? = null,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        singleLine = true,
        shape = MaterialTheme.shapes.medium,
        textStyle = MaterialTheme.typography.bodyMedium,
        placeholder = {
            Text(placeholder, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        },
        leadingIcon = {
            Icon(
                Icons.Outlined.Search,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        },
        trailingIcon = {
            if (value.isNotEmpty()) {
                IconButton(onClick = { onValueChange("") }) {
                    Icon(
                        Icons.Outlined.Close,
                        contentDescription = "清空",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        },
        keyboardOptions = KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSearch?.invoke() }),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            cursorColor = MaterialTheme.colorScheme.primary,
        ),
    )
}

/** 一行筛选标签。options 与 label 一一对应，避免用字符串当键以后国际化时对不上。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <T> FilterChipsRow(
    options: List<T>,
    selected: T,
    labelOf: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    // 横向可滚动：系统字号放大到 1.3 倍时，四个筛选标签的总宽度会超过屏宽，
    // 原来放在普通 Row 里会把最后一个标签压成一列竖排的单字。
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        options.forEach { option ->
            FilterChip(
                selected = option == selected,
                onClick = { onSelect(option) },
                label = {
                    Text(
                        text = labelOf(option),
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                        softWrap = false,
                    )
                },
                shape = MaterialTheme.shapes.extraSmall,
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = MaterialTheme.colorScheme.primary,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                    labelColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
                border = null,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/**
 * 行点击的统一样式来源。
 *
 * 单独抽出是因为「整行可点」与「只有右边按钮可点」在触控判定上差别很大，
 * 一旦每个页面自己写 clickable，就会出现有的行点不到左侧文字。
 */
private fun Modifier.clickableRow(enabled: Boolean = true, onClick: () -> Unit): Modifier =
    this.clickable(enabled = enabled, onClick = onClick)

// ---------------- 时间展示 ----------------
// 界面对时间的唯一出口。这里只做「转发 + 补默认时区」，
// 不允许出现任何 DateTimeFormatter、SimpleDateFormat 或字符串拼接：
// 一旦界面自己拼格式，「日期型截止日被补成 00:00」这类错误就会从领域层漏回来。

/** 记录里存的是 IANA 时区名，脏数据不应该让页面崩溃，所以解析失败退回设备时区。 */
fun zoneOf(name: String?): ZoneId {
    if (name.isNullOrBlank()) return ZoneId.systemDefault()
    return runCatching { ZoneId.of(name) }.getOrDefault(ZoneId.systemDefault())
}

fun formatDateTime(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
    DayCueTime.displayDateTime(instant, zone)

fun formatDate(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
    DayCueTime.displayDate(instant, zone)

/**
 * 任务的截止时间文案。
 *
 * date 型只显示日期：DayCueTime 已经保证 due_utc 为空，界面同样不许替它补一个时刻，
 * 否则「周五之前交」会显示成「周五 00:00」。
 */
fun formatTaskDue(task: TaskRecord): String {
    val zone = zoneOf(task.timezone)
    return when (task.dueKind) {
        DueKind.NONE -> "无截止时间"
        DueKind.DATE -> task.dueLocal
            ?.let { raw -> DayCueTime.parseLocalDateOrNull(raw)?.let { date -> DayCueTime.localDateString(date) } }
            ?: "截止日缺失"
        DueKind.DATETIME -> task.dueUtc
            ?.let { DayCueTime.displayDateTime(it, zone) }
            ?: "截止时刻缺失"
    }
}

/**
 * 今天页的截止/提醒文案。
 *
 * 与 formatTaskDue 的差别只有一处：当天到期时不再重复写日期。
 * 今天页上每一行都是今天的任务，每行都写「2026-10-26 22:00」只会让人读不出时间。
 * 跨天（例如列到明天的待办）仍然带上日期，否则会误读成今天。
 */
fun formatTaskScheduleToday(task: TaskRecord, now: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
    val due = when (task.dueKind) {
        DueKind.NONE -> "无截止时间"
        DueKind.DATE -> task.dueLocal
            ?.let { raw -> DayCueTime.parseLocalDateOrNull(raw)?.let { DayCueTime.localDateString(it) } }
            ?: "截止日缺失"
        DueKind.DATETIME -> task.dueUtc?.let { instant ->
            if (DayCueTime.isSameLocalDay(instant, now, zone)) {
                DayCueTime.displayClock(instant, zone) + " 截止"
            } else {
                DayCueTime.displayDateTime(instant, zone) + " 截止"
            }
        } ?: "截止时刻缺失"
    }
    val reminder = task.remindUtc?.let { instant ->
        if (DayCueTime.isSameLocalDay(instant, now, zone)) {
            DayCueTime.displayClock(instant, zone) + " 提醒"
        } else {
            DayCueTime.displayDateTime(instant, zone) + " 提醒"
        }
    } ?: "未设提醒"
    return due + " · " + reminder
}

/** 提醒时刻文案；没有提醒时刻时返回 null，由调用方决定要不要显示「未设提醒」。 */
fun formatTaskReminder(task: TaskRecord): String? =
    task.remindUtc?.let { DayCueTime.displayDateTime(it, zoneOf(task.timezone)) }

/**
 * 本地时刻文案。
 *
 * 这里刻意用 java.time 自带的 ISO 输出（08:00）而不是自己拼 HH:mm：
 * 课表字段本身就是 LocalTime，没有绝对时刻，DayCueTime 里也就没有对应的格式化入口。
 */
fun formatLocalTime(time: LocalTime): String = time.toString()
