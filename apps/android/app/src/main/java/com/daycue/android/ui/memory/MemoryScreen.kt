package com.daycue.android.ui.memory

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.rememberContainer

/**
 * 记忆页。
 *
 * 这一页的排版顺序就是它的产品立场：先放「需要你确认的推断」，再放已确认的事实，
 * 因为把推断混在事实里，用户就再也分不清哪句是自己说过的。
 */
@Composable
fun MemoryScreen() {
    val container = rememberContainer()
    val viewModel: MemoryViewModel = viewModel(factory = remember(container) { MemoryViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    DayCueScreen(title = "记忆") {
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item { MessageCard("这是 DayCue 对你的了解。带「推断」标记的条目只是系统的猜测，确认之后才会当作事实。") }

            state.error?.let { error ->
                item { MessageCard(error, isError = true) }
            }
            state.message?.let { message ->
                item { MessageCard(message) }
            }

            if (state.attention.isNotEmpty()) {
                item { SectionHeader(title = "需要你确认", subtitle = "系统推断出来、还没得到你确认的内容") }
                items(state.attention, key = { it.id }) { record ->
                    MemoryRow(
                        record = record,
                        onConfirm = { viewModel.confirm(record.id) },
                        onRetire = { viewModel.retire(record.id) },
                        onDelete = { viewModel.delete(record.id) },
                    )
                }
            }

            if (state.loaded && state.groups.isEmpty() && state.attention.isEmpty()) {
                item {
                    EmptyState(
                        title = "还没有任何记忆",
                        description = "当你在记录里写下自己的学习习惯、偏好或结论，它们会出现在这里，由你决定留不留。",
                    )
                }
            }

            for (group in state.groups) {
                item { SectionHeader(title = group.status.displayName, subtitle = groupDescription(group.status)) }
                items(group.items, key = { it.id }) { record ->
                    MemoryRow(
                        record = record,
                        onConfirm = { viewModel.confirm(record.id) },
                        onRetire = { viewModel.retire(record.id) },
                        onDelete = { viewModel.delete(record.id) },
                    )
                }
            }

            if (state.sourcePolicy.isNotEmpty()) {
                item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
                item { SectionHeader(title = "记忆来源", subtitle = "不同来源的可信度不一样，这里如实说明当前的处理方式") }
                items(state.sourcePolicy, key = { it.sourceKind.name }) { row ->
                    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Text(text = row.sourceKind.displayName, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = row.behavior,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

private fun groupDescription(status: MemoryStatus): String = when (status) {
    MemoryStatus.CANDIDATE -> "系统推断出来的，等你确认"
    MemoryStatus.CONFIRMED -> "已经确认，会作为事实参与回答"
    MemoryStatus.RETIRED -> "已经作废，只留档不再使用"
    MemoryStatus.CONFLICT -> "与已有记忆冲突，需要你决定以哪条为准"
}

@Composable
private fun MemoryRow(
    record: MemoryItemRecord,
    onConfirm: () -> Unit,
    onRetire: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (record.sourceKind == MemorySourceKind.INFERRED) {
                // 「推断」必须显示在主语之前：用户先看到来源，才知道后面这句话该不该信。
                Text(
                    text = "推断",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error,
                    fontWeight = FontWeight.Bold,
                )
                Text(text = "  ", style = MaterialTheme.typography.bodyMedium)
            } else {
                Text(
                    text = record.sourceKind.displayName,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Text(text = "  ", style = MaterialTheme.typography.bodyMedium)
            }
            Text(text = record.kind, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        Text(
            text = record.statement,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.padding(top = 4.dp),
        )

        val meta = buildList {
            add("记录于 " + formatDateTime(record.createdAt))
            record.reviewAt?.let { add("复核时间 " + formatDateTime(it)) }
            add("状态 " + record.status.displayName)
        }.joinToString(" · ")
        Text(
            text = meta,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 2.dp),
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
            if (record.status != MemoryStatus.CONFIRMED) {
                OutlinedButton(onClick = onConfirm) { Text("确认") }
            }
            if (record.status != MemoryStatus.RETIRED) {
                TextButton(onClick = onRetire) { Text("作废") }
            }
            TextButton(onClick = onDelete) { Text("删除") }
        }
    }
}
