package com.daycue.android.ui.today

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.WriteStateBadge
import com.daycue.android.ui.common.formatDate
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.common.formatTaskDue
import com.daycue.android.ui.common.formatTaskReminder
import com.daycue.android.ui.rememberContainer

/**
 * 今天页：把「现在该做什么」按优先级排出来。
 *
 * 五块内容的顺序是固定的：下一节课 → 今天到期的待办 → 待回复追问 → 同步异常 → 待处理记录。
 * 每一块都必须独立给出空态，因为「今天没课」和「课表还没导入」在用户眼里是两件事。
 */
@Composable
fun TodayScreen(
    onOpenTasks: () -> Unit,
    onOpenSchedule: () -> Unit,
    onOpenFollowUp: () -> Unit,
    onOpenCapture: () -> Unit,
    onOpenNote: (String) -> Unit,
) {
    val container = rememberContainer()
    val viewModel: TodayViewModel = viewModel(factory = TodayViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    DayCueScreen(
        title = "今天",
        actions = {
            TextButton(onClick = onOpenCapture) { Text("记一笔") }
            TextButton(onClick = { viewModel.refresh() }) { Text("刷新") }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            item {
                state.now?.let {
                    Text(
                        text = "现在 " + formatDateTime(it),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }

            state.notice?.let { notice ->
                item { MessageCard(text = notice, isError = true) }
            }

            // ---- 下一个行程 ----
            item {
                SectionHeader("下一个行程", trailing = { TextButton(onClick = onOpenSchedule) { Text("课表") } })
            }
            val course = state.nextCourse
            if (course == null) {
                item {
                    EmptyState(
                        title = "今天没有更多课程",
                        description = state.laterCourseHint?.let { "接下来的一次课：" + it } ?: "近期没有排课。如果课表还没导入，可以到课表页粘贴 ICS 或手工添加。",
                        actionLabel = "打开课表",
                        onAction = onOpenSchedule,
                    )
                }
            } else {
                item {
                    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Text(course.courseName, style = MaterialTheme.typography.titleSmall)
                        Text(
                            text = formatDateTime(course.startsAt) + " – " + formatDateTime(course.endsAt),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        val location = course.location
                        if (!location.isNullOrBlank()) {
                            Text("地点：" + location, style = MaterialTheme.typography.bodySmall)
                        }
                        Text(
                            text = "状态：" + course.status.displayName,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // ---- 临期待办 ----
            item {
                SectionHeader(
                    title = "今天到期的待办",
                    subtitle = "按截止时刻过滤，日期型截止日不会补成零点",
                    trailing = { TextButton(onClick = onOpenTasks) { Text("全部待办") } },
                )
            }
            if (state.dueTodayTasks.isEmpty()) {
                item {
                    EmptyState(
                        title = "今天没有到期的待办",
                        description = "还没有到期的任务会留在待办列表里，不会消失。",
                        actionLabel = "打开待办",
                        onAction = onOpenTasks,
                    )
                }
            } else {
                items(state.dueTodayTasks, key = { it.id }) { task ->
                    TodayTaskRow(task = task, onComplete = { viewModel.completeTask(task.id) })
                }
            }

            // ---- 待回复追问 ----
            item {
                SectionHeader(
                    title = "待回复的追问",
                    subtitle = "只有已经问过你、还没回复的才在这里",
                    trailing = { TextButton(onClick = onOpenFollowUp) { Text("去回复") } },
                )
            }
            if (state.pendingFollowUps.isEmpty()) {
                item {
                    EmptyState(
                        title = "没有待回复的追问",
                        description = "课后追问由课表生成；如果课程没开启追问，这里会一直是空的。",
                        actionLabel = "查看追问",
                        onAction = onOpenFollowUp,
                    )
                }
            } else {
                items(state.pendingFollowUps, key = { it.followUpId }) { item ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        Text(item.courseName, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = item.state.displayName + " · " + formatDateTime(item.at) + " · 第 " + (item.attempt + 1).toString() + " 次询问",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // ---- 同步异常 ----
            item {
                SectionHeader(
                    title = "同步异常",
                    subtitle = "外部写入状态不是「已完成」的都列在这里",
                )
            }
            if (state.syncIssues.isEmpty()) {
                item {
                    EmptyState(
                        title = "没有需要处理的同步问题",
                        description = if (state.outboxPending > 0) {
                            "还有 " + state.outboxPending.toString() + " 条操作在队列里等待执行。"
                        } else {
                            "外部写入没有异常，也没有等待执行的操作。"
                        },
                    )
                }
            } else {
                items(state.syncIssues, key = { it.id }) { task ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(task.title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            WriteStateBadge(state = task.externalWriteState)
                        }
                        Text(
                            text = "截止：" + formatTaskDue(task) + " · 提醒：" + (formatTaskReminder(task) ?: "未设置"),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // ---- 今天的笔记 ----
            item {
                SectionHeader(
                    title = "今天记下的内容",
                    subtitle = "按用户时区的当天统计",
                )
            }
            if (state.todayNotes.isEmpty()) {
                item {
                    EmptyState(
                        title = "今天还没有笔记",
                        description = "文字、录音或图片记录解析完成后的内容会落在笔记里。",
                        actionLabel = "去记录",
                        onAction = onOpenCapture,
                    )
                }
            } else {
                items(state.todayNotes, key = { it.id }) { note ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                    ) {
                        Text(
                            text = note.title,
                            style = MaterialTheme.typography.bodyLarge,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(
                            text = note.originKind.displayName + " · " + formatDate(note.occurredAt ?: note.createdAt),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        TextButton(onClick = { onOpenNote(note.id) }) { Text("查看详情") }
                    }
                }
            }

            // ---- 待处理记录 ----
            item {
                SectionHeader(
                    title = "待处理记录",
                    subtitle = "还没有解析完成或解析失败的记录",
                    trailing = { TextButton(onClick = onOpenCapture) { Text("新记录") } },
                )
            }
            if (state.pendingCaptures.isEmpty()) {
                item {
                    EmptyState(
                        title = "没有待处理的记录",
                        description = "所有记录都已经解析完成。",
                    )
                }
            } else {
                items(state.pendingCaptures, key = { it.captureId }) { capture ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        Text(capture.preview, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            text = capture.kindName + " · " + capture.status.displayName + " · " + formatDateTime(capture.recordedAt),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            item {
                Spacer(Modifier.height(24.dp))
                HorizontalDivider()
                Text(
                    text = "今天页只做汇总，不做任何写入：所有修改都发生在各自的详情页。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
        }
    }
}

/** 待办行：勾选即完成。取消本地闹钟由 ViewModel 负责，界面不直接碰提醒。 */
@Composable
private fun TodayTaskRow(task: TaskRecord, onComplete: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = false, onCheckedChange = { checked -> if (checked) onComplete() })
        Column(Modifier.weight(1f)) {
            Text(task.title, style = MaterialTheme.typography.bodyLarge)
            val reminder = formatTaskReminder(task)
            Text(
                text = "截止：" + formatTaskDue(task) + (if (reminder != null) " · 提醒：" + reminder else " · 未设提醒"),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
