package com.daycue.android.ui.settings

import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.StatusRow
import com.daycue.android.ui.common.ValueRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 通知与主动帮助。
 *
 * 「打扰预算」全部用「点一行改一个值」的方式：这些数字一个月也未必改一次，
 * 却曾经在设置页占掉整屏（四个全宽输入框）。
 */
@Composable
fun SettingsProactiveScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val context = LocalContext.current
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        viewModel.updateCapabilities(container.capabilities())
    }
    LaunchedEffect(Unit) {
        viewModel.refresh()
        viewModel.updateCapabilities(container.capabilities())
    }

    var editingDaily by remember { mutableStateOf(false) }
    var editingInterval by remember { mutableStateOf(false) }
    var editingQuiet by remember { mutableStateOf(false) }

    SettingsPageScaffold(title = "通知与主动帮助", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("这些限制只管 App 主动开口的次数；你自己设的提醒不受影响。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("权限")
            SettingGroup {
                StatusRow(
                    title = "通知",
                    status = if (state.notificationsGranted) "已授予" else "未授予：不会弹出提醒，待办与追问仍显示在今天页",
                    statusOk = state.notificationsGranted,
                    actionLabel = if (state.notificationsGranted) {
                        null
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        "授权"
                    } else {
                        "去设置"
                    },
                    onAction = if (state.notificationsGranted) {
                        null
                    } else {
                        {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                permissionLauncher.launch(PermissionCenter.POST_NOTIFICATIONS)
                            } else {
                                CapabilityProbe.openNotificationSettings(context)
                            }
                        }
                    },
                )
            }

            GroupLabel("打扰预算")
            SettingGroup {
                ValueRow(
                    label = "每日自主消息",
                    value = state.dailyLimit + " 条",
                    onClick = { editingDaily = true },
                    showDivider = true,
                )
                ValueRow(
                    label = "最小间隔",
                    value = state.minIntervalMinutes + " 分钟",
                    onClick = { editingInterval = true },
                    showDivider = true,
                )
                ValueRow(
                    label = "静默时段",
                    value = state.quietStart + " – " + state.quietEnd,
                    onClick = { editingQuiet = true },
                )
            }

            Spacer(Modifier.height(DayCueSpacing.Medium))
            Text(
                text = "静默时段内到点的消息会顺延到结束之后，而不是被丢掉；超过有效期的则不再补发。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }

    if (editingDaily) {
        EditTextDialog(
            title = "每日自主消息",
            initial = state.dailyLimit,
            label = "最多几条 / 天",
            keyboardType = KeyboardType.Number,
            onDismiss = { editingDaily = false },
            onConfirm = { value ->
                editingDaily = false
                viewModel.saveBudget(value, state.minIntervalMinutes, state.quietStart, state.quietEnd)
            },
        )
    }
    if (editingInterval) {
        EditTextDialog(
            title = "最小间隔",
            initial = state.minIntervalMinutes,
            label = "两条之间的最小分钟数",
            keyboardType = KeyboardType.Number,
            onDismiss = { editingInterval = false },
            onConfirm = { value ->
                editingInterval = false
                viewModel.saveBudget(state.dailyLimit, value, state.quietStart, state.quietEnd)
            },
        )
    }
    if (editingQuiet) {
        EditPairDialog(
            title = "静默时段",
            firstLabel = "开始（如 22:30）",
            firstInitial = state.quietStart,
            secondLabel = "结束（如 08:00）",
            secondInitial = state.quietEnd,
            onDismiss = { editingQuiet = false },
            onConfirm = { start, end ->
                editingQuiet = false
                viewModel.saveBudget(state.dailyLimit, state.minIntervalMinutes, start, end)
            },
        )
    }
}
