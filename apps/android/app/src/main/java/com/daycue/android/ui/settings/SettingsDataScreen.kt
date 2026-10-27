package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueButtonStyle
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.ValueRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 数据管理。
 *
 * 危险操作单独成组、单独确认：它不跟「笔记有几条」放在一起，
 * 免得用户是想看统计、手一滑点到了清空。
 */
@Composable
fun SettingsDataScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()
    SettingsRefreshEffect(viewModel)

    var confirmClear by remember { mutableStateOf(false) }

    SettingsPageScaffold(title = "数据管理", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("全部数据都在这台设备上，没有服务端备份。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("本机数据")
            SettingGroup {
                ValueRow(label = "笔记", value = state.noteCount.toString() + " 条", showDivider = true)
                ValueRow(label = "待办", value = state.openTaskCount.toString() + " 条", showDivider = true)
                ValueRow(
                    label = "待同步操作",
                    value = if (state.outboxPending == 0) "0 条" else state.outboxPending.toString() + " 条",
                )
            }

            GroupLabel("危险操作")
            SettingGroup {
                Column(Modifier.padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium)) {
                    Text("清空本机数据", style = MaterialTheme.typography.bodyLarge)
                    Spacer(Modifier.height(DayCueSpacing.XSmall))
                    Text(
                        text = "会删除这台设备上的笔记、待办、课表、追问与记忆，包括还没同步出去的操作。无法撤销。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    DayCueButton(
                        text = "清空本机数据…",
                        onClick = { confirmClear = true },
                        style = DayCueButtonStyle.Outline,
                    )
                }
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }

    if (confirmClear) {
        ConfirmDangerDialog(
            title = "清空本机数据？",
            message = "会删除这台设备上的全部笔记、待办、课表、追问与记忆，" +
                "包括尚未同步出去的操作记录（那些操作之后不会再发出）。这个动作无法撤销。",
            confirmLabel = "确认清空",
            onDismiss = { confirmClear = false },
            onConfirm = {
                confirmClear = false
                viewModel.clearLocalData()
            },
        )
    }
}
