package com.daycue.android.ui.memory

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import java.time.ZoneId
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueIcons
import com.daycue.android.ui.common.EmptyStateGlyph
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.MiniTag
import com.daycue.android.ui.common.MiniTagTone
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.RowDivider
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.formatDate
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinTouchTarget

/**
 * 记忆页。
 *
 * 排版顺序就是这一页的产品立场：先放**待确认**（系统推断出来的），再放已确认的事实。
 * 把推断混进事实里，用户就再也分不清哪句是自己说过的、哪句是 App 猜的。
 *
 * 「记忆来源原理」不再长期占据主页面：它是解释性内容，进帮助弹窗看即可。
 */
@Composable
fun MemoryScreen(onOpenCapture: () -> Unit) {
    val container = rememberContainer()
    val viewModel: MemoryViewModel = viewModel(factory = remember(container) { MemoryViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    MemoryContent(
        state = state,
        onConfirm = viewModel::confirm,
        onRetire = viewModel::retire,
        onDelete = viewModel::delete,
        onOpenCapture = onOpenCapture,
    )
}

@Composable
fun MemoryContent(
    state: MemoryUiState,
    onConfirm: (String) -> Unit,
    onRetire: (String) -> Unit,
    onDelete: (String) -> Unit,
    onOpenCapture: () -> Unit,
) {
    var showHelp by remember { mutableStateOf(false) }
    var showRetired by remember { mutableStateOf(false) }

    // 待复核的条目单独置顶；它们同时也是 CANDIDATE 分组里的成员，
    // 所以分组里要排除掉，否则同一条记忆会出现两次（上一版就有这个重复）。
    val reviewDueIds = state.attention.map { it.id }.toSet()
    val pending = state.groups.firstOrNull { it.status == MemoryStatus.CANDIDATE }?.items.orEmpty()
    val reviewDue = pending.filter { it.id in reviewDueIds }
    val pendingRest = pending.filter { it.id !in reviewDueIds }
    val conflicts = state.groups.firstOrNull { it.status == MemoryStatus.CONFLICT }?.items.orEmpty()
    val confirmed = state.groups.firstOrNull { it.status == MemoryStatus.CONFIRMED }?.items.orEmpty()
    val retired = state.groups.firstOrNull { it.status == MemoryStatus.RETIRED }?.items.orEmpty()
    val nothing = state.loaded && state.groups.isEmpty()

    DayCueScreen(
        title = "记忆",
        actions = {
            IconButton(onClick = { showHelp = true }) {
                Icon(
                    imageVector = Icons.Outlined.Info,
                    contentDescription = "记忆是怎么来的",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(
                start = DayCueSpacing.Screen,
                end = DayCueSpacing.Screen,
                top = DayCueSpacing.Small,
                bottom = DayCueSpacing.XXLarge,
            ),
        ) {
            state.error?.let { error -> item { MessageCard(text = error, isError = true) } }
            state.message?.let { message -> item { MessageCard(text = message) } }

            if (nothing) {
                item {
                    // 空态居中并限宽：这一页空着时只有「一句解释 + 一个动作」，
                    // 顶在页面上方既留死白，也让那句解释横向拉满整屏、读起来很散。
                    Column(
                        modifier = Modifier.fillParentMaxHeight(0.78f).fillMaxWidth(),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        EmptyStateGlyph(DayCueIcons.Bookmark)
                        Spacer(Modifier.height(DayCueSpacing.Medium))
                        Text("还没有记忆", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(DayCueSpacing.XSmall + 2.dp))
                        Text(
                            text = "你写下自己的习惯、偏好或结论之后，App 会把它们整理到这里，留不留由你决定。",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.widthIn(max = 280.dp),
                        )
                        Spacer(Modifier.height(DayCueSpacing.XLarge))
                        DayCueButton(text = "去记一笔", onClick = onOpenCapture)
                    }
                }
            }

            if (reviewDue.isNotEmpty()) {
                item {
                    SectionHeader(title = "需要你看一眼", subtitle = "到了该复核的时间，确认或作废")
                    MemoryGroup(
                        records = reviewDue,
                        highlighted = true,
                        now = state.now,
                        onConfirm = onConfirm,
                        onRetire = onRetire,
                        onDelete = onDelete,
                    )
                }
            }

            if (pendingRest.isNotEmpty()) {
                item {
                    SectionHeader(
                        title = "待确认",
                        subtitle = "App 推断出来的，只有你确认之后才会被当作事实使用",
                    )
                    MemoryGroup(
                        records = pendingRest,
                        highlighted = false,
                        now = state.now,
                        onConfirm = onConfirm,
                        onRetire = onRetire,
                        onDelete = onDelete,
                    )
                }
            }

            if (conflicts.isNotEmpty()) {
                item {
                    SectionHeader(title = "存在冲突", subtitle = "和已有记忆矛盾，需要你决定留哪条")
                    MemoryGroup(
                        records = conflicts,
                        highlighted = true,
                        now = state.now,
                        onConfirm = onConfirm,
                        onRetire = onRetire,
                        onDelete = onDelete,
                    )
                }
            }

            if (confirmed.isNotEmpty()) {
                item {
                    SectionHeader(title = "已确认", subtitle = "你确认过，会作为事实参与回答")
                    MemoryGroup(
                        records = confirmed,
                        highlighted = false,
                        now = state.now,
                        onConfirm = onConfirm,
                        onRetire = onRetire,
                        onDelete = onDelete,
                    )
                }
            }

            if (retired.isNotEmpty()) {
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = MinTouchTarget),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "已失效 " + retired.size.toString() + " 条",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(
                            onClick = { showRetired = !showRetired },
                            modifier = Modifier.heightIn(min = MinTouchTarget),
                        ) {
                            Text(if (showRetired) "收起" else "展开")
                        }
                    }
                }
                // 已失效的默认折叠：它们不再参与回答，长期铺开只会把有用的内容顶下去。
                if (showRetired) {
                    item {
                        MemoryGroup(
                            records = retired,
                            highlighted = false,
                            now = state.now,
                            onConfirm = onConfirm,
                            onRetire = onRetire,
                            onDelete = onDelete,
                        )
                    }
                }
            }
        }
    }

    if (showHelp) {
        MemorySourceHelpDialog(
            rows = state.sourcePolicy,
            onDismiss = { showHelp = false },
        )
    }
}

/**
 * 一组记忆。
 *
 * 每条记忆单独一张卡片会让一屏里出现十几张卡片，反而看不出分组；
 * 这里按「同一状态一组容器 + 行间细线」排，分组标题仍然负责说清这一组的含义。
 */
@Composable
private fun MemoryGroup(
    records: List<MemoryItemRecord>,
    highlighted: Boolean,
    now: Instant?,
    onConfirm: (String) -> Unit,
    onRetire: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    SettingGroup {
        records.forEachIndexed { index, record ->
            MemoryRow(
                record = record,
                highlighted = highlighted,
                now = now,
                onConfirm = { onConfirm(record.id) },
                onRetire = { onRetire(record.id) },
                onDelete = { onDelete(record.id) },
                showDivider = index < records.lastIndex,
            )
        }
    }
}

/**
 * 记忆行。
 *
 * 来源必须在陈述之前：用户先看到「这是 App 推断的」，才知道后面那句话该不该信。
 * 更新时间、复核时间这类信息压到第二行的小字里，不占正文空间。
 */
@Composable
private fun MemoryRow(
    record: MemoryItemRecord,
    highlighted: Boolean,
    now: Instant?,
    onConfirm: () -> Unit,
    onRetire: () -> Unit,
    onDelete: () -> Unit,
    showDivider: Boolean = false,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (record.sourceKind == MemorySourceKind.INFERRED) {
                    MiniTag(text = "推断", tone = MiniTagTone.Neutral)
                } else {
                    MiniTag(text = record.sourceKind.displayName, tone = MiniTagTone.Accent)
                }
                if (highlighted) {
                    Spacer(Modifier.width(DayCueSpacing.XSmall))
                    MiniTag(text = "待复核", tone = MiniTagTone.Accent)
                }
                Spacer(Modifier.weight(1f))
                Text(
                    // 只到日：记忆是「什么时候记下的」，精确到分钟没有意义。
                    text = if (now == null) {
                        formatDate(record.createdAt)
                    } else {
                        DayCueTime.displayMonthDay(record.createdAt, now, ZoneId.systemDefault())
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(DayCueSpacing.XSmall))
            Text(record.statement, style = MaterialTheme.typography.bodyLarge)

            // 三个操作挤在一条紧凑的行里：默认 TextButton 的左右内边距会把每个按钮撑到 100dp 以上，
            // 一行三个就成了一条横贯整页的按钮带，比上面的正文还显眼。
            Row(
                horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.XSmall),
                modifier = Modifier.padding(top = DayCueSpacing.XSmall),
            ) {
                val compact = Modifier.heightIn(min = MinTouchTarget)
                val compactPadding = PaddingValues(horizontal = DayCueSpacing.Medium)
                if (record.status != MemoryStatus.CONFIRMED) {
                    // 主操作给主色：这一组里真正想让用户做的是「确认」，
                    // 三个按钮同色时用户得先读完三个词才知道该点哪个。
                    TextButton(onClick = onConfirm, modifier = compact, contentPadding = compactPadding) {
                        Text(
                            text = "确认为事实",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
                if (record.status != MemoryStatus.RETIRED) {
                    TextButton(onClick = onRetire, modifier = compact, contentPadding = compactPadding) {
                        Text("作废", style = MaterialTheme.typography.labelMedium)
                    }
                }
                TextButton(onClick = onDelete, modifier = compact, contentPadding = compactPadding) {
                    Text(
                        text = "删除",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
        if (showDivider) RowDivider()
    }
}

/**
 * 帮助弹窗：记忆是怎么来的。
 *
 * 放在这里而不是主页面，是因为它是「第一次想知道」的内容：
 * 长期占据列表上方，每次进页面都要重新读一遍三段解释。
 */
@Composable
private fun MemorySourceHelpDialog(rows: List<MemorySourceRow>, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("记忆是怎么来的") },
        text = {
            Column {
                Text(
                    text = "不同来源的可信度不一样，下面是我们现在的实际处理方式。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                rows.forEach { row ->
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    Text(row.sourceKind.displayName, style = MaterialTheme.typography.titleSmall)
                    Text(
                        text = row.behavior,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = MinTouchTarget)) {
                Text("知道了")
            }
        },
    )
}
