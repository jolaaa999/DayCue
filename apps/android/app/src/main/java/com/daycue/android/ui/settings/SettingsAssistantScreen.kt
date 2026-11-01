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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.daycue.android.platform.overlay.OverlayController
import com.daycue.android.platform.overlay.OverlayPermission
import com.daycue.android.ui.common.GroupLabel
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.NoticeRow
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.StatusRow
import com.daycue.android.ui.common.SwitchRow
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import kotlinx.coroutines.launch

/**
 * 悬浮球与语音。
 *
 * 这一页只如实回答三个问题：
 * 1) 悬浮球开关是开的吗；2) 悬浮窗权限有没有；3) 现在到底有没有球挂在外面。
 * 三者必须分开显示——「开关开着但没权限」是最常见的状态，把它显示成「已开启」
 * 就是在骗用户（他会一直找那个不存在的球）。
 *
 * 语音唤醒与 AI 操作权限在这一页只是占位说明，明确标注「未启用」：
 * 它们要等指令链路与常听能力真正落地，届时把这里的说明换成真实开关。
 */
@Composable
fun SettingsAssistantScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var enabled by remember { mutableStateOf(false) }
    var permissionGranted by remember { mutableStateOf(OverlayPermission.canDraw(context)) }
    var running by remember { mutableStateOf(OverlayController.isRunning()) }
    var message by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun refresh() {
        enabled = false // 先清空，避免读库失败时把上一次的旧值当事实
        scope.launch {
            runCatching { container.settingsRepository.floatingBallEnabled() }
                .onSuccess { enabled = it }
                .onFailure { error = "读取悬浮球开关失败：" + (it.message ?: "未知错误") }
            permissionGranted = OverlayPermission.canDraw(context)
            running = OverlayController.isRunning()
        }
    }

    LaunchedEffect(Unit) { refresh() }

    // 用户去系统设置授权后返回，本页必须重新读一次权限，否则会一直显示「未授权」
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    fun setBallEnabled(next: Boolean) {
        message = null
        error = null
        if (!next) {
            OverlayController.stop(context)
            enabled = false
            running = false
            scope.launch { container.settingsRepository.setFloatingBallEnabled(false) }
            message = "已关闭悬浮球"
            return
        }
        if (!OverlayPermission.canDraw(context)) {
            // 没有权限就绝不写「已开启」：先带用户去授权，回来后再由开关触发一次启动
            val launched = runCatching { context.startActivity(OverlayPermission.requestIntent(context)) }
                .isSuccess
            message = if (launched) {
                "请打开「显示在其他应用上层」后返回本页，再打开一次开关"
            } else {
                "无法打开系统授权页，请到系统设置里手动允许本应用显示在其他应用上层"
            }
            return
        }
        val started = OverlayController.start(context)
        enabled = started
        running = started
        scope.launch { container.settingsRepository.setFloatingBallEnabled(started) }
        if (!started) {
            error = "悬浮球启动失败。部分机型还需要在系统设置里允许本应用「后台弹出界面」或关闭省电限制。"
        } else {
            message = "悬浮球已开启。通知栏会保留一条常驻通知，可从那里关闭。"
        }
    }

    SettingsPageScaffold(title = "悬浮球与语音", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            PageIntro("悬浮球会显示在其他应用之上，点开是环形扇区菜单，可以直接跳去记录、待办、课表或记忆。")

            error?.let { MessageCard(text = it, isError = true) }
            message?.let { MessageCard(text = it) }

            Spacer(Modifier.height(DayCueSpacing.Small))
            GroupLabel("桌面悬浮球")
            SettingGroup {
                SwitchRow(
                    title = "显示悬浮球",
                    subtitle = "收起时是一个 64dp 的圆球，可拖动；点开是扇区菜单",
                    checked = enabled,
                    onCheckedChange = { setBallEnabled(it) },
                    showDivider = true,
                )
                StatusRow(
                    title = "悬浮窗权限",
                    subtitle = "「显示在其他应用上层」。没有它，开关打开也不会出现球",
                    status = if (permissionGranted) "已授权" else "未授权",
                    statusOk = permissionGranted,
                    actionLabel = if (permissionGranted) null else "去授权",
                    onAction = if (permissionGranted) {
                        null
                    } else {
                        {
                            runCatching { context.startActivity(OverlayPermission.requestIntent(context)) }
                                .onFailure { error = "无法打开系统授权页，请手动到系统设置里授权" }
                        }
                    },
                    showDivider = true,
                )
                StatusRow(
                    title = "当前状态",
                    status = when {
                        running -> "运行中"
                        enabled -> "已开启但没有在运行"
                        else -> "未开启"
                    },
                    statusOk = running,
                    subtitle = if (enabled && !running) {
                        "可能是权限被撤销，或系统回收了后台服务。回到 App 会自动重试一次。"
                    } else {
                        null
                    },
                )
            }

            Spacer(Modifier.height(DayCueSpacing.Section))
            GroupLabel("语音唤醒（未启用）")
            SettingGroup {
                NoticeRow(
                    text = "常听唤醒词需要麦克风前台服务与离线唤醒模型，本版本尚未接入，开关不会出现。",
                    tone = com.daycue.android.ui.common.MiniTagTone.Neutral,
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
                ) {
                    Text(
                        text = "Android 上常听必须是前台服务并显示常驻通知；iOS 不支持后台常听，只能在 App 内识别或用 Siri / 快捷指令。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(DayCueSpacing.Section))
            GroupLabel("AI 操作权限（未启用）")
            SettingGroup {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
                ) {
                    Text(
                        text = "计划：新增与更新由 AI 直接执行并保留可回滚的操作记录；删除必须先弹窗并用语音确认。这部分随指令链路一起交付。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(DayCueSpacing.Section))
            GroupLabel("已知限制")
            SettingGroup {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
                ) {
                    Text(
                        text = "悬浮球会显示在所有应用之上；在部分机型上需要额外允许「后台弹出界面」并关闭省电限制，否则开屏一段时间后会被系统回收。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }
    }
}
