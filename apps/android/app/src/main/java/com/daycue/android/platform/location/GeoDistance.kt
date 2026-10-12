package com.daycue.android.platform.location

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 球面距离。
 *
 * 自己实现而不是用 android.location.Location.distanceBetween：后者是平台静态方法，
 * 在纯 JVM 单元测试里只会返回默认值（数组不被写入），于是「在不在围栏内」的判断
 * 在测试里会静默变成「永远在围栏内」。这段几何逻辑必须能被真实断言。
 *
 * 用 haversine 而不是等距圆柱投影：围栏半径可能只有 100 米，
 * 投影法在城市尺度下的误差足以把「在楼下」判成「不在」。
 */
internal object GeoDistance {

    private const val EARTH_RADIUS_METERS = 6_371_000.0

    fun meters(latitudeA: Double, longitudeA: Double, latitudeB: Double, longitudeB: Double): Double {
        val lat1 = Math.toRadians(latitudeA)
        val lat2 = Math.toRadians(latitudeB)
        val deltaLat = Math.toRadians(latitudeB - latitudeA)
        val deltaLon = Math.toRadians(longitudeB - longitudeA)
        val a = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * EARTH_RADIUS_METERS * asin(min(1.0, sqrt(a)))
    }
}
