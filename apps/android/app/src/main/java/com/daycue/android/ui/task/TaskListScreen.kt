package com.daycue.android.ui.task

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.TaskStatus
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.WriteStateBadge
import com.daycue.android.ui.common.formatTaskDue
import com.daycue.android.ui.common.formatTaskReminder
import com.daycue.android.ui.rememberContainer

/**
 * App 内待办列表。
 *
 * Android 端不假定任何系统级待办 API，这里就是主库；
 * 「写入外部」只是可选的投影，所以列表上必须显示外部写入状态，避免用户以为已经同步。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskListScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val viewModel: TaskViewModel = viewModel(factory = TaskViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    DayCueScreen(
        title = "待办",
        onBack = onBack,
        actions = { TextButton(onClick = { viewModel.openDialog() }) { Text("新建") } },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TaskStatus.entries.forEach { status ->
                    FilterChip(
                        selected = state.filter == status,
                        onClick = { viewModel.setFilter(status) },
                        label = { Text(status.displayName) },
                    )
                }
            }

            state.error?.let { error ->
                MessageCard(text = error, isError = true, modifier = Modifier.padding(horizontal = 16.dp))
            }
            state.notice?.let { notice ->
                MessageCard(text = notice, modifier = Modifier.padding(horizontal = 16.dp))
            }

            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (state.tasks.isEmpty()) {
                    item {
                        when (state.filter) {
                            TaskStatus.OPEN -> EmptyState(
                                title = "没有待办",
                                description = "从记录里解析出的行动意图、或者你手动新建的任务都会出现在这里。",
                                actionLabel = "新建任务",
                                onAction = { viewModel.openDialog() },
                            )

                            TaskStatus.DONE -> EmptyState(
                                title = "还没有已完成的任务",
                                description = "在「待办」里勾选完成，任务就会挪到这里。",
                            )

                            TaskStatus.CANCELLED -> EmptyState(
                                title = "还没有已取消的任务",
                                description = "不再需要的任务可以取消，取消后记录仍然保留，不会被物理删除。",
                            )
                        }
                    }
                } else {
                    items(state.tasks, key = { it.id }) { task ->
                        TaskRow(
                            title = task.title,
                            detail = task.detail,
                            dueText = formatTaskDue(task),
                            reminderText = formatTaskReminder(task),
                            status = task.status,
                            writeStateName = task.externalWriteState.displayName,
                            writeNeedsAttention = task.externalWriteState.needsAttention,
                            onComplete = { viewModel.complete(task.id) },
                            onReopen = { viewModel.reopen(task.id) },
                            onCancel = { viewModel.cancel(task.id) },
                            onDelete = { viewModel.delete(task.id) },
                        )
                    }
                }
            }
        }

        if (state.dialogOpen) {
            NewTaskDialog(
                draft = state.draft,
                error = state.error,
                onDraftChange = { transform -> viewModel.updateDraft(transform) },
                onDismiss = { viewModel.closeDialog() },
                onConfirm = { viewModel.createTask() },
            )
        }
    }
}

@Composable
private fun TaskRow(
    title: String,
    detail: String?,
    dueText: String,
    reminderText: String?,
    status: TaskStatus,
    writeStateName: String,
    writeNeedsAttention: Boolean,
    onComplete: () -> Unit,
    onReopen: () -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            WriteStateBadge(
                state = if (writeNeedsAttention) {
                    com.daycue.android.domain.model.ExternalWriteState.WAITING_FOR_PERMISSION
                } else {
                    com.daycue.android.domain.model.ExternalWriteState.WRITTEN
                },
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        if (!detail.isNullOrBlank()) {
            Text(detail, style = MaterialTheme.typography.bodyMedium)
        }
        Text(
            text = "截止：" + dueText + " · 提醒：" + (reminderText ?: "未设置") + " · " + status.displayName,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = "外部写入：" + writeStateName,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            when (status) {
                TaskStatus.OPEN -> {
                    TextButton(onClick = onComplete) { Text("完成") }
                    TextButton(onClick = onCancel) { Text("取消") }
                }

                TaskStatus.DONE -> TextButton(onClick = onReopen) { Text("重新打开") }
                TaskStatus.CANCELLED -> TextButton(onClick = onReopen) { Text("恢复为待办") }
            }
            TextButton(onClick = onDelete) { Text("删除") }
        }
        HorizontalDivider()
    }
}

/** 新建任务对话框。日期型与时间型分开输入，提醒是可选项而不是默认补出来的时刻。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewTaskDialog(
    draft: NewTaskDraft,
    error: String?,
    onDraftChange: ((NewTaskDraft) -> NewTaskDraft) -> Unit,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("新建待办") },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                OutlinedTextField(
                    value = draft.title,
                    onValueChange = { value -> onDraftChange { it.copy(title = value) } },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("标题") },
                )
                OutlinedTextField(
                    value = draft.detail,
                    onValueChange = { value -> onDraftChange { it.copy(detail = value) } },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    minLines = 2,
                    label = { Text("备注（可选）") },
                )

                Text("截止时间形态", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = draft.dueKind == DueKind.NONE,
                        onClick = { onDraftChange { it.copy(dueKind = DueKind.NONE, dueDate = "", dueTime = "") } },
                        label = { Text("无截止") },
                    )
                    FilterChip(
                        selected = draft.dueKind == DueKind.DATE,
                        onClick = { onDraftChange { it.copy(dueKind = DueKind.DATE, dueTime = "") } },
                        label = { Text("日期") },
                    )
                    FilterChip(
                        selected = draft.dueKind == DueKind.DATETIME,
                        onClick = { onDraftChange { it.copy(dueKind = DueKind.DATETIME) } },
                        label = { Text("时刻") },
                    )
                }

                if (draft.dueKind == DueKind.DATE) {
                    OutlinedTextField(
                        value = draft.dueDate,
                        onValueChange = { value -> onDraftChange { it.copy(dueDate = value) } },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        singleLine = true,
                        label = { Text("截止日（2026-10-16）") },
                    )
                    Text(
                        text = "日期型只保存日期，不会补一个 00:00 的提醒时刻。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                if (draft.dueKind == DueKind.DATETIME) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = draft.dueDate,
                            onValueChange = { value -> onDraftChange { it.copy(dueDate = value) } },
                            modifier = Modifier.weight(1f).padding(top = 8.dp),
                            singleLine = true,
                            label = { Text("日期") },
                        )
                        OutlinedTextField(
                            value = draft.dueTime,
                            onValueChange = { value -> onDraftChange { it.copy(dueTime = value) } },
                            modifier = Modifier.weight(1f).padding(top = 8.dp),
                            singleLine = true,
                            label = { Text("时刻") },
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("设置提醒", modifier = Modifier.weight(1f))
                    Switch(
                        checked = draft.remindEnabled,
                        onCheckedChange = { checked ->
                            onDraftChange { it.copy(remindEnabled = checked) }
                        },
                    )
                }

                if (draft.remindEnabled) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = draft.remindDate,
                            onValueChange = { value -> onDraftChange { it.copy(remindDate = value) } },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            label = { Text("提醒日期") },
                        )
                        OutlinedTextField(
                            value = draft.remindTime,
                            onValueChange = { value -> onDraftChange { it.copy(remindTime = value) } },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            label = { Text("提醒时刻") },
                        )
                    }
                    Text(
                        text = "提醒时刻是绝对时刻，与截止时间各自独立；如果系统没有授予精确闹钟权限，提醒可能延迟几分钟。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                OutlinedTextField(
                    value = draft.courseHint,
                    onValueChange = { value -> onDraftChange { it.copy(courseHint = value) } },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("关联课程（可选）") },
                )

                error?.let { message -> MessageCard(text = message, isError = true) }

                Text(
                    text = "Android 端不写入系统日历或系统待办：任务只保存在 App 内。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = { Button(onClick = onConfirm) { Text("创建") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
