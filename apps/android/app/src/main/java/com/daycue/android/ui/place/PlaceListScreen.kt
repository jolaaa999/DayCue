package com.daycue.android.ui.place

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
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
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.rememberContainer

/**
 * 地点与规则列表。
 *
 * 这一页把「某个地点会不会触发、为什么不会触发」放在列表里直接说清楚：
 * 地点与规则的链路很长（能力 -> 总开关 -> 规则开关 -> 地点确认 -> 过期），
 * 只要其中任何一环没接上就是「建了规则但永远不响」，而用户从界面上完全看不出来。
 * 所以每条规则都带一行 readiness 结论，这句话与系统实际判定用的是同一个 Evaluator。
 */
@Composable
fun PlaceListScreen(
    onBack: () -> Unit,
    onEditPlace: (String?) -> Unit,
    onEditRule: (placeId: String, ruleId: String?) -> Unit,
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

    // 每次回到这一页都重读能力与总开关：用户可能刚从系统设置里改过权限，
    // 拿旧结论展示会让界面说「可以触发」而实际不会。
    LaunchedEffect(Unit) { viewModel.refreshAvailability() }

    var pendingDeletePlace by remember { mutableStateOf<String?>(null) }
    var pendingDeleteRule by remember { mutableStateOf<String?>(null) }

    DayCueScreen(
        title = "地点与规则",
        onBack = onBack,
        actions = {
            TextButton(onClick = { onEditPlace(null) }) { Text("新建地点") }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            state.error?.let { item { MessageCard(it, isError = true) } }
            state.message?.let { item { MessageCard(it) } }

            item {
                CapabilityCard(
                    capabilityName = state.capability.displayName,
                    usable = state.capability.isUsable,
                    rulesEnabled = state.locationRulesEnabled,
                )
            }

            if (state.places.isEmpty()) {
                item {
                    EmptyState(
                        title = "还没有地点",
                        description = "先新建一个地点（需要你给出真实位置），再为它添加触发规则。",
                        actionLabel = "新建地点",
                        onAction = { onEditPlace(null) },
                    )
                }
            }

            items(state.places) { item ->
                PlaceCard(
                    item = item,
                    locationReady = state.locationReady,
                    onEditPlace = { onEditPlace(item.place.id) },
                    onDeletePlace = { pendingDeletePlace = item.place.id },
                    onAddRule = { onEditRule(item.place.id, null) },
                    onEditRule = { ruleId -> onEditRule(item.place.id, ruleId) },
                    onDeleteRule = { ruleId -> pendingDeleteRule = ruleId },
                    onToggleRule = { ruleId, enabled -> viewModel.setRuleEnabled(ruleId, enabled) },
                )
            }
        }
    }

    pendingDeletePlace?.let { placeId ->
        val name = state.places.firstOrNull { it.place.id == placeId }?.place?.name.orEmpty()
        AlertDialog(
            onDismissRequest = { pendingDeletePlace = null },
            title = { Text("删除地点「" + name + "」？") },
            text = {
                Text(
                    "这个地点下面的规则会一起删除，它们已经排队但还没发出的提醒也会被取消。" +
                        "数据是软删除，仍保留在本机数据库里。",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingDeletePlace = null
                    viewModel.deletePlace(placeId)
                }) { Text("确认删除") }
            },
            dismissButton = { TextButton(onClick = { pendingDeletePlace = null }) { Text("取消") } },
        )
    }

    pendingDeleteRule?.let { ruleId ->
        val title = state.places
            .flatMap { it.rules }
            .firstOrNull { it.rule.id == ruleId }
            ?.rule?.title.orEmpty()
        AlertDialog(
            onDismissRequest = { pendingDeleteRule = null },
            title = { Text("删除规则「" + title + "」？") },
            text = { Text("删除后会立刻注销这个地点的围栏，并取消这条规则已经排上的提醒。") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDeleteRule = null
                    viewModel.deleteRule(ruleId)
                }) { Text("确认删除") }
            },
            dismissButton = { TextButton(onClick = { pendingDeleteRule = null }) { Text("取消") } },
        )
    }
}

/** 定位能力卡片。不可用时必须说清「规则会被暂停」，而不是显示成正常。 */
@Composable
private fun CapabilityCard(
    capabilityName: String,
    usable: Boolean,
    rulesEnabled: Boolean,
) {
    Surface(
        color = if (usable) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.errorContainer,
        contentColor = if (usable) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onErrorContainer,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(12.dp)) {
            Text("定位能力：" + capabilityName, style = MaterialTheme.typography.titleSmall)
            Text(
                text = when {
                    !usable ->
                        "定位不可用时新增的规则会被保存成暂停状态；已有关闭的规则也不会触发。" +
                            "等定位恢复并重新打开总开关后，围栏会自动重新注册。"
                    !rulesEnabled -> "定位可用，但「启用地点规则」的总开关是关的；规则不会被评估。"
                    else -> "定位可用且总开关已打开，围栏会按下面的规则注册。"
                },
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun PlaceCard(
    item: PlaceListItem,
    locationReady: Boolean,
    onEditPlace: () -> Unit,
    onDeletePlace: () -> Unit,
    onAddRule: () -> Unit,
    onEditRule: (String) -> Unit,
    onDeleteRule: (String) -> Unit,
    onToggleRule: (String, Boolean) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Text(item.place.name, style = MaterialTheme.typography.titleMedium)
        Text(
            text = "半径 " + formatRadius(item.place.radiusMeters) + " 米 · " +
                item.place.coordinateSystem.displayName + " · " +
                (item.place.address?.takeIf { it.isNotBlank() } ?: "未填写地址"),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = "坐标 " + formatCoordinate(item.place.latitude) + ", " + formatCoordinate(item.place.longitude) +
                " · 规则 " + item.rules.size + " 条",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 4.dp)) {
            OutlinedButton(onClick = onEditPlace) { Text("编辑") }
            OutlinedButton(onClick = onAddRule) { Text("加规则") }
            OutlinedButton(onClick = onDeletePlace) { Text("删除") }
        }

        if (item.rules.isEmpty()) {
            Text(
                text = "这个地点还没有规则，它不会产生任何提醒。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp, start = 8.dp),
            )
        }

        item.rules.forEach { entry ->
            RuleRow(
                rule = entry.rule,
                readinessText = entry.readiness?.displayText,
                active = entry.readiness?.isActive == true && locationReady,
                onEdit = { onEditRule(entry.rule.id) },
                onDelete = { onDeleteRule(entry.rule.id) },
                onToggle = { enabled -> onToggleRule(entry.rule.id, enabled) },
            )
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
    }
}

@Composable
private fun RuleRow(
    rule: GeoRuleRecord,
    readinessText: String?,
    active: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onToggle: (Boolean) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(rule.title, style = MaterialTheme.typography.bodyLarge)
                Text(
                    text = rule.trigger.displayName + conditionSuffix(rule) +
                        (if (rule.cooldownSeconds > 0) " · 冷却 " + rule.cooldownSeconds + " 秒" else ""),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (rule.linkedTaskId != null) {
                    Text(
                        text = "关联任务：" + rule.linkedTaskId,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    text = readinessText ?: "可触发状态未知",
                    style = MaterialTheme.typography.bodySmall,
                    // 不会触发的规则必须是警示色：绿色会让用户以为它在工作。
                    color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                )
            }
            Switch(checked = rule.enabled, onCheckedChange = onToggle)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onEdit) { Text("编辑规则") }
            TextButton(onClick = onDelete) { Text("删除规则") }
        }
    }
}

private fun conditionSuffix(rule: GeoRuleRecord): String = when (rule.trigger) {
    com.daycue.android.domain.model.PlaceTrigger.DWELL -> "（最短停留 " + rule.minDwellSeconds + " 秒）"
    else -> ""
}

internal fun formatRadius(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
