package com.daycue.android.ui.place

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.domain.model.PlaceTrigger
import com.daycue.android.domain.schedule.weekdayDisplayName
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.rememberContainer

/**
 * 新建 / 编辑规则。
 *
 * 编辑时必须复用既有 ruleId（草稿里的 ruleId 非空就传它），
 * 否则保存会变成「又建了一条」——同一次进入会触发两条规则、收到两份通知。
 *
 * 关联任务只决定通知点开之后落到哪条任务上，不参与触发条件；
 * 留空是合法状态，界面明确写出来，避免用户以为必须选一个。
 */
@Composable
fun RuleEditScreen(
    placeId: String,
    ruleId: String?,
    onBack: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: PlaceViewModel = viewModel(
        factory = remember(container) {
            PlaceViewModel.factory(
                repository = container.placeRepository,
                geoChanges = container.geoCoordinator,
                locationPicker = container.locationPicker,
                catalog = container.placeCatalog,
            )
        },
    )
    val state by viewModel.state.collectAsState()
    val draft = state.ruleDraft

    LaunchedEffect(placeId, ruleId) { viewModel.startRuleDraft(placeId, ruleId) }

    DayCueScreen(
        title = if (ruleId == null) "新建规则" else "编辑规则",
        onBack = {
            viewModel.closeRuleDraft()
            onBack()
        },
    ) { padding ->
        if (draft == null) {
            Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
                Text("正在读取规则…", style = MaterialTheme.typography.bodyMedium)
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
            state.error?.let { MessageCard(it, isError = true) }
            state.message?.let { MessageCard(it) }

            if (!state.capability.isUsable) {
                MessageCard(
                    text = "当前定位不可用（" + state.capability.displayName + "）：" +
                        "保存后这条规则会被记成暂停状态，等定位恢复并重新打开总开关时自动启用。",
                    isError = true,
                )
            }

            SectionHeader(title = "触发条件", subtitle = "进入 / 离开由系统围栏给出，停留由到点复查确认")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PlaceTrigger.entries.forEach { trigger ->
                    FilterChip(
                        selected = draft.trigger == trigger,
                        onClick = { viewModel.updateRuleDraft { it.copy(trigger = trigger) } },
                        label = { Text(trigger.displayName) },
                    )
                }
            }

            OutlinedTextField(
                value = draft.title,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(title = value) } },
                label = { Text("通知标题") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = draft.body,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(body = value) } },
                label = { Text("通知正文（可选）") },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = draft.minDwellSeconds,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(minDwellSeconds = value) } },
                label = { Text("最短停留秒数（仅「停留」有意义）") },
                singleLine = true,
                enabled = draft.trigger == PlaceTrigger.DWELL,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            Text(
                text = if (draft.trigger == PlaceTrigger.DWELL) {
                    "必须在围栏内连续停留这么久才会提醒。"
                } else {
                    "当前触发条件不是「停留」，保存时这个秒数会被记成 0。"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = draft.cooldownSeconds,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(cooldownSeconds = value) } },
                label = { Text("冷却秒数（同一条规则两次提醒的最小间隔）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )

            SectionHeader(title = "生效范围", subtitle = "留空即不限；星期不选表示每天都生效")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (1..7).forEach { day ->
                    FilterChip(
                        selected = day in draft.weekdays,
                        onClick = { viewModel.toggleWeekday(day) },
                        label = { Text(weekdayDisplayName(day)) },
                    )
                }
            }
            OutlinedTextField(
                value = draft.activeFrom,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(activeFrom = value) } },
                label = { Text("生效起点（如 08:00，可留空）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = draft.activeTo,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(activeTo = value) } },
                label = { Text("生效终点（如 22:00，可留空）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = draft.expiresAtLocalDate,
                onValueChange = { value -> viewModel.updateRuleDraft { it.copy(expiresAtLocalDate = value) } },
                label = { Text("过期日期（如 2026-12-31，可留空）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            Text(
                text = "过期按当地这一天的最后一刻算（不是当天 00:00），所以「12-31 过期」在 12-31 当天仍然有效。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            SectionHeader(title = "关联任务", subtitle = "只影响通知点开之后落到哪条任务，可以留空")
            if (state.openTasks.isEmpty()) {
                Text(
                    text = "当前没有未完成的任务可以关联。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Column(Modifier.fillMaxWidth()) {
                    FilterChip(
                        selected = draft.linkedTaskId == null,
                        onClick = { viewModel.updateRuleDraft { it.copy(linkedTaskId = null) } },
                        label = { Text("不关联任务") },
                    )
                    state.openTasks.take(20).forEach { task ->
                        FilterChip(
                            selected = draft.linkedTaskId == task.id,
                            onClick = { viewModel.updateRuleDraft { it.copy(linkedTaskId = task.id) } },
                            label = { Text(task.title) },
                            modifier = Modifier.padding(top = 4.dp),
                        )
                    }
                }
            }

            SectionHeader(title = "启用")
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.weight(1f)) {
                    Text("启用这条规则", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        text = if (state.capability.isUsable) {
                            "关闭后围栏会被注销，但规则本身保留。"
                        } else {
                            "定位不可用，保存时会被强制记成暂停。"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = draft.enabled,
                    onCheckedChange = { value -> viewModel.updateRuleDraft { it.copy(enabled = value) } },
                )
            }

            Button(onClick = { viewModel.saveRule() }, modifier = Modifier.padding(top = 16.dp)) {
                Text("保存规则")
            }
            TextButton(
                onClick = { viewModel.closeRuleDraft(); onBack() },
                modifier = Modifier.padding(bottom = 24.dp),
            ) { Text("取消") }
        }
    }
}
