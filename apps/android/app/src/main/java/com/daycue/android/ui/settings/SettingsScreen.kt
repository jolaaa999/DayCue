package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.DateRange
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Place
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.NavigationRow
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.ThemeMode

/**
 * 设置首页：只放分组入口，不放具体表单。
 *
 * 上一版把后端地址、令牌、五个权限、学期基准、打扰预算、数据统计、清空按钮
 * 全部堆在一页里，结果是「想改个静默时段要滑四屏」。现在这一页只回答
 * 「有哪些设置」并给出当前状态摘要，具体的东西都在二级页。
 *
 * 服务地址与令牌这种一次性配置挪到「高级设置」，但仍然可达。
 */
@Composable
fun SettingsScreen(
    onOpenAccount: () -> Unit,
    onOpenProactive: () -> Unit,
    onOpenLocation: () -> Unit,
    onOpenTerm: () -> Unit,
    onOpenPermissions: () -> Unit,
    onOpenAppearance: () -> Unit,
    onOpenData: () -> Unit,
    onOpenAdvanced: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: SettingsViewModel = viewModel(factory = remember(container) { SettingsViewModel.factory(container) })
    val state by viewModel.state.collectAsState()

    // 首页的摘要要显示真实的权限状态：不刷新就会一直显示上一次的结论。
    LaunchedEffect(Unit) {
        viewModel.refresh()
        viewModel.updateCapabilities(container.capabilities())
    }

    SettingsHomeContent(
        state = state,
        onOpenAccount = onOpenAccount,
        onOpenProactive = onOpenProactive,
        onOpenLocation = onOpenLocation,
        onOpenTerm = onOpenTerm,
        onOpenPermissions = onOpenPermissions,
        onOpenAppearance = onOpenAppearance,
        onOpenData = onOpenData,
        onOpenAdvanced = onOpenAdvanced,
    )
}

/** 设置首页的纯展示部分。状态由外部给，Preview 与调试画廊都用它渲染同一套界面。 */
@Composable
fun SettingsHomeContent(
    state: SettingsUiState,
    onOpenAccount: () -> Unit,
    onOpenProactive: () -> Unit,
    onOpenLocation: () -> Unit,
    onOpenTerm: () -> Unit,
    onOpenPermissions: () -> Unit,
    onOpenAppearance: () -> Unit,
    onOpenData: () -> Unit,
    onOpenAdvanced: () -> Unit,
) {
    val grantedCount = listOf(
        state.recordingGranted,
        state.cameraGranted,
        state.notificationsGranted,
        state.exactAlarmGranted,
        state.locationUsable,
    ).count { it }

    DayCueScreen(title = "设置") { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(padding),
            contentPadding = PaddingValues(
                start = DayCueSpacing.Screen,
                end = DayCueSpacing.Screen,
                top = DayCueSpacing.Small,
                bottom = DayCueSpacing.XXLarge,
            ),
        ) {
            state.error?.let { error -> item { MessageCard(text = error, isError = true) } }
            state.message?.let { message -> item { MessageCard(text = message) } }

            item {
                GroupLabel("账号与同步")
                SettingGroup {
                    NavigationRow(
                        title = "账号与同步",
                        subtitle = if (state.purelyLocal) {
                            "纯本地模式：不联网，记录照常保存"
                        } else {
                            "已连接 " + hostOf(state.backendUrl) + "，令牌" + (if (state.tokenStored) "已保存" else "未保存")
                        },
                        icon = Icons.Outlined.Person,
                        onClick = onOpenAccount,
                    )
                }
            }

            item {
                GroupLabel("提醒与帮助")
                SettingGroup {
                    NavigationRow(
                        title = "通知与主动帮助",
                        subtitle = (if (state.notificationsGranted) "通知已开启" else "通知未开启") +
                            " · 每日最多 " + state.dailyLimit + " 条",
                        icon = Icons.Outlined.Notifications,
                        onClick = onOpenProactive,
                        showDivider = true,
                    )
                    NavigationRow(
                        title = "地点与规则",
                        subtitle = when {
                            !state.locationUsable -> "定位不可用，规则暂停"
                            state.locationRulesEnabled -> "已开启 · " + state.locationName
                            else -> "已关闭 · 定位可用（" + state.locationName + "）"
                        },
                        icon = Icons.Outlined.Place,
                        onClick = onOpenLocation,
                        showDivider = true,
                    )
                    NavigationRow(
                        title = "课表与学期",
                        subtitle = if (state.termWeeks.isBlank()) {
                            "还没设置学期基准，课表无法展开"
                        } else {
                            "学期共 " + state.termWeeks + " 周"
                        },
                        icon = Icons.Outlined.DateRange,
                        onClick = onOpenTerm,
                    )
                }
            }

            item {
                GroupLabel("权限与外观")
                SettingGroup {
                    NavigationRow(
                        title = "权限",
                        // 摘要只给结论：一行的空间里塞「被拒绝时功能降级」这种解释会被折成两行，
                        // 反而让这一行比别的行高出一截；解释放在权限页里。
                        subtitle = if (grantedCount == 5) "全部已授予" else grantedCount.toString() + "/5 项已授予",
                        icon = Icons.Outlined.Lock,
                        onClick = onOpenPermissions,
                        showDivider = true,
                    )
                    NavigationRow(
                        title = "外观",
                        subtitle = ThemeMode.fromRaw(state.themeMode).displayName + " · 字号跟随系统",
                        icon = Icons.Outlined.Settings,
                        onClick = onOpenAppearance,
                    )
                }
            }

            item {
                GroupLabel("数据")
                SettingGroup {
                    NavigationRow(
                        title = "数据管理",
                        subtitle = "笔记 " + state.noteCount + " 条 · 待办 " + state.openTaskCount + " 条" +
                            if (state.outboxPending > 0) " · " + state.outboxPending + " 条待同步" else "",
                        icon = Icons.Outlined.Delete,
                        onClick = onOpenData,
                        showDivider = true,
                    )
                    NavigationRow(
                        title = "高级设置",
                        subtitle = "服务地址、后端令牌与连接诊断",
                        icon = Icons.Outlined.Build,
                        onClick = onOpenAdvanced,
                    )
                }
            }

            item {
                Spacer(Modifier.height(DayCueSpacing.XLarge))
                Text(
                    text = "所有数据都存在这台设备上。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

/**
 * 摘要里只显示主机与端口。
 *
 * 完整地址里可能带路径或内网域名，主页面上没必要铺开；
 * 需要核对完整值时进「高级设置」看得到。
 */
internal fun hostOf(url: String): String {
    val trimmed = url.trim()
    if (trimmed.isEmpty()) return "未配置后端"
    val withoutScheme = trimmed.substringAfter("://", trimmed)
    return withoutScheme.trimEnd('/')
}

/** 二级页的共用外壳：标题 + 返回。 */
@Composable
internal fun SettingsPageScaffold(
    title: String,
    onBack: () -> Unit,
    content: @Composable (PaddingValues) -> Unit,
) {
    DayCueScreen(title = title, onBack = onBack, content = content)
}

/** 供各二级页复用的「读取一次状态并刷新能力」效果。 */
@Composable
internal fun SettingsRefreshEffect(viewModel: SettingsViewModel) {
    val container = rememberContainer()
    LaunchedEffect(Unit) {
        viewModel.refresh()
        viewModel.updateCapabilities(container.capabilities())
    }
}

/** 统一的说明文字样式：二级页顶部那句「这一页管什么」。 */
@Composable
internal fun PageIntro(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(top = DayCueSpacing.Small, bottom = DayCueSpacing.Small),
    )
}
