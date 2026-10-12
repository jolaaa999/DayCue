package com.daycue.android

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import com.daycue.android.platform.platformDependenciesOrNull
import com.daycue.android.ui.DayCueApp
import com.daycue.android.ui.theme.DayCueTheme
import kotlinx.coroutines.launch
import java.time.ZoneId

/**
 * 唯一的 Activity。
 *
 * 刻意不做多 Activity：状态与返回栈全部交给 Navigation Compose，
 * 这样「记录 -> 详情 -> 返回」的逻辑与 iOS 端的 NavigationStack 是一一对应的。
 * Intent 里的数据（分享进来的文字、图片）也在这里解析后交给界面层。
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // targetSdk 35 起系统强制边到边，主动开启才能拿到 insets 并自己处理，而不是被系统裁切。
        enableEdgeToEdge()
        setContent {
            DayCueTheme {
                DayCueApp()
            }
        }
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
        }
    }

    private companion object {
        const val TAG = "MainActivity"
    }
}
