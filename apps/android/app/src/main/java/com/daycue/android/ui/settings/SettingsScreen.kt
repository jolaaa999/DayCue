package com.daycue.android.ui.settings

import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.KeyValueLine
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.rememberContainer

/**
 * 设置页。
 *
 * 权限那一块是这一页的重点：每一项都写清楚「被拒绝之后会怎样」，
 * 因为用户拒绝权限时真正想知道的是后果，而不是权限的名字。
 */
@Composable
fun SettingsScreen() {
    val container = rememberContainer()
    val context = LocalContext.current
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    var confirmClear by remember { mutableStateOf(false) }
    var dailyLimitDraft by remember { mutableStateOf<String?>(null) }
    var minIntervalDraft by remember { mutableStateOf<String?>(null) }
    var quietStartDraft by remember { mutableStateOf<String?>(null) }
    var quietEndDraft by remember { mutableStateOf<String?>(null) }

    // 权限只能在 Activity 里申请；申请结果回来后重新读一次能力状态，避免界面停留在旧结论上。
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        viewModel.updateCapabilities(container.capabilities())
    }
    val multiPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.updateCapabilities(container.capabilities())
    }

    LaunchedEffect(Unit) {
        viewModel.updateCapabilities(container.capabilities())
    }

    DayCueScreen(title = "设置") {
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            state.error?.let { item { MessageCard(it, isError = true) } }
            state.message?.let { item { MessageCard(it) } }

            item { SectionHeader(title = "后端", subtitle = "留空即纯本地运行：记录照常保存，只是不做解析与转写") }
            item {
                Column(modifier = Modifier.fillMaxWidth()) {
                    OutlinedTextField(
                        value = state.backendUrl,
                        onValueChange = viewModel::onBackendUrlChange,
                        label = { Text("后端地址") },
                        placeholder = { Text("例如 http://192.168.1.10:8080") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                        Button(onClick = viewModel::saveBackendUrl) { Text("保存地址") }
                        OutlinedButton(onClick = viewModel::testConnection) { Text("测试连接") }
                    }
                    when (state.connection) {
                        ConnectionState.TESTING -> Text("正在连接…", style = MaterialTheme.typography.bodySmall)
                        ConnectionState.OK -> Text(
                            text = state.connectionMessage.orEmpty(),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        ConnectionState.FAILED -> Text(
                            text = state.connectionMessage.orEmpty(),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                        ConnectionState.IDLE -> Unit
                    }
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("纯本地模式", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = "打开后不再发起任何网络请求，未发送的记录会留在本机",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(checked = state.offlineMode, onCheckedChange = viewModel::setOfflineMode)
                }
            }
            item { KeyValueLine("当前状态", if (state.purelyLocal) "纯本地（不会联网）" else "会联网") }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(title = "权限与能力", subtitle = "每一项被拒绝之后，App 都仍然可用，只是能力会降级") }

            item {
                PermissionRow(
                    label = "录音",
                    granted = state.recordingGranted,
                    explanation = "没有录音权限时，文字记录完全不受影响；录音按钮会提示需要授权。",
                    actionLabel = "授予录音权限",
                    onAction = { permissionLauncher.launch(PermissionCenter.RECORD_AUDIO) },
                )
            }
            item {
                PermissionRow(
                    label = "相机",
                    granted = state.cameraGranted,
                    explanation = "没有相机权限时，仍然可以用系统图片选择器挑一张已有图片。",
                    actionLabel = "查看系统设置",
                    onAction = { CapabilityProbe.openAppSettings(context) },
                )
            }
            item {
                PermissionRow(
                    label = "通知",
                    granted = state.notificationsGranted,
                    explanation = "没有通知权限时不会弹出提醒；待办与待回复仍然显示在今天页里。",
                    actionLabel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) "授予通知权限" else "查看通知设置",
                    onAction = {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            permissionLauncher.launch(PermissionCenter.POST_NOTIFICATIONS)
                        } else {
                            CapabilityProbe.openNotificationSettings(context)
                        }
                    },
                )
            }
            item {
                PermissionRow(
                    label = "精确闹钟",
                    granted = state.exactAlarmGranted,
                    explanation = "未授权时提醒会降级为不精确（可能有几分钟误差），App 会在通知里说明这一点。",
                    actionLabel = "去系统设置授权",
                    onAction = { CapabilityProbe.openExactAlarmSettings(context) },
                )
            }
            item {
                PermissionRow(
                    label = "定位",
                    granted = state.locationUsable,
                    explanation = if (state.locationUsable) {
                        "定位可用。地点规则由你单独开启，App 不会在后台持续定位。"
                    } else {
                        "定位不可用（" + state.locationName + "），地点规则已禁用，不会伪造位置。"
                    },
                    actionLabel = if (state.locationUsable) null else "授予定位权限",
                    onAction = if (state.locationUsable) null else {
                        { multiPermissionLauncher.launch(arrayOf(PermissionCenter.ACCESS_FINE_LOCATION, "android.permission.ACCESS_COARSE_LOCATION")) }
                    },
                )
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("启用地点规则", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = if (state.locationUsable) "只有开启后，地点规则才会被评估" else "定位不可用，这个开关不会生效",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(
                        checked = state.locationRulesEnabled && state.locationUsable,
                        enabled = state.locationUsable,
                        onCheckedChange = viewModel::setLocationRulesEnabled,
                    )
                }
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(title = "学期基准", subtitle = "课表按它换算周次；不设置就无法展开课程") }
            item {
                TermEditor(
                    firstMonday = state.termFirstMonday,
                    weeks = state.termWeeks,
                    onSave = viewModel::saveTerm,
                )
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(title = "打扰预算", subtitle = "限制 App 主动开口的次数；你自己设的提醒不在此限") }
            item {
                Column(modifier = Modifier.fillMaxWidth()) {
                    OutlinedTextField(
                        value = dailyLimitDraft ?: state.dailyLimit,
                        onValueChange = { dailyLimitDraft = it },
                        label = { Text("每日自主消息条数") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = minIntervalDraft ?: state.minIntervalMinutes,
                        onValueChange = { minIntervalDraft = it },
                        label = { Text("最小间隔（分钟）") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                    OutlinedTextField(
                        value = quietStartDraft ?: state.quietStart,
                        onValueChange = { quietStartDraft = it },
                        label = { Text("静默开始（如 22:30）") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                    OutlinedTextField(
                        value = quietEndDraft ?: state.quietEnd,
                        onValueChange = { quietEndDraft = it },
                        label = { Text("静默结束（如 08:00）") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                    Text(
                        text = "静默时段内到点的消息会顺延到静默结束，而不是被丢掉；但超过有效期就不再补发。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                    Button(
                        onClick = {
                            viewModel.saveBudget(
                                dailyLimitText = dailyLimitDraft ?: state.dailyLimit,
                                minIntervalText = minIntervalDraft ?: state.minIntervalMinutes,
                                quietStartText = quietStartDraft ?: state.quietStart,
                                quietEndText = quietEndDraft ?: state.quietEnd,
                            )
                            dailyLimitDraft = null
                            minIntervalDraft = null
                            quietStartDraft = null
                            quietEndDraft = null
                        },
                        modifier = Modifier.padding(top = 8.dp),
                    ) { Text("保存打扰预算") }
                }
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(title = "数据", subtitle = "全部数据都存在这台设备上") }
            item { KeyValueLine("笔记", state.noteCount.toString() + " 条") }
            item { KeyValueLine("待办", state.openTaskCount.toString() + " 条") }
            item {
                KeyValueLine(
                    label = "待同步操作",
                    value = if (state.outboxPending == 0) "0 条" else state.outboxPending.toString() + " 条（尚未接入外部写入，会一直留在这里）",
                )
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(title = "危险操作") }
            item {
                OutlinedButton(onClick = { confirmClear = true }) { Text("清空本机数据") }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空本机数据？") },
            text = {
                Text(
                    "会删除这台设备上的全部笔记、待办、课表、追问与记忆，" +
                        "包括尚未同步出去的操作记录（那些操作之后不会再发出）。这个动作无法撤销。",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    viewModel.clearLocalData()
                }) { Text("确认清空") }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun PermissionRow(
    label: String,
    granted: Boolean,
    explanation: String,
    actionLabel: String?,
    onAction: (() -> Unit)?,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(text = label, style = MaterialTheme.typography.bodyLarge)
            Text(
                text = if (granted) "  已授予" else "  未授予",
                style = MaterialTheme.typography.labelMedium,
                color = if (granted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
            )
        }
        Text(
            text = explanation,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!granted && actionLabel != null && onAction != null) {
            TextButton(onClick = onAction, modifier = Modifier.padding(top = 2.dp)) { Text(actionLabel) }
        }
    }
}

@Composable
private fun TermEditor(
    firstMonday: String,
    weeks: String,
    onSave: (String, String) -> Unit,
) {
    var dateDraft by remember(firstMonday) { mutableStateOf(firstMonday) }
    var weeksDraft by remember(weeks) { mutableStateOf(weeks) }
    Column(modifier = Modifier.fillMaxWidth()) {
        OutlinedTextField(
            value = dateDraft,
            onValueChange = { dateDraft = it },
            label = { Text("第一周的周一（如 2026-09-07）") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = weeksDraft,
            onValueChange = { weeksDraft = it },
            label = { Text("学期总周数（1–60）") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        )
        Button(onClick = { onSave(dateDraft, weeksDraft) }, modifier = Modifier.padding(top = 8.dp)) {
            Text("保存学期基准")
        }
    }
}
