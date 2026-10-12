package com.daycue.android.platform.location

import android.content.Context
import com.daycue.android.domain.location.GeoMonitoredPlace
import java.time.Instant

/**
 * 围栏注册表的本机快照。
 *
 * 为什么需要持久化：进程被杀之后重新起来时，「系统里还挂着哪些围栏、上次进入是几点」
 * 必须还能读到，否则注册对账会以为什么都没注册（于是漏注册），
 * 或者把一次停留的起始时刻当成「现在」（于是停留时长永远算不对）。
 *
 * 只存围栏本身需要的四项与进入时刻，不存任何轨迹点。
 */
internal class GeoMonitorStateStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun monitoredPlaceIds(): Set<String> = prefs.getStringSet(KEY_MONITORED, emptySet())?.toSet() ?: emptySet()

    fun markMonitored(placeId: String, latitude: Double, longitude: Double, radiusMeters: Double) {
        prefs.edit()
            .putStringSet(KEY_MONITORED, monitoredPlaceIds() + placeId)
            .putString(placeKey(placeId), latitude.toString() + "," + longitude + "," + radiusMeters)
            .apply()
    }

    fun unmarkMonitored(placeId: String) {
        prefs.edit()
            .putStringSet(KEY_MONITORED, monitoredPlaceIds() - placeId)
            .remove(placeKey(placeId))
            .remove(insideKey(placeId))
            .apply()
    }

    fun clearMonitored() {
        prefs.edit().clear().apply()
    }

    /** 读回围栏参数；没有注册过或数据坏掉时返回 null，绝不返回一个瞎猜的坐标。 */
    fun fence(placeId: String): GeoMonitoredPlace? {
        val raw = prefs.getString(placeKey(placeId), null) ?: return null
        val parts = raw.split(",")
        if (parts.size != 3) return null
        val latitude = parts[0].toDoubleOrNull() ?: return null
        val longitude = parts[1].toDoubleOrNull() ?: return null
        val radius = parts[2].toDoubleOrNull() ?: return null
        return GeoMonitoredPlace(id = placeId, latitude = latitude, longitude = longitude, radiusMeters = radius)
    }

    fun insideSince(placeId: String): Instant? {
        val raw = prefs.getString(insideKey(placeId), null) ?: return null
        return raw.toLongOrNull()?.let { Instant.ofEpochMilli(it) }
    }

    fun setInsideSince(placeId: String, at: Instant?) {
        val editor = prefs.edit()
        if (at == null) editor.remove(insideKey(placeId)) else editor.putString(insideKey(placeId), at.toEpochMilli().toString())
        editor.apply()
    }

    private fun placeKey(placeId: String) = "fence." + placeId

    private fun insideKey(placeId: String) = "inside." + placeId

    private companion object {
        const val PREFS_NAME = "daycue_geo_monitor"
        const val KEY_MONITORED = "monitored"
    }
}
