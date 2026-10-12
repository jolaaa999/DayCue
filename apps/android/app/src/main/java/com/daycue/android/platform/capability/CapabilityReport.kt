package com.daycue.android.platform.capability

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.daycue.android.data.repository.LocationAvailability
import com.daycue.android.domain.reminder.ReminderCapability
import com.daycue.android.platform.location.LocationCapabilityProbe
import com.daycue.android.platform.permission.PermissionCenter

/**
 * 当前设备的能力快照。
 *
 * 单独做一次探测而不是让界面各处自己查，是为了让「设置页显示的降级说明」与
 * 「提醒真正被安排时的判断」用的是同一份结果，不会出现界面说能响、实际排不上的情况。
 */
data class CapabilityReport(
    val notificationsAllowed: Boolean,
    val exactAlarmAllowed: Boolean,
    val recordingAllowed: Boolean,
    val cameraAvailable: Boolean,
    val location: LocationAvailability,
) {
    /** 直接复用领域层的投递能力判定，避免平台层和领域层各算一套「精确 / 不精确 / 不可用」。 */
    val reminderCapability: ReminderCapability
        get() = ReminderCapability(
            notificationsAllowed = notificationsAllowed,
            exactAlarmAllowed = exactAlarmAllowed,
        )
}

object CapabilityProbe {

    private const val TAG = "CapabilityProbe"

    fun report(context: Context): CapabilityReport {
        val appContext = context.applicationContext
        return CapabilityReport(
            notificationsAllowed = PermissionCenter.hasNotifications(appContext),
            exactAlarmAllowed = exactAlarmAllowed(appContext),
            recordingAllowed = PermissionCenter.hasRecording(appContext),
            // 摄像头只报「硬件在不在」：权限被拒时仍然可以走系统图片选择器，那不是「没有摄像头」。
            cameraAvailable = appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY),
            location = LocationCapabilityProbe.availability(appContext),
        )
    }

    fun openAppSettings(context: Context) {
        startSettings(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri(context)))
    }

    fun openNotificationSettings(context: Context) {
        // 通知渠道的开关按应用分组，O 起用 ACTION_APP_NOTIFICATION_SETTINGS 才能直达本应用的通知页。
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        startSettings(context, intent)
    }

    fun openExactAlarmSettings(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            // 12 以下没有这个开关，精确闹钟也不需要用户授权。
            openAppSettings(context)
            return
        }
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri(context))
        startSettings(context, intent)
    }

    /** 12 及以上才有「闹钟和提醒」这个独立授权；更低版本的系统不限制精确闹钟。 */
    fun exactAlarmAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = context.applicationContext
            .getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
            ?: return false
        return alarmManager.canScheduleExactAlarms()
    }

    private fun packageUri(context: Context): Uri = Uri.fromParts("package", context.packageName, null)

    private fun startSettings(context: Context, intent: Intent) {
        // 从 application context 启动 Activity 必须带 NEW_TASK；部分厂商会抽掉这个设置页，
        // 所以失败时退回应用详情页，绝不让用户点了没反应。
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.applicationContext.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "打开系统设置页失败，退回应用详情页", e)
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri(context))
            fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.applicationContext.startActivity(fallback) }
        }
    }
}
