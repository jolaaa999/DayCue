package com.daycue.android.platform.capability

import android.content.Context
import android.os.Build
import com.daycue.android.data.repository.DeviceCapabilitySnapshot
import com.daycue.android.platform.permission.PermissionCenter

/**
 * 把 Android 的权限 / 能力翻译成服务端认识的能力键。
 *
 * 键名与 iOS 的 DeviceCapabilities 对齐（notifications / precise_location /
 * calendar_write / speech_transcription），服务端不区分平台，两类设备必须用同一套键。
 *
 * 一条硬约定：**未知的能力键直接省略**，不填 false。
 * 服务端把「键存在」当作「客户端已确认」；填 false 会让它以为这台设备确实收不到通知，
 * 从而放弃推送——这比「未知」糟得多。
 */
class AndroidDeviceCapabilitySnapshot(
    private val context: Context,
) : DeviceCapabilitySnapshot {

    private val appContext = context.applicationContext

    override fun asCapabilityMap(): Map<String, Boolean> {
        val report = CapabilityProbe.report(appContext)
        val map = linkedMapOf<String, Boolean>()
        map["notifications"] = report.notificationsAllowed
        // 「精确定位」而不是「有定位权限」：Android 12 起用户可以只给大致位置，
        // 那种情况下围栏精度会掉到公里级，服务端据此决定要不要依赖位置触发。
        map["precise_location"] = PermissionCenter.hasFineLocation(appContext)
        // Android 端不读写系统日历（见 README 的已知限制），所以这一项是明确的 false，不是未知。
        map["calendar_write"] = false
        // 语音转写始终依赖后端，客户端本地没有这个能力。
        map["speech_transcription"] = false
        return map
    }

    /** 展示名。Build.MODEL 在少数设备上是空串，所以给一个明确的兜底而不是留空。 */
    override fun deviceName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        return if (model.isEmpty()) "Android 设备" else model
    }
}
