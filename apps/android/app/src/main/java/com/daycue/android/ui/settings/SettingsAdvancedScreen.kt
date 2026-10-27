package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueButtonStyle
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.KeyValueLine
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 高级设置：服务地址、后端令牌、连接诊断。
 *
 * 这些是「配置一次就不再动」的东西，但必须仍然可达——
 * 上一轮的教训就是：TokenStore 写好了却没有入口，设备登记与解析全是 401。
 */
@Composable
fun SettingsAdvancedScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()
    SettingsRefreshEffect(viewModel)

    SettingsPageScaffold(title = "高级设置", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("留空即纯本地运行：记录照常保存，只是不做解析与转写。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("服务地址")
            OutlinedTextField(
                value = state.backendUrl,
                onValueChange = viewModel::onBackendUrlChange,
                label = { Text("后端地址") },
                placeholder = { Text("例如 http://192.168.1.10:8787") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.medium,
            )
            Spacer(Modifier.height(DayCueSpacing.Medium))
            Row {
                DayCueButton(
                    text = "保存地址",
                    onClick = viewModel::saveBackendUrl,
                    style = DayCueButtonStyle.Tonal,
                )
                Spacer(Modifier.padding(horizontal = DayCueSpacing.XSmall))
                DayCueButton(
                    text = "测试连接",
                    onClick = viewModel::testConnection,
                    style = DayCueButtonStyle.Outline,
                )
            }
            when (state.connection) {
                ConnectionState.TESTING -> Text(
                    text = "正在连接…",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = DayCueSpacing.Small),
                )
                ConnectionState.OK -> Text(
                    text = state.connectionMessage.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(top = DayCueSpacing.Small),
                )
                ConnectionState.FAILED -> Text(
                    text = state.connectionMessage.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(top = DayCueSpacing.Small),
                )
                ConnectionState.IDLE -> Unit
            }

            GroupLabel("后端令牌")
            OutlinedTextField(
                value = state.bearerToken,
                onValueChange = viewModel::onBearerTokenChange,
                label = { Text("Bearer Token") },
                placeholder = { Text("在电脑上运行 scripts/issue-token.ps1 取得") },
                singleLine = true,
                // 令牌等同密码：遮挡显示，避免被旁观或截屏带走。
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.medium,
            )
            Spacer(Modifier.height(DayCueSpacing.Medium))
            Row {
                DayCueButton(
                    text = "保存令牌",
                    onClick = viewModel::saveBearerToken,
                    style = DayCueButtonStyle.Tonal,
                )
                Spacer(Modifier.padding(horizontal = DayCueSpacing.XSmall))
                DayCueButton(
                    text = "清除令牌",
                    onClick = {
                        // 先清空草稿再保存，等价于「清除已存的令牌」。
                        viewModel.onBearerTokenChange("")
                        viewModel.saveBearerToken()
                    },
                    style = DayCueButtonStyle.Outline,
                )
            }
            Text(
                text = if (state.tokenStored) {
                    "已保存令牌：设备登记、同步与解析可以正常调用"
                } else {
                    "尚未保存令牌：设备登记、同步与解析都会返回 401"
                },
                style = MaterialTheme.typography.bodySmall,
                color = if (state.tokenStored) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = DayCueSpacing.Small),
            )

            GroupLabel("当前状态")
            SettingGroup {
                Column(Modifier.padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Small)) {
                    KeyValueLine("联网状态", if (state.purelyLocal) "纯本地（不会联网）" else "会联网")
                    KeyValueLine("待同步操作", state.outboxPending.toString() + " 条")
                }
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }
}
