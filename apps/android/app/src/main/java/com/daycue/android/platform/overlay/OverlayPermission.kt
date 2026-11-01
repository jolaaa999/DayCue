package com.daycue.android.platform.overlay

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager

/**
 * 悬浮窗权限（SYSTEM_ALERT_WINDOW）的判断与跳转。
 *
 * 这不是运行时权限：没有系统弹窗，只有「用户自己去设置页打开」这一条路。
 * 因此这里只做两件事——如实回答当前状态，以及给出那条系统设置页的 Intent。
 * 任何「假装已授权然后什么都不显示」的实现都会让用户以为功能坏了。
 */
object OverlayPermission {

    fun canDraw(context: Context): Boolean {
        val appContext = context.applicationContext
        // 少数定制 ROM 会保留 appops 但设置页显示为关，这里同时校验两者
        if (Settings.canDrawOverlays(appContext)) return true
        return hasAppOpPermission(appContext)
    }

    /**
     * 直接查 appops。
     *
     * 有些 ROM 的 canDrawOverlays 在「刚授予完就立刻返回」时会短暂返回 false，
     * 补一次 appops 查询能避免用户「明明授权了开关却打不开」。
     */
    private fun hasAppOpPermission(context: Context): Boolean = try {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? android.app.AppOpsManager
        val mode = appOps?.checkOpNoThrow(
            "android:system_alert_window",
            android.os.Process.myUid(),
            context.packageName,
        )
        mode == android.app.AppOpsManager.MODE_ALLOWED
    } catch (e: Throwable) {
        false
    }

    /** 跳到本应用的「显示在其他应用上层」设置页。 */
    fun requestIntent(context: Context): Intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:" + context.packageName),
    )

    /** 包管理器层面的自查：没有声明权限时上面的设置页也会被系统直接关掉，排查时先看这一条。 */
    fun isDeclared(context: Context): Boolean = try {
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        )
        info.requestedPermissions?.contains(android.Manifest.permission.SYSTEM_ALERT_WINDOW) == true
    } catch (e: Throwable) {
        false
    }
}
