package com.daycue.android.platform.location

import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.util.Log
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.platform.permission.PermissionCenter
import java.time.Instant

/** 一个确定的坐标。经度纬度分开存，避免有人用 0,0 当「没有位置」的哨兵值。 */
data class GeoPoint(val latitude: Double, val longitude: Double)

/**
 * 一份带时间戳与精度的定位结果。
 *
 * observedAt 必须来自系统（Location.time），不能是「读到它的时刻」：
 * 把 20 分钟前的缓存当作刚刚到达，是地点提醒里最难排查的一类错误——
 * 用户会在图书馆收到「你到家了」。系统不给出时间（time <= 0）时按「时间未知」处理，
 * 用 epoch 0 表示，新鲜度检查会因此丢弃它，这是刻意的：未知不等于新鲜。
 */
data class LocationFix(
    val point: GeoPoint,
    val observedAt: Instant,
    /** 系统没有给出精度时为 null（不是 0）。 */
    val horizontalAccuracyMeters: Double?,
)

/**
 * 定位能力探测。
 *
 * 只用系统 android.location.LocationManager，**不引用 GMS**：
 * 国行设备与无 Google 服务的设备上 FusedLocationProvider 会直接不可用，
 * 而本产品的硬约束是「没有定位能力就明确降级」，不允许因此整机不可用。
 *
 * 需要 GMS FusedLocationProvider 的分支应自己加 implementation(libs.play.services.location)
 * 并在此处替换实现，默认实现必须能在无 GMS 设备上工作。
 */
object LocationCapabilityProbe {

    private const val TAG = "LocationCapabilityProbe"

    fun availability(context: Context): LocationCapability {
        val appContext = context.applicationContext

        // 判断顺序即「用户能修的顺序」：先看硬件（改不了），再看系统开关（改一个设置），最后看权限。
        if (!appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_LOCATION)) {
            return LocationCapability.HARDWARE_MISSING
        }
        val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return LocationCapability.UNSUPPORTED

        if (!PermissionCenter.hasFineLocation(appContext) && !PermissionCenter.hasCoarseLocation(appContext)) {
            return LocationCapability.PERMISSION_DENIED
        }
        if (!isLocationEnabled(manager)) {
            return LocationCapability.PROVIDER_DISABLED
        }
        return LocationCapability.AVAILABLE
    }

    /**
     * 最近一次已知定位，带系统时间戳与精度；拿不到就返回 null。
     *
     * **绝不返回 (0,0)**：那个坐标在几内亚湾，用它触发「你到图书馆了」比不触发更糟。
     * 这里也不主动发起一次定位请求——那需要前台/后台定位权限与持续运行的服务，
     * 而本产品的定位规则是「用户显式开启 + 前台一次性取点」，主动请求应由界面层在做用户可见的操作时发起。
     */
    fun lastFix(context: Context): LocationFix? {
        val appContext = context.applicationContext
        if (!PermissionCenter.hasFineLocation(appContext) && !PermissionCenter.hasCoarseLocation(appContext)) {
            Log.w(TAG, "未授予定位权限，不返回任何坐标")
            return null
        }
        val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        if (!isLocationEnabled(manager)) {
            // 系统定位关了以后 getLastKnownLocation 仍可能返回很久以前的缓存，
            // 那种坐标被拿来判断「现在在不在图书馆」是纯粹的误导。
            Log.w(TAG, "系统定位服务已关闭，不返回陈旧坐标")
            return null
        }

        val candidates = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        )
        val latest = candidates
            .mapNotNull { provider ->
                try {
                    manager.getLastKnownLocation(provider)
                } catch (e: SecurityException) {
                    // 权限在运行中被撤销，或该 provider 不被允许：跳过它，继续看别的 provider。
                    Log.w(TAG, "读取 " + provider + " 的最近位置被拒绝", e)
                    null
                } catch (e: IllegalArgumentException) {
                    // 该设备没有这个 provider。
                    null
                }
            }
            // 多个 provider 都有缓存时取最新的那次定位，而不是取第一个非空。
            .maxByOrNull { it.time }
            ?: return null

        if (latest.latitude == 0.0 && latest.longitude == 0.0) {
            Log.w(TAG, "系统返回的坐标为 (0,0)，按无位置处理")
            return null
        }
        return LocationFix(
            point = GeoPoint(latest.latitude, latest.longitude),
            // time <= 0 表示系统没给出定位时间；用 epoch 0 让新鲜度检查把它判为「太旧」。
            observedAt = if (latest.time > 0L) Instant.ofEpochMilli(latest.time) else Instant.EPOCH,
            horizontalAccuracyMeters = if (latest.hasAccuracy()) latest.accuracy.toDouble() else null,
        )
    }

    /** 只要坐标的旧接口，保留给不关心新鲜度的调用方；新代码请用 lastFix。 */
    fun lastKnownLocation(context: Context): GeoPoint? = lastFix(context)?.point

    /** 28 之前没有 isLocationEnabled，只能用两个 provider 的开关近似系统定位总开关。 */
    private fun isLocationEnabled(manager: LocationManager): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return manager.isLocationEnabled
        }
        return manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }
}
