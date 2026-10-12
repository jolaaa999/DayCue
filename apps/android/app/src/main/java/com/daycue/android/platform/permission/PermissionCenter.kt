package com.daycue.android.platform.permission

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * 运行时权限的统一判断点。
 *
 * 全部走「查询当前状态」而不是「请求」：请求必须由 Activity 发起（Compose 的 rememberLauncherForActivityResult），
 * 平台层只负责如实回答「现在有没有」，这样权限弹窗的时机完全由界面掌控。
 */
object PermissionCenter {

    val RECORD_AUDIO: String = Manifest.permission.RECORD_AUDIO
    val CAMERA: String = Manifest.permission.CAMERA
    val POST_NOTIFICATIONS: String = Manifest.permission.POST_NOTIFICATIONS
    val ACCESS_FINE_LOCATION: String = Manifest.permission.ACCESS_FINE_LOCATION

    fun isGranted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context.applicationContext, permission) == PackageManager.PERMISSION_GRANTED

    fun hasRecording(context: Context): Boolean = isGranted(context, RECORD_AUDIO)

    fun hasCamera(context: Context): Boolean = isGranted(context, CAMERA)

    /**
     * 通知是否真的能弹出来。
     *
     * 33 以下 POST_NOTIFICATIONS 根本不存在，checkSelfPermission 只会返回「拒绝」，
     * 所以那里用 areNotificationsEnabled：它同时覆盖「用户在系统设置里关掉了通知」，
     * 比只看权限更接近事实。
     */
    fun hasNotifications(context: Context): Boolean {
        val appContext = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return isGranted(appContext, POST_NOTIFICATIONS)
        }
        return NotificationManagerCompat.from(appContext).areNotificationsEnabled()
    }

    fun hasFineLocation(context: Context): Boolean = isGranted(context, ACCESS_FINE_LOCATION)

    /**
     * 粗略定位也要单独判断：Android 12 起用户可以只授予「大致位置」，
     * 那种情况下 FINE 是拒绝的，但粗略定位仍然可用。
     */
    fun hasCoarseLocation(context: Context): Boolean = isGranted(context, Manifest.permission.ACCESS_COARSE_LOCATION)
}
