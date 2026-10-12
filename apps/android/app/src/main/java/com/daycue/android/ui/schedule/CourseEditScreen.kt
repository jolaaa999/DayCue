package com.daycue.android.ui.schedule

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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.WeekParity
import com.daycue.android.domain.schedule.weekdayDisplayName
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.formatLocalTime
import com.daycue.android.ui.rememberContainer

/**
 * 课程设置。
 *
 * 一页里承担两件事：课程的增删，以及「每周规则 + 课后追问策略」。
 * 追问的延迟被限制在 5–15 分钟（仓储也会再夹一次），因为「课后立刻问」会撞上下课路上，
 * 「隔太久才问」用户已经忘了课上发生了什么，这两个边界是产品约束而不是随意取值。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CourseEditScreen(
    courseId: String,
    onBack: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: CourseEditViewModel = viewModel(
        factory = CourseEditViewModel.factory(container, courseId),
    )
    val state by viewModel.state.collectAsState()
    var confirmDelete by remember { mutableStateOf(false) }

    DayCueScreen(
        title = if (state.isNew) "新增课程" else "课程设置",
        onBack = onBack,
        actions = {
            if (!state.isNew) {
                TextButton(onClick = { viewModel.saveFollowUpSettings() }) { Text("保存追问") }
            }
        },
    ) { padding ->
        if (state.deleted) {
            Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
                state.notice?.let { MessageCard(text = it) }
                EmptyState(
                    title = "这门课程已删除",
                    description = "它的课程实例不会再出现在周视图里；数据是软删除，仍保留在本机数据库中。",
                    actionLabel = "返回课表",
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

            SectionHeader(
                title = if (state.isNew) "新建课程" else "课程信息",
                subtitle = if (state.isNew) "课程名是必填项；创建之后才能添加每周规则" else "课程信息创建后不再修改，如需改名请新建一门课",
            )
            if (state.isNew) {
                OutlinedTextField(
                    value = state.name,
                    onValueChange = { value -> viewModel.update { it.copy(name = value) } },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("课程名") },
                )
                OutlinedTextField(
                    value = state.teacher,
                    onValueChange = { value -> viewModel.update { it.copy(teacher = value) } },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("教师（可选）") },
                )
                OutlinedTextField(
                    value = state.location,
                    onValueChange = { value -> viewModel.update { it.copy(location = value) } },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("地点（可选）") },
                )
                OutlinedTextField(
                    value = state.termName,
                    onValueChange = { value -> viewModel.update { it.copy(termName = value) } },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("学期标识（可选）") },
                )
                Button(
                    onClick = { viewModel.createCourse() },
                    modifier = Modifier.padding(top = 12.dp),
                ) { Text("创建课程") }
            } else {
                Text(state.name, style = MaterialTheme.typography.titleMedium)
                Text(
                    text = "教师：" + state.teacher.ifBlank { "未填写" } + " · 地点：" + state.location.ifBlank { "未填写" },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (!state.isNew) {
                SectionHeader(
                    title = "课后追问",
                    subtitle = "追问只在课后触发，且受主动消息预算与静默时段约束",
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("开启课后追问", modifier = Modifier.weight(1f))
                    Switch(
                        checked = state.followUpEnabled,
                        onCheckedChange = { checked -> viewModel.update { it.copy(followUpEnabled = checked) } },
                    )
                }
                OutlinedTextField(
                    value = state.followUpDelayMinutes.toString(),
                    onValueChange = { value ->
                        val parsed = value.trim().toIntOrNull()
                        viewModel.update { it.copy(followUpDelayMinutes = parsed ?: it.followUpDelayMinutes) }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("课后延迟（分钟，5–15）") },
                )
                Text("追问策略", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FollowUpMode.entries.forEach { mode ->
                        FilterChip(
                            selected = state.followUpMode == mode,
                            onClick = { viewModel.update { it.copy(followUpMode = mode) } },
                            label = { Text(mode.displayName) },
                        )
                    }
                }
                Text(
                    text = "关闭追问后，这门课的课后不会再主动打扰；已经排好的追问会在下次同步课表时被取消。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Button(onClick = { viewModel.saveFollowUpSettings() }, modifier = Modifier.padding(top = 8.dp)) {
                    Text("保存追问设置")
                }

                SectionHeader(title = "每周上课规则", subtitle = "规则决定课表长什么样；某次课到底上没上由周视图里的停课/调课决定")
                if (state.rules.isEmpty()) {
                    EmptyState(
                        title = "还没有上课规则",
                        description = "没有规则就不会生成任何课程实例，周视图会一直是空的。",
                    )
                } else {
                    state.rules.forEach { rule ->
                        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            Text(
                                text = weekdayDisplayName(rule.weekday) + " " + formatLocalTime(rule.startTimeLocal) +
                                    "–" + formatLocalTime(rule.endTimeLocal),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            Text(
                                text = "第 " + rule.sectionStart.toString() + "–" + rule.sectionEnd.toString() +
                                    " 节 · " + rule.weekParity.displayName +
                                    " · 第 " + rule.weekStart.toString() + "–" + rule.weekEnd.toString() + " 周",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            HorizontalDivider()
                        }
                    }
                }
                AddRuleForm(onAdd = { weekday, sectionStart, sectionEnd, start, end, parity, weekStart, weekEnd ->
                    viewModel.addRule(weekday, sectionStart, sectionEnd, start, end, parity, weekStart, weekEnd)
                })

                SectionHeader(title = "停课日", subtitle = "整学期都上不了的日期；只是某一次不上，用周视图里的「停课」")
                OutlinedTextField(
                    value = state.excludedDatesText,
                    onValueChange = { value -> viewModel.update { it.copy(excludedDatesText = value) } },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("日期，用逗号分隔（2026-10-16，2026-11-02）") },
                )
                Button(onClick = { viewModel.saveExcludedDates() }, modifier = Modifier.padding(top = 8.dp)) {
                    Text("保存停课日")
                }

                SectionHeader(title = "生成课程实例", subtitle = "新增或修改规则之后必须展开一次，周视图才会出现这些课")
                OutlinedButton(onClick = { viewModel.expandCourse() }) { Text("按规则展开课表") }

                SectionHeader(title = "删除课程")
                Text(
                    text = "删除是软删除：课程与其实例不再显示，但数据仍保留在本机数据库中，外部对账期间不做物理删除。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedButton(onClick = { confirmDelete = true }, modifier = Modifier.padding(top = 8.dp)) {
                    Text("删除这门课程")
                }
            }

            Spacer(Modifier.height(32.dp))
        }

        if (confirmDelete) {
            AlertDialog(
                onDismissRequest = { confirmDelete = false },
                title = { Text("删除这门课程？") },
                text = { Text("删除后它的课程实例不会再出现在周视图里。已经排好的课后追问也会随之失效。") },
                confirmButton = {
                    TextButton(onClick = {
                        confirmDelete = false
                        viewModel.deleteCourse()
                    }) { Text("删除") }
                },
                dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("取消") } },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddRuleForm(
    onAdd: (Int, String, String, String, String, WeekParity, String, String) -> Unit,
) {
    var weekday by remember { mutableStateOf(1) }
    var sectionStart by remember { mutableStateOf("1") }
    var sectionEnd by remember { mutableStateOf("2") }
    var start by remember { mutableStateOf("") }
    var end by remember { mutableStateOf("") }
    var parity by remember { mutableStateOf(WeekParity.ALL) }
    var weekStart by remember { mutableStateOf("1") }
    var weekEnd by remember { mutableStateOf("30") }

    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Text("星期", style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            (1..7).forEach { day ->
                FilterChip(
                    selected = weekday == day,
                    onClick = { weekday = day },
                    label = { Text(weekdayDisplayName(day)) },
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = sectionStart,
                onValueChange = { sectionStart = it },
                modifier = Modifier.weight(1f).padding(top = 8.dp),
                singleLine = true,
                label = { Text("起始节次") },
            )
            OutlinedTextField(
                value = sectionEnd,
                onValueChange = { sectionEnd = it },
                modifier = Modifier.weight(1f).padding(top = 8.dp),
                singleLine = true,
                label = { Text("结束节次") },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = start,
                onValueChange = { start = it },
                modifier = Modifier.weight(1f).padding(top = 8.dp),
                singleLine = true,
                label = { Text("上课时间 08:00") },
            )
            OutlinedTextField(
                value = end,
                onValueChange = { end = it },
                modifier = Modifier.weight(1f).padding(top = 8.dp),
                singleLine = true,
                label = { Text("下课时间 09:40") },
            )
        }

        Text("单双周", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            WeekParity.entries.forEach { option ->
                FilterChip(
                    selected = parity == option,
                    onClick = { parity = option },
                    label = { Text(option.displayName) },
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = weekStart,
                onValueChange = { weekStart = it },
                modifier = Modifier.weight(1f).padding(top = 8.dp),
                singleLine = true,
                label = { Text("起始周") },
            )
            OutlinedTextField(
                value = weekEnd,
                onValueChange = { weekEnd = it },
                modifier = Modifier.weight(1f).padding(top = 8.dp),
                singleLine = true,
                label = { Text("结束周") },
            )
        }

        Button(
            onClick = { onAdd(weekday, sectionStart, sectionEnd, start, end, parity, weekStart, weekEnd) },
            modifier = Modifier.padding(top = 12.dp),
        ) { Text("添加规则") }
        Text(
            text = "节次只用于显示；真正的上课时间以上面填写的时刻为准。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
