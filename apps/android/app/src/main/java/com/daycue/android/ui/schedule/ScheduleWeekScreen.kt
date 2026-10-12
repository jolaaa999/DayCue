package com.daycue.android.ui.schedule

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.core.DayCueTime
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.schedule.weekdayDisplayName
import com.daycue.android.ui.DayCueRoutes
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.rememberContainer

/**
 * 周视图。
 *
 * 一周里的每一天都单独给出表头（含日期），即使那天没课也不隐藏：
 * 「周三没课」和「周三的课被停掉了」对用户是完全不同的两件事，
 * 所以停课/调课的实例仍要显示，只是把状态标出来。
 */
@Composable
fun ScheduleWeekScreen(
    onBack: () -> Unit,
    onEditCourse: (String) -> Unit,
    onImportIcs: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: ScheduleViewModel = viewModel(factory = ScheduleViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    var showTermDialog by remember { mutableStateOf(false) }
    var rescheduleTarget by remember { mutableStateOf<WeekEntry?>(null) }
    var deleteTarget by remember { mutableStateOf<String?>(null) }

    DayCueScreen(
        title = "课表",
        onBack = onBack,
        actions = {
            TextButton(onClick = { showTermDialog = true }) { Text("学期") }
            TextButton(onClick = onImportIcs) { Text("导入 ICS") }
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
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedButton(onClick = { viewModel.shiftWeek(-1) }) { Text("上一周") }
                    OutlinedButton(onClick = { viewModel.goToCurrentWeek() }) { Text("本周") }
                    OutlinedButton(onClick = { viewModel.shiftWeek(1) }) { Text("下一周") }
                }
            }

            item {
                val monday = state.monday
                Text(
                    text = if (monday == null) {
                        "正在读取周次…"
                    } else {
                        val range = DayCueTime.localDateString(monday) + " – " + DayCueTime.localDateString(monday.plusDays(6))
                        val week = state.weekIndex
                        if (week == null) "不在学期范围内 · " + range else "第 " + week.toString() + " 周 · " + range
                    },
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(vertical = 6.dp),
                )
                val term = state.term
                Text(
                    text = if (term == null) {
                        "还没有设置学期基准：单双周与「第几周」都换算不出实际日期，请先点右上角「学期」。"
                    } else {
                        "学期基准：第 1 周周一 " + DayCueTime.localDateString(term.firstWeekMonday) + "，共 " + term.totalWeeks.toString() + " 周"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            state.error?.let { error -> item { MessageCard(text = error, isError = true) } }
            state.notice?.let { notice -> item { MessageCard(text = notice) } }

            item {
                SectionHeader(title = "本周课程", subtitle = "节次来自课程规则，停课与调课只改这一次课")
            }

            if (state.entries.isEmpty()) {
                item {
                    EmptyState(
                        title = "这一周没有课",
                        description = if (state.courses.isEmpty()) {
                            "还没有任何课程。可以粘贴 ICS，或手工新增一门课再添加每周规则。"
                        } else {
                            "已经有的课程都不在这一周。课程实例只会在学期基准范围内、且周次命中规则时生成。"
                        },
                    )
                }
            } else {
                for (weekday in 1..7) {
                    val dayEntries = state.entries.filter { it.weekday == weekday }.sortedBy { it.startsAt }
                    val monday = state.monday
                    val dayLabel = weekdayDisplayName(weekday) +
                        (monday?.let { " · " + DayCueTime.localDateString(it.plusDays((weekday - 1).toLong())) } ?: "")
                    item(key = "day-" + weekday.toString()) {
                        Text(
                            text = dayLabel + if (dayEntries.isEmpty()) "（没课）" else "",
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.padding(top = 10.dp, bottom = 2.dp),
                        )
                    }
                    items(dayEntries, key = { it.instanceId }) { entry ->
                        WeekEntryCard(
                            entry = entry,
                            onEditCourse = { onEditCourse(entry.courseId) },
                            onToggleCancelled = {
                                if (entry.status == CourseInstanceStatus.CANCELLED) {
                                    viewModel.markScheduled(entry.instanceId)
                                } else {
                                    viewModel.markCancelled(entry.instanceId)
                                }
                            },
                            onReschedule = { rescheduleTarget = entry },
                        )
                    }
                }
            }

            item {
                SectionHeader(
                    title = "课程",
                    subtitle = "删除是软删除；追问设置按月/按次策略影响课后打扰",
                    trailing = {
                        TextButton(onClick = { onEditCourse(DayCueRoutes.COURSE_ID_NEW) }) { Text("新增") }
                    },
                )
            }

            if (state.courses.isEmpty()) {
                item {
                    EmptyState(
                        title = "还没有课程",
                        description = "课程是课表的源头：先建课程，再加每周规则，最后展开成实例。",
                        actionLabel = "新增课程",
                        onAction = { onEditCourse(DayCueRoutes.COURSE_ID_NEW) },
                    )
                }
            } else {
                items(state.courses, key = { it.id }) { course ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                        Text(course.name, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = buildString {
                                append(if (course.followUpEnabled) "课后追问：开启" else "课后追问：关闭")
                                append(" · 延迟 ").append(course.followUpDelayMinutes.toString()).append(" 分钟")
                                append(" · ").append(course.followUpMode.displayName)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        course.teacher?.takeIf { it.isNotBlank() }?.let { teacher ->
                            Text("教师：" + teacher, style = MaterialTheme.typography.bodySmall)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(onClick = { onEditCourse(course.id) }) { Text("编辑") }
                            TextButton(onClick = { viewModel.regenerate(course.id) }) { Text("展开课表") }
                            TextButton(onClick = { deleteTarget = course.id }) { Text("删除") }
                        }
                        HorizontalDivider()
                    }
                }
            }

            item { Spacer(Modifier.height(32.dp)) }
        }

        if (showTermDialog) {
            TermDialog(
                initialFirstMonday = state.term?.let { DayCueTime.localDateString(it.firstWeekMonday) } ?: "",
                initialWeeks = state.term?.totalWeeks?.toString() ?: "30",
                onDismiss = { showTermDialog = false },
                onConfirm = { firstMonday, weeks ->
                    showTermDialog = false
                    viewModel.saveTerm(firstMonday, weeks)
                },
            )
        }

        rescheduleTarget?.let { target ->
            RescheduleDialog(
                entry = target,
                onDismiss = { rescheduleTarget = null },
                onConfirm = { date, start, end, note ->
                    rescheduleTarget = null
                    viewModel.reschedule(target.instanceId, target.timezone, date, start, end, note)
                },
            )
        }

        deleteTarget?.let { courseId ->
            AlertDialog(
                onDismissRequest = { deleteTarget = null },
                title = { Text("删除这门课程？") },
                text = { Text("删除后它的课程实例不会再出现在周视图里。这是软删除，数据仍保留在本机数据库中，外部对账期间不做物理删除。") },
                confirmButton = {
                    TextButton(onClick = {
                        deleteTarget = null
                        viewModel.deleteCourse(courseId)
                    }) { Text("删除") }
                },
                dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("取消") } },
            )
        }
    }
}

@Composable
private fun WeekEntryCard(
    entry: WeekEntry,
    onEditCourse: () -> Unit,
    onToggleCancelled: () -> Unit,
    onReschedule: () -> Unit,
) {
    val cancelled = entry.status == CourseInstanceStatus.CANCELLED
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(entry.courseName, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            Text(
                text = entry.status.displayName,
                style = MaterialTheme.typography.labelSmall,
                color = if (cancelled) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = formatDateTime(entry.startsAt) + " – " + formatDateTime(entry.endsAt) + " · " + entry.sectionText,
            style = MaterialTheme.typography.bodyMedium,
        )
        val location = entry.location
        if (!location.isNullOrBlank()) {
            Text("地点：" + location, style = MaterialTheme.typography.bodySmall)
        }
        Text(
            text = "来源：" + entry.originName,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = onToggleCancelled) { Text(if (cancelled) "恢复" else "停课") }
            TextButton(onClick = onReschedule) { Text("调课") }
            TextButton(onClick = onEditCourse) { Text("课程设置") }
        }
        HorizontalDivider()
    }
}

/** 学期基准：没有它，单双周与「第几周」都无法换算成实际日期。 */
@Composable
private fun TermDialog(
    initialFirstMonday: String,
    initialWeeks: String,
    onDismiss: () -> Unit,
    onConfirm: (String, String) -> Unit,
) {
    var firstMonday by remember { mutableStateOf(initialFirstMonday) }
    var weeks by remember { mutableStateOf(initialWeeks) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("学期基准") },
        text = {
            Column {
                OutlinedTextField(
                    value = firstMonday,
                    onValueChange = { firstMonday = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("第 1 周周一（2026-09-01）") },
                )
                OutlinedTextField(
                    value = weeks,
                    onValueChange = { weeks = it },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("学期总周数（1–60）") },
                )
                Text(
                    text = "课表展开、单双周判断与 ICS 导入的周次换算都以这里为基准。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = { Button(onClick = { onConfirm(firstMonday, weeks) }) { Text("保存") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

/** 调课：只改这一次课的时间，规则不动；结束早于开始时顺延到次日。 */
@Composable
private fun RescheduleDialog(
    entry: WeekEntry,
    onDismiss: () -> Unit,
    onConfirm: (String, String, String, String) -> Unit,
) {
    var date by remember { mutableStateOf("") }
    var start by remember { mutableStateOf("") }
    var end by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("调课：" + entry.courseName) },
        text = {
            Column {
                Text(
                    text = "原时间：" + formatDateTime(entry.startsAt) + " – " + formatDateTime(entry.endsAt),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = date,
                    onValueChange = { date = it },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("新日期（2026-10-16）") },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = start,
                        onValueChange = { start = it },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        label = { Text("开始（20:00）") },
                    )
                    OutlinedTextField(
                        value = end,
                        onValueChange = { end = it },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        label = { Text("结束（21:40）") },
                    )
                }
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("备注（可选）") },
                )
            }
        },
        confirmButton = { Button(onClick = { onConfirm(date, start, end, note) }) { Text("保存调课") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
