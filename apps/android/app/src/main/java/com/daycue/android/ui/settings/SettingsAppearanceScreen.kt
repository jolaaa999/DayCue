package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinTouchTarget
import com.daycue.android.ui.theme.ThemeMode

/**
 * 外观。
 *
 * 只提供深浅色三档。不提供「字号」开关：字号跟随系统设置（显示 → 字体大小），
 * 再放一个 App 内字号开关，等于和系统设置打架，最后用户不知道该改哪个。
 */
@Composable
fun SettingsAppearanceScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()
    SettingsRefreshEffect(viewModel)

    val current = ThemeMode.fromRaw(state.themeMode)

    SettingsPageScaffold(title = "外观", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("主题会立刻生效，不需要重启。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("主题")
            SettingGroup {
                ThemeMode.entries.forEachIndexed { index, mode ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = MinTouchTarget)
                            .selectable(
                                selected = current == mode,
                                onClick = { viewModel.setThemeMode(mode) },
                            )
                            .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = current == mode, onClick = { viewModel.setThemeMode(mode) })
                        Spacer(Modifier.width(DayCueSpacing.Small))
                        Text(mode.displayName, style = MaterialTheme.typography.bodyLarge)
                    }
                    if (index != ThemeMode.entries.lastIndex) com.daycue.android.ui.common.RowDivider()
                }
            }

            GroupLabel("字号")
            SettingGroup {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
                ) {
                    Text(
                        text = "字号跟随系统设置。需要更大的字，去系统「显示 → 字体大小」调整，界面会整体放大且不会被裁切。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }
}
