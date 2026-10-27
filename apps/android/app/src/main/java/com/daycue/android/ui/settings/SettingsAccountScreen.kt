package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueButtonStyle
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.StatusRow
import com.daycue.android.ui.common.SwitchRow
import com.daycue.android.ui.common.ValueRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 账号与同步。
 *
 * 这里只表达三件事：现在是否联网、令牌有没有存、队列里还压着多少。
 * 具体地址与令牌的填写在「高级设置」——它们是配置一次就不再动的东西。
 */
@Composable
fun SettingsAccountScreen(
    onBack: () -> Unit,
    onOpenAdvanced: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()
    SettingsRefreshEffect(viewModel)

    SettingsPageScaffold(title = "账号与同步", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("记录永远先存在本机。联网只用于 AI 解析、同步与设备登记，断开也不会丢内容。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            SettingGroup {
                SwitchRow(
                    title = "纯本地模式",
                    subtitle = "打开后不再发起任何网络请求",
                    checked = state.offlineMode,
                    onCheckedChange = viewModel::setOfflineMode,
                )
            }

            GroupLabel("状态")
            SettingGroup {
                ValueRow(
                    label = "后端地址",
                    value = hostOf(state.backendUrl),
                    onClick = onOpenAdvanced,
                    showDivider = true,
                )
                StatusRow(
                    title = "后端令牌",
                    // 401 的后果写进说明而不是状态标签：标签是给「扫一眼」用的，长句会挤掉左边的名称。
                    subtitle = if (state.tokenStored) null else "未保存时设备登记与解析会返回 401",
                    status = if (state.tokenStored) "已保存" else "未保存",
                    statusOk = state.tokenStored,
                    showDivider = true,
                )
                StatusRow(
                    title = "待同步操作",
                    subtitle = if (state.outboxPending == 0) null else "网络恢复后会自动重试",
                    status = if (state.outboxPending == 0) "没有积压" else state.outboxPending.toString() + " 条等待",
                    statusOk = state.outboxPending == 0,
                )
            }

            Spacer(Modifier.height(DayCueSpacing.XLarge))
            DayCueButton(
                text = "打开高级设置",
                onClick = onOpenAdvanced,
                style = DayCueButtonStyle.Tonal,
            )
            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }
}
