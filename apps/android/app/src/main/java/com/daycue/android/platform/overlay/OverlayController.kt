package com.daycue.android.platform.overlay

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import com.daycue.android.MainActivity

/**
 * 悬浮球服务的启动、停止与跳转入口。
 *
 * 单独抽出来是为了让界面层（设置页、主界面）不必知道服务的实现细节，
 * 也让「没有悬浮窗权限就不启动」这条判断只有一份。
 */
object OverlayController {

    private const val TAG = "DayCueOverlay"

    /** MainActivity 用来识别「从悬浮球跳过来、要落到哪一页」。 */
    const val EXTRA_START_ROUTE = "com.daycue.android.extra.START_ROUTE"

    internal const val ACTION_STOP = "com.daycue.android.overlay.STOP"

    fun isRunning(): Boolean = FloatingBallService.isRunning

    /**
     * 启动悬浮球。
     *
     * 返回 false 表示「没有悬浮窗权限，所以没有启动」，调用方必须如实告诉用户，
     * 不能吞掉这个返回值然后让用户以为开了。
     *
     * 必须在界面可见时调用：Android 12+ 禁止从后台启动前台服务，
     * Android 14+ 对前台服务类型的限制更严，从后台拉起会直接抛 ForegroundServiceStartNotAllowedException。
     */
    fun start(context: Context): Boolean {
        if (!OverlayPermission.canDraw(context)) {
            Log.i(TAG, "没有悬浮窗权限，不启动悬浮球")
            return false
        }
        val intent = Intent(context, FloatingBallService::class.java)
        return try {
            ContextCompat.startForegroundService(context, intent)
            true
        } catch (e: Throwable) {
            Log.e(TAG, "启动悬浮球服务失败", e)
            false
        }
    }

    fun stop(context: Context) {
        runCatching { context.stopService(Intent(context, FloatingBallService::class.java)) }
    }

    /** 打开 App 并落到指定路由（null 表示就停在今天页）。 */
    fun openApp(context: Context, route: String?) {
        val intent = appIntent(context)
        if (route != null) intent.putExtra(EXTRA_START_ROUTE, route)
        runCatching { context.startActivity(intent) }
            .onFailure { Log.w(TAG, "打开 App 失败", it) }
    }

    /** 从服务/广播里拉起 Activity 必须带 NEW_TASK，否则在非 Activity 上下文里会直接抛异常。 */
    fun appIntent(context: Context): Intent = Intent(context, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
}
