package com.daycue.android

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import com.daycue.android.platform.overlay.OverlayController
import com.daycue.android.platform.platformDependenciesOrNull
import com.daycue.android.ui.DayCueApp
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.time.ZoneId

/**
 * 唯一的 Activity。
 *
 * 刻意不做多 Activity：状态与返回栈全部交给 Navigation Compose，
 * 这样「记录 -> 详情 -> 返回」的逻辑与 iOS 端的 NavigationStack 是一一对应的。
 * Intent 里的数据（分享进来的文字、图片）也在这里解析后交给界面层。
 *
 * 悬浮球是唯一会从外部带路由进来的入口：点扇区后由服务发起带
 * [OverlayController.EXTRA_START_ROUTE] 的 Intent，这里把它转成一次导航请求。
 */
class MainActivity : ComponentActivity() {

    /**
     * 待处理的路由请求。
     *
     * 用 StateFlow 而不是直接在 onCreate 里 navigate：Activity 可能在悬浮球点击时
     * 还没创建完界面（冷启动），也可能已经在运行（singleTop + onNewIntent）。
     * 交给 Compose 侧统一消费，两条路径就不会各写一套。
     */
    private val routeRequests = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // targetSdk 35 起系统强制边到边，主动开启才能拿到 insets 并自己处理，而不是被系统裁切。
        enableEdgeToEdge()
        routeRequests.value = intent?.getStringExtra(OverlayController.EXTRA_START_ROUTE)
        // 主题在 DayCueApp 内部按「外观偏好」应用（可能要跟随系统、也可能被用户固定成浅色/深色），
        // 这里再包一层会让外层永远按系统深色来算，覆盖掉用户的选择。
        setContent {
            DayCueApp(
                pendingRoute = routeRequests,
                onRouteConsumed = { routeRequests.value = null },
            )
        }
    }

    /** 从悬浮球再次点击时 Activity 已在栈顶（singleTop），路由只能从这里进来。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeRequests.value = intent.getStringExtra(OverlayController.EXTRA_START_ROUTE)
    }

    /**
     * 回到前台时补一次「注册对账 + 当前围栏判断」。
     *
     * 为什么必须在这里做：
     * 1) 用户可能刚在系统设置里授予或撤销定位权限，或在 App 内改了规则 / 总开关，
     *    此时「实际已注册的围栏」与「现在应该监控的地点」就已经不一致。不对账会留下野注册——
     *    用户删掉的规则仍在后台触发提醒，这是最难排查的一类问题。
     * 2) 部分机型为省电会丢掉系统围栏事件，用最近一次定位补一次能救回「已经到家却没收到提醒」。
     *    这条路同样要过新鲜度检查，陈旧坐标不作数（见 GeoProactiveCoordinator）。
     *
     * 用 lifecycleScope：界面离开前台即取消，不会在后台留下无人回收的协程。
     */
    override fun onResume() {
        super.onResume()
        lifecycleScope.launch {
            val dependencies = platformDependenciesOrNull() ?: return@launch
            runCatching { dependencies.geoCoordinator.refreshRegistration() }
                .onFailure { Log.w(TAG, "回前台时地点规则注册对账失败", it) }
            runCatching { dependencies.geoCoordinator.evaluateCurrentFix(ZoneId.systemDefault()) }
                .onFailure { Log.w(TAG, "回前台时的围栏补偿判断失败", it) }

            // 悬浮球自愈：开关是开的、权限也在，但服务没在跑（被系统回收 / 刚重启手机）。
            // 只能在这里补启：Android 12+ 禁止后台启动前台服务，开机广播里拉起会被系统直接拦掉。
            // 补启失败不打扰用户——真正的原因是权限没了，设置页会显示「未授权」。
            val enabled = runCatching { dependencies.settingsRepository.floatingBallEnabled() }
                .getOrDefault(false)
            if (enabled && !OverlayController.isRunning()) {
                if (!OverlayController.start(this@MainActivity)) {
                    Log.i(TAG, "悬浮球开关为开，但当前无法启动（多半是悬浮窗权限被撤销）")
                }
            }
        }
    }

    private companion object {
        const val TAG = "MainActivity"
    }
}
