package com.daycue.android.ui.note

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.KeyValueLine
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.WriteStateBadge
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.common.formatTaskDue
import com.daycue.android.ui.rememberContainer

/**
 * 记录详情：编辑、软删除、溯源。
 *
 * 来源区是这一页的重点：「这条笔记从哪来」决定了它可不可信，
 * 所以 originKind 与来源记录的原文都必须显示出来，而不是只显示笔记本身。
 */
@Composable
fun NoteDetailScreen(
    noteId: String,
    onBack: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: NoteDetailViewModel = viewModel(
        factory = NoteDetailViewModel.factory(container, noteId),
    )
    val state by viewModel.state.collectAsState()
    var confirmDelete by remember { mutableStateOf(false) }

    DayCueScreen(
        title = "记录详情",
        onBack = onBack,
        actions = {
            TextButton(onClick = { viewModel.save() }, enabled = state.dirty && !state.busy) { Text("保存") }
        },
    ) { padding ->
        val note = state.note
        if (note == null && !state.loading) {
            Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
                state.notice?.let { MessageCard(text = it) }
                EmptyState(
                    title = if (state.deleted) "这条记录已删除" else "找不到这条记录",
                    description = if (state.deleted) {
                        "删除是软删除：内容仍在本机数据库里，时间线之外的页面不再显示它。"
                    } else {
                        "它可能已经被删除，或者数据库里没有这个 id。"
                    },
                    actionLabel = "返回",
                    onAction = onBack,
                )
            }
            return@DayCueScreen
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            state.error?.let { MessageCard(text = it, isError = true) }
            state.notice?.let { MessageCard(text = it) }

            OutlinedTextField(
                value = state.titleDraft,
                onValueChange = { viewModel.onTitleChange(it) },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                singleLine = true,
                label = { Text("标题") },
            )
            OutlinedTextField(
                value = state.bodyDraft,
                onValueChange = { viewModel.onBodyChange(it) },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                minLines = 5,
                label = { Text("正文") },
            )

            Row(
                modifier = Modifier.padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(
                    onClick = { viewModel.save() },
                    enabled = state.dirty && !state.busy,
                ) { Text(if (state.dirty) "保存修订" else "没有改动") }
                OutlinedButton(onClick = { confirmDelete = true }, enabled = !state.busy) { Text("删除") }
            }

            SectionHeader(title = "来源")
            KeyValueLine("来源类型", note?.originKind?.displayName ?: "未知")
            KeyValueLine("是否由你修订", if (note?.userEdited == true) "是（识别结果不会覆盖）" else "否")
            KeyValueLine("发生时间", note?.occurredAt?.let { formatDateTime(it) } ?: "未记录")
            KeyValueLine("创建时间", note?.createdAt?.let { formatDateTime(it) } ?: "未知")
            note?.courseHint?.takeIf { it.isNotBlank() }?.let { KeyValueLine("关联课程", it) }
            val sourceKind = state.sourceCaptureKind
            if (sourceKind != null) {
                KeyValueLine("来源记录类型", sourceKind)
                Text(
                    text = state.sourceCaptureText ?: "来源记录没有文本内容（录音或图片尚未补充文字）。",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 4.dp),
                )
            } else {
                Text(
                    text = "这条笔记没有关联的记录来源。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }

            SectionHeader(title = "同一来源的待办", subtitle = "任务与笔记分开存，这里只做展示，不改状态")
            if (state.relatedTasks.isEmpty()) {
                EmptyState(
                    title = "没有关联的待办",
                    description = "笔记默认不提醒；只有明确写出的行动意图才会生成待办。",
                )
            } else {
                state.relatedTasks.forEach { task ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        Row {
                            Text(task.title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            WriteStateBadge(state = task.externalWriteState)
                        }
                        Text(
                            text = "截止：" + formatTaskDue(task) + " · " + task.status.displayName,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            SectionHeader(title = "同一来源的其他笔记")
            if (state.relatedNotes.isEmpty()) {
                EmptyState(
                    title = "没有其他笔记",
                    description = "一次记录可能只产出一条笔记。",
                )
            } else {
                state.relatedNotes.forEach { other ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        Text(other.title, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            text = formatDateTime(other.occurredAt ?: other.createdAt),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        HorizontalDivider()
                    }
                }
            }

            Spacer(Modifier.height(32.dp))
        }

        if (confirmDelete) {
            AlertDialog(
                onDismissRequest = { confirmDelete = false },
                title = { Text("删除这条记录？") },
                text = { Text("删除后它不会再出现在列表里；内容仍以软删除的形式保留在本机数据库中，外部同步期间不做物理删除。") },
                confirmButton = {
                    TextButton(onClick = {
                        confirmDelete = false
                        viewModel.delete()
                    }) { Text("删除") }
                },
                dismissButton = {
                    TextButton(onClick = { confirmDelete = false }) { Text("取消") }
                },
            )
        }
    }
}
