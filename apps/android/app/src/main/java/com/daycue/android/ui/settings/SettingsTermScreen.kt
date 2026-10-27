package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.NavigationRow
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.ValueRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 课表与学期。
 *
 * 学期基准决定「第几周」，课表里的单双周规则全靠它换算。
 * 没设置时不说「未设置」就完了，还要说清后果：课表展不开。
 */
@Composable
fun SettingsTermScreen(
    onBack: () -> Unit,
    onOpenSchedule: () -> Unit,
    onImportIcs: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()
    SettingsRefreshEffect(viewModel)

    var editing by remember { mutableStateOf(false) }

    SettingsPageScaffold(title = "课表与学期", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("学期基准用来把「第几周」换算成具体日期；不设置就无法展开课程。")

            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("学期基准")
            SettingGroup {
                ValueRow(
                    label = "第一周的周一",
                    value = state.termFirstMonday.ifBlank { "未设置" },
                    onClick = { editing = true },
                    showDivider = true,
                )
                ValueRow(
                    label = "学期总周数",
                    value = if (state.termWeeks.isBlank()) "未设置" else state.termWeeks + " 周",
                    onClick = { editing = true },
                )
            }

            GroupLabel("课表")
            SettingGroup {
                NavigationRow(
                    title = "打开课表",
                    subtitle = "按周查看课程与停课安排",
                    onClick = onOpenSchedule,
                    showDivider = true,
                )
                NavigationRow(
                    title = "从 ICS 导入",
                    subtitle = "粘贴课表文件内容，确认后才会落库",
                    onClick = onImportIcs,
                )
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }

    if (editing) {
        EditPairDialog(
            title = "学期基准",
            firstLabel = "第一周的周一（2026-09-07）",
            firstInitial = state.termFirstMonday,
            secondLabel = "学期总周数（1–60）",
            secondInitial = state.termWeeks,
            firstKeyboardType = KeyboardType.Text,
            secondKeyboardType = KeyboardType.Number,
            onDismiss = { editing = false },
            onConfirm = { date, weeks ->
                editing = false
                viewModel.saveTerm(date, weeks)
            },
        )
    }
}
