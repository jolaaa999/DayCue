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
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.StatusRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 权限页。
 *
 * 每一项都写「被拒绝之后会怎样」，因为用户点拒绝时真正想知道的是后果，不是权限名字。
 * 但说明只保留一句：上一版每项两到三行，五项加起来整整两屏。
 */
@Composable
fun SettingsPermissionsScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val context = LocalContext.current
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    val single = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        viewModel.updateCapabilities(container.capabilities())
    }
    val multiple = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.updateCapabilities(container.capabilities())
    }
    LaunchedEffect(Unit) {
        viewModel.refresh()
        viewModel.updateCapabilities(container.capabilities())
    }

    SettingsPageScaffold(title = "权限", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("被拒绝任何一项权限，App 都仍然可用，只是对应能力降级。")

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("能力")
            SettingGroup {
                StatusRow(
                    title = "录音",
                    subtitle = "被拒绝时文字记录完全不受影响",
                    status = if (state.recordingGranted) "已授予" else "未授予",
                    statusOk = state.recordingGranted,
                    actionLabel = if (state.recordingGranted) null else "授权",
                    onAction = if (state.recordingGranted) null else {
                        { single.launch(PermissionCenter.RECORD_AUDIO) }
                    },
                    showDivider = true,
                )
                StatusRow(
                    title = "相机",
                    subtitle = "被拒绝时仍可用系统选择器挑已有图片",
                    status = if (state.cameraGranted) "已授予" else "未授予",
                    statusOk = state.cameraGranted,
                    actionLabel = if (state.cameraGranted) null else "去设置",
                    onAction = if (state.cameraGranted) null else {
                        { CapabilityProbe.openAppSettings(context) }
                    },
                    showDivider = true,
                )
                StatusRow(
                    title = "通知",
                    subtitle = "被拒绝时不会弹提醒，待办仍显示在今天页",
                    status = if (state.notificationsGranted) "已授予" else "未授予",
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
                                single.launch(PermissionCenter.POST_NOTIFICATIONS)
                            } else {
                                CapabilityProbe.openNotificationSettings(context)
                            }
                        }
                    },
                    showDivider = true,
                )
                StatusRow(
                    title = "精确闹钟",
                    subtitle = "未授权时提醒会晚几分钟，App 会在通知里说明",
                    status = if (state.exactAlarmGranted) "已授予" else "未授予",
                    statusOk = state.exactAlarmGranted,
                    actionLabel = if (state.exactAlarmGranted) null else "去设置",
                    onAction = if (state.exactAlarmGranted) null else {
                        { CapabilityProbe.openExactAlarmSettings(context) }
                    },
                    showDivider = true,
                )
                StatusRow(
                    title = "定位",
                    // 状态标签只放结论，具体到哪一级定位写在说明里：
                    // 标签一旦放长句，右侧就会挤掉左边的能力名称。
                    subtitle = if (state.locationUsable) {
                        "定位已就绪，地点规则会按你设置的地点触发"
                    } else {
                        "定位不可用，地点规则整体暂停，不会伪造位置"
                    },
                    status = if (state.locationUsable) "可用" else "不可用",
                    statusOk = state.locationUsable,
                    actionLabel = if (state.locationUsable) null else "授权",
                    onAction = if (state.locationUsable) null else {
                        {
                            multiple.launch(
                                arrayOf(
                                    PermissionCenter.ACCESS_FINE_LOCATION,
                                    "android.permission.ACCESS_COARSE_LOCATION",
                                ),
                            )
                        }
                    },
                )
            }

            state.error?.let {
                Spacer(Modifier.height(DayCueSpacing.Medium))
                MessageCard(text = it, isError = true)
            }

            Spacer(Modifier.height(DayCueSpacing.Medium))
            Text(
                text = "在系统设置里改过权限后回到 App，状态会在回到前台时重新读取。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }
}
