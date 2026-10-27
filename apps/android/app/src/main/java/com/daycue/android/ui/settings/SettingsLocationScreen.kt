package com.daycue.android.ui.settings

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
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.NavigationRow
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.StatusRow
import com.daycue.android.ui.common.SwitchRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 地点与规则。
 *
 * 定位不可用时把总开关置灰并说明原因，而不是让它看起来「开着」：
 * 一个显示开着、实际不生效的开关，比直接告诉用户不可用更糟。
 */
@Composable
fun SettingsLocationScreen(
    onBack: () -> Unit,
    onOpenPlaces: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    val locationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.updateCapabilities(container.capabilities())
    }
    LaunchedEffect(Unit) {
        viewModel.refresh()
        viewModel.updateCapabilities(container.capabilities())
    }

    SettingsPageScaffold(title = "地点与规则", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("地点规则只在 App 被打开时判断，不申请后台定位，也不使用过期的位置。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("定位")
            SettingGroup {
                StatusRow(
                    title = "定位能力",
                    status = if (state.locationUsable) "可用（" + state.locationName + "）" else "不可用（" + state.locationName + "）",
                    statusOk = state.locationUsable,
                    actionLabel = if (state.locationUsable) null else "授权",
                    onAction = if (state.locationUsable) {
                        null
                    } else {
                        {
                            locationPermission.launch(
                                arrayOf(
                                    PermissionCenter.ACCESS_FINE_LOCATION,
                                    "android.permission.ACCESS_COARSE_LOCATION",
                                ),
                            )
                        }
                    },
                )
            }

            GroupLabel("规则")
            SettingGroup {
                SwitchRow(
                    title = "启用地点规则",
                    subtitle = if (state.locationUsable) "关闭后所有围栏会被取消" else "定位不可用，这个开关不会生效",
                    checked = state.locationRulesEnabled && state.locationUsable,
                    enabled = state.locationUsable,
                    onCheckedChange = viewModel::setLocationRulesEnabled,
                    showDivider = true,
                )
                NavigationRow(
                    title = "地点与规则管理",
                    subtitle = "半径、触发条件，以及每条规则现在会不会触发",
                    onClick = onOpenPlaces,
                )
            }

            Spacer(Modifier.height(DayCueSpacing.Medium))
            Text(
                text = "进入某地自动提醒在 App 未打开时可能不触发，这是当前实现的有意取舍。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }
}
