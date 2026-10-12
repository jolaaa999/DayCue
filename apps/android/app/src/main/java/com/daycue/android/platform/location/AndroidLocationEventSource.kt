package com.daycue.android.platform.location

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.os.Build
import android.util.Log
import com.daycue.android.domain.location.GeoMonitoredPlace
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.domain.location.LocationEventKind
import com.daycue.android.domain.location.LocationEventSource
import com.daycue.android.domain.location.RawLocationObservation
import com.daycue.android.platform.notify.INEXACT_WINDOW_MILLIS
import com.daycue.android.platform.notify.notificationId
import java.time.Instant

/**
 * 系统位置事件源的真实实现。
 *
 * 为什么用 addProximityAlert（系统围栏）而不是「LocationListener + 自己算距离」持续定位：
 * 1) 产品约束是**不做后台连续定位**，因此清单里没有 ACCESS_BACKGROUND_LOCATION；
 *    持续监听在 App 不可见时本来就会被系统掐掉，写在代码里只会是一个假承诺；
 * 2) 围栏由系统判定并在跨越时唤醒我们的广播，App 不需要常驻，才可能真正省电；
 * 3) 无 GMS 设备上 addProximityAlert 属于 AOSP 的 LocationManager，与 FusedLocationProvider 无关。
 *
 * 代价也必须写清楚：addProximityAlert 自 API 29 起被标记为废弃，且广播里**没有坐标、没有精度、
 * 没有事件时刻**。所以进入 / 离开的 observedAt 只能是「收到广播的时刻」、精度只能是 null；
 * 而需要坐标与真实新鲜度的路径（前台补偿检查、停留复查）走 lastKnownLocation，
 * 那条路径的 observedAt 来自系统定位时间，会被新鲜度检查如实拦截。
 *
 * 「自己算距离」并没有被丢掉：前台补偿与停留复查用的就是它，见 [currentObservation]。
 */
class AndroidLocationEventSource(context: Context) : LocationEventSource {

    private val appContext: Context = context.applicationContext
    private val state = GeoMonitorStateStore(appContext)

    override val capability: LocationCapability
        get() = LocationCapabilityProbe.availability(appContext)

    override val monitoredPlaceIds: Set<String>
        get() = state.monitoredPlaceIds()

    override fun refreshCapability(): LocationCapability = capability

    /**
     * 注册围栏。
     *
     * 能力不可用时直接不注册，且**不写入注册表**：把失败记成成功会让界面显示成「正常运行」，
     * 而用户永远等不到提醒——这是位置功能里最伤信任的一种表现。
     */
    @Suppress("DEPRECATION")
    override fun startMonitoring(places: List<GeoMonitoredPlace>) {
        if (places.isEmpty()) return
        val current = capability
        if (!current.isUsable) {
            Log.w(TAG, "定位不可用（" + current.displayName + "），跳过围栏注册")
            return
        }
        val manager = locationManager() ?: return
        for (place in places) {
            // FLAG_UPDATE_CURRENT 语义上一定会创建一个，但类型上仍是可空：
            // 拿不到就如实记成「没注册」，不能用 !! 把「系统拒绝创建」变成一次崩溃。
            val pending = fencePendingIntent(place.id, PendingIntent.FLAG_UPDATE_CURRENT)
            if (pending == null) {
                Log.w(TAG, "系统拒绝创建围栏 PendingIntent，未注册：" + place.id)
                state.unmarkMonitored(place.id)
                continue
            }
            try {
                manager.addProximityAlert(
                    place.latitude,
                    place.longitude,
                    place.radiusMeters.toFloat(),
                    NO_EXPIRY,
                    pending,
                )
                state.markMonitored(place.id, place.latitude, place.longitude, place.radiusMeters)
                Log.i(TAG, "已注册围栏：" + place.id)
            } catch (e: SecurityException) {
                // 权限在运行中被撤销：如实记成「没注册」，上层才能把规则显示成不可触发。
                Log.w(TAG, "围栏注册被系统拒绝（权限可能已撤销）：" + place.id, e)
                state.unmarkMonitored(place.id)
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "围栏参数被系统拒绝：" + place.id, e)
                state.unmarkMonitored(place.id)
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun stopMonitoring(placeIds: List<String>) {
        val manager = locationManager()
        for (placeId in placeIds) {
            val pending = fencePendingIntent(placeId, PendingIntent.FLAG_NO_CREATE)
            if (manager != null && pending != null) {
                // 取消一个不存在的围栏不是错误：用户可能已经手动清掉过，或系统重启后围栏本就没了。
                runCatching { manager.removeProximityAlert(pending) }
            }
            cancelDwellRecheck(placeId)
            state.unmarkMonitored(placeId)
        }
    }

    override fun stopAllMonitoring() {
        stopMonitoring(monitoredPlaceIds.toList())
    }

    override fun proximityObservation(placeId: String, entering: Boolean, now: Instant): RawLocationObservation {
        val previousInsideSince = state.insideSince(placeId)
        state.setInsideSince(placeId, if (entering) now else null)
        return RawLocationObservation(
            placeId = placeId,
            kind = if (entering) LocationEventKind.Entered else LocationEventKind.Exited,
            observedAt = now,
            // 系统围栏广播不提供精度：null 表示「系统没给」，不是「精度为 0」。
            horizontalAccuracyMeters = null,
            capability = capability,
            // 离开事件要用「这次离开所结束的那次进入」作为幂等键的场合，所以把上一次进入时刻带出去。
            insideSince = if (entering) now else previousInsideSince,
        )
    }

    /**
     * 用系统最近一次定位判断当前是否在围栏内。
     *
     * 会顺手更新「已进入」状态：状态更新与新鲜度检查是两件事。
     * 即使这次观测因为太旧而被丢弃，它给出的「20 分钟前就已经在围栏内」这个事实仍然成立，
     * 因此停留时长的起点应当记下来；而迟到的那次「进入提醒」确实不该发。
     */
    override fun currentObservation(placeId: String, now: Instant): RawLocationObservation? {
        val fence = state.fence(placeId) ?: return null
        val fix = LocationCapabilityProbe.lastFix(appContext) ?: return null
        val current = capability
        val distance = GeoDistance.meters(
            fix.point.latitude,
            fix.point.longitude,
            fence.latitude,
            fence.longitude,
        )
        val inside = distance <= fence.radiusMeters
        val previousInsideSince = state.insideSince(placeId)

        return when {
            inside && previousInsideSince == null -> {
                state.setInsideSince(placeId, fix.observedAt)
                RawLocationObservation(
                    placeId = placeId,
                    kind = LocationEventKind.Entered,
                    observedAt = fix.observedAt,
                    horizontalAccuracyMeters = fix.horizontalAccuracyMeters,
                    capability = current,
                    insideSince = fix.observedAt,
                )
            }

            // 走到这里 inside 必然为真，而上面那条已经排除了 previousInsideSince == null，
            // 所以它一定非空；把条件显式写出来，编译器才能智能转换，
            // 也把「Dwell 必须有进入时刻」这条前提留在代码里。
            inside && previousInsideSince != null -> RawLocationObservation(
                placeId = placeId,
                kind = LocationEventKind.Dwell(previousInsideSince),
                observedAt = fix.observedAt,
                horizontalAccuracyMeters = fix.horizontalAccuracyMeters,
                capability = current,
                insideSince = previousInsideSince,
            )

            previousInsideSince != null -> {
                state.setInsideSince(placeId, null)
                RawLocationObservation(
                    placeId = placeId,
                    kind = LocationEventKind.Exited,
                    observedAt = fix.observedAt,
                    horizontalAccuracyMeters = fix.horizontalAccuracyMeters,
                    capability = current,
                    insideSince = previousInsideSince,
                )
            }

            // 一直在外面、现在也在外面：没有状态变化，不产出任何规则可用的语义。
            else -> RawLocationObservation(
                placeId = placeId,
                kind = LocationEventKind.Indeterminate("当前不在围栏内，没有发生状态变化"),
                observedAt = fix.observedAt,
                horizontalAccuracyMeters = fix.horizontalAccuracyMeters,
                capability = current,
            )
        }
    }

    override fun scheduleDwellRecheck(placeId: String, at: Instant) {
        val manager = alarmManager() ?: return
        val pending = dwellPendingIntent(placeId, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        val triggerAtMillis = at.toEpochMilli()
        try {
            if (canScheduleExact()) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, pending)
            } else {
                // 停留复查晚几分钟不影响正确性（到达时刻仍取真实进入时刻），所以不申请精确闹钟。
                manager.setWindow(AlarmManager.RTC_WAKEUP, triggerAtMillis, INEXACT_WINDOW_MILLIS, pending)
            }
        } catch (e: SecurityException) {
            // 授权在最后一刻被撤销：降级为窗口唤醒，而不是让调用方崩掉。
            Log.w(TAG, "停留复查的精确唤醒被拒绝，降级为窗口唤醒：" + placeId, e)
            manager.setWindow(AlarmManager.RTC_WAKEUP, triggerAtMillis, INEXACT_WINDOW_MILLIS, pending)
        }
    }

    override fun cancelDwellRecheck(placeId: String) {
        val manager = alarmManager() ?: return
        val pending = dwellPendingIntent(placeId, PendingIntent.FLAG_NO_CREATE) ?: return
        manager.cancel(pending)
        pending.cancel()
    }

    // ---- 内部 ----

    private fun locationManager(): LocationManager? =
        appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    private fun alarmManager(): AlarmManager? =
        appContext.getSystemService(Context.ALARM_SERVICE) as? AlarmManager

    /** 12 以下没有「闹钟和提醒」这个独立授权，也就不需要查。 */
    private fun canScheduleExact(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return alarmManager()?.canScheduleExactAlarms() ?: false
    }

    private fun fencePendingIntent(placeId: String, flags: Int): PendingIntent? {
        val intent = Intent(appContext, GeoProximityReceiver::class.java).apply {
            action = GeoProximityReceiver.ACTION_PROXIMITY
            putExtra(GeoProximityReceiver.EXTRA_PLACE_ID, placeId)
        }
        // request code 用「geo_fence:<placeId>」的稳定哈希，与任务提醒、追问的 key 前缀不同，
        // 三者的 PendingIntent 不会互相命中。
        return PendingIntent.getBroadcast(
            appContext,
            notificationId("geo_fence:" + placeId),
            intent,
            flags or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun dwellPendingIntent(placeId: String, flags: Int): PendingIntent? {
        val intent = Intent(appContext, GeoDwellRecheckReceiver::class.java).apply {
            action = GeoDwellRecheckReceiver.ACTION_DWELL_RECHECK
            putExtra(GeoDwellRecheckReceiver.EXTRA_PLACE_ID, placeId)
        }
        return PendingIntent.getBroadcast(
            appContext,
            notificationId("geo_dwell:" + placeId),
            intent,
            flags or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private companion object {
        const val TAG = "AndroidLocationEventSource"

        /** addProximityAlert 的过期时间：-1 表示永不过期。 */
        const val NO_EXPIRY = -1L
    }
}
