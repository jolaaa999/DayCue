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
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.domain.schedule.weekdayDisplayName
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.formatLocalTime
import com.daycue.android.ui.rememberContainer

/**
 * ICS 粘贴导入。
 *
 * 严格分两步：预览（只解析、不落库）→ 用户确认 → 导入。
 * 预览页必须把解析器的 warnings 与草稿的 notes 原样显示出来，
 * 因为「每 2 周一次」「没有结束时间」这类问题一旦静默处理，用户就会上错课。
 */
@Composable
fun IcsImportScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val viewModel: IcsImportViewModel = viewModel(factory = IcsImportViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    DayCueScreen(title = "导入 ICS", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            state.error?.let { MessageCard(text = it, isError = true) }

            val term = state.term
            Text(
                text = if (term == null) {
                    "还没有设置学期基准：ICS 里的周次要靠「第 1 周周一」换算，请先到课表页点「学期」。"
                } else {
                    "学期基准：第 1 周周一 " + com.daycue.android.core.DayCueTime.localDateString(term.firstWeekMonday) +
                        "，共 " + term.totalWeeks.toString() + " 周"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )

            SectionHeader(title = "粘贴 ICS 文本", subtitle = "支持 VEVENT + 每周重复；其他重复规则会进入提示，不会硬套")
            OutlinedTextField(
                value = state.text,
                onValueChange = { viewModel.onTextChange(it) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 6,
                label = { Text("BEGIN:VCALENDAR …") },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { viewModel.preview() },
                    enabled = !state.busy,
                    modifier = Modifier.padding(top = 8.dp),
                ) { Text("预览") }
                Button(
                    onClick = { viewModel.import() },
                    enabled = state.previewed && !state.busy,
                    modifier = Modifier.padding(top = 8.dp),
                ) { Text("确认导入") }
            }

            if (state.previewed) {
                SectionHeader(
                    title = "预览",
                    subtitle = "共 " + state.preview.size.toString() + " 条可导入日程（预览不会改动数据）",
                )
                if (state.preview.isEmpty()) {
                    EmptyState(
                        title = "没有可导入的日程",
                        description = "可能文件格式不对，或者所有日程都开始于学期第 1 周之前。请对照下面的解析提示。",
                    )
                } else {
                    state.preview.forEach { draft ->
                        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            Text(
                                text = draft.summary + " · " + weekdayDisplayName(draft.weekday),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            Text(
                                text = formatLocalTime(draft.startTime) + "–" + formatLocalTime(draft.endTime) +
                                    " · " + draft.weekParity.displayName +
                                    " · 第 " + draft.weekStart.toString() + "–" + draft.weekEnd.toString() + " 周",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            draft.location?.takeIf { it.isNotBlank() }?.let { location ->
                                Text("地点：" + location, style = MaterialTheme.typography.bodySmall)
                            }
                            if (draft.excludedDates.isNotEmpty()) {
                                Text(
                                    text = "文件里标记的取消日期：" + draft.excludedDates.joinToString("，") { date ->
                                        com.daycue.android.core.DayCueTime.localDateString(date)
                                    },
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            draft.notes.forEach { note ->
                                Text(
                                    text = "· " + note,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }

                if (state.warnings.isNotEmpty()) {
                    SectionHeader(title = "解析提示", subtitle = "解析器读不懂或做了取舍的地方，逐条列出")
                    state.warnings.forEach { warning ->
                        Text(
                            text = "· " + warning,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            state.report?.let { report ->
                SectionHeader(title = "导入结果", subtitle = "以下都是真实落库的计数")
                Text("新增课程：" + report.courseCount.toString() + " 门", style = MaterialTheme.typography.bodyMedium)
                Text("新增/更新规则：" + report.ruleCount.toString() + " 条", style = MaterialTheme.typography.bodyMedium)
                Text("新增课程实例：" + report.instanceCount.toString() + " 个", style = MaterialTheme.typography.bodyMedium)
                if (report.warnings.isNotEmpty()) {
                    SectionHeader(title = "导入过程中的提示")
                    report.warnings.forEach { warning ->
                        Text(
                            text = "· " + warning,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                if (report.notes.isNotEmpty()) {
                    SectionHeader(title = "需要你核对的点")
                    report.notes.forEach { note ->
                        Text(
                            text = "· " + note,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Text(
                    text = "导入完成。回到课表页确认周次与节次是否正确。",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp),
                )
                TextButton(onClick = onBack) { Text("返回课表") }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}
