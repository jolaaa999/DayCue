package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.data.local.dao.GeoRuleDao
import com.daycue.android.data.local.dao.PlaceDao
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.data.local.entity.PlaceRecord
import com.daycue.android.domain.model.PlaceTrigger
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.LocalTime

/** 定位能力状态。必须显式表达「不可用」，而不是用 0,0 假装有位置。 */
enum class LocationAvailability(val displayName: String) {
    AVAILABLE("定位可用"),
    PERMISSION_DENIED("未授予定位权限"),
    PROVIDER_DISABLED("系统定位服务已关闭"),
    HARDWARE_MISSING("本机没有定位硬件"),
    UNSUPPORTED("当前设备不支持定位能力"),
    ;

    val isUsable: Boolean get() = this == AVAILABLE
}

/**
 * 地点与位置规则仓储。
 *
 * 一条硬约束：定位不可用时，规则**不得**被静默忽略——要么明确禁用并在界面上说明原因，
 * 要么不创建。绝不允许用陈旧坐标或 (0,0) 触发「你到图书馆了」这样的判断。
 */
class PlaceRepository(
    private val placeDao: PlaceDao,
    private val geoRuleDao: GeoRuleDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    fun observePlaces(): Flow<List<PlaceRecord>> = placeDao.observeActive()

    fun observeRules(): Flow<List<GeoRuleRecord>> = geoRuleDao.observeAll()

    suspend fun findPlace(id: String): PlaceRecord? = placeDao.findById(id)

    /** 只有用户确认过的地点才允许参与自动触发，所以 confirmedByUser 不是可选装饰。 */
    suspend fun createConfirmedPlace(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        address: String? = null,
    ): String {
        require(latitude in -90.0..90.0) { "纬度必须在 -90..90" }
        require(longitude in -180.0..180.0) { "经度必须在 -180..180" }
        require(radiusMeters > 0) { "半径必须为正数" }
        val now = timeSource.now()
        val id = DayCueId.new()
        placeDao.insert(
            PlaceRecord(
                id = id,
                name = name.trim(),
                latitude = latitude,
                longitude = longitude,
                radiusMeters = radiusMeters,
                address = address,
                confirmedByUser = true,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    suspend fun upsertRule(
        placeId: String,
        trigger: PlaceTrigger,
        title: String,
        availability: LocationAvailability,
        body: String? = null,
        minDwellSeconds: Int = 0,
        cooldownSeconds: Int = 3600,
        weekdays: List<Int> = emptyList(),
        activeFrom: LocalTime? = null,
        activeTo: LocalTime? = null,
        expiresAt: Instant? = null,
        ruleId: String = DayCueId.new(),
    ): GeoRuleRecord {
        val now = timeSource.now()
        // 建规则时就要求能定位：否则用户以为设好了，实际永远不会触发。
        val enabled = availability.isUsable
        val record = GeoRuleRecord(
            id = ruleId,
            placeId = placeId,
            trigger = trigger,
            title = title,
            body = body ?: if (enabled) null else "定位不可用（" + availability.displayName + "），这条规则已暂停",
            minDwellSeconds = minDwellSeconds,
            cooldownSeconds = cooldownSeconds,
            activeFromLocal = activeFrom,
            activeToLocal = activeTo,
            weekdays = weekdays,
            enabled = enabled,
            expiresAtUtc = expiresAt,
            createdAt = now,
            updatedAt = now,
        )
        geoRuleDao.insert(record)
        return record
    }

    suspend fun setEnabled(ruleId: String, enabled: Boolean) =
        geoRuleDao.setEnabled(ruleId, enabled, timeSource.now())

    suspend fun enabledRulesFor(placeId: String): List<GeoRuleRecord> = geoRuleDao.listEnabledForPlace(placeId)

    suspend fun listConfirmedPlaces(): List<PlaceRecord> = placeDao.listConfirmed()

    suspend fun deletePlace(placeId: String) = placeDao.softDelete(placeId, timeSource.now())

    suspend fun deleteRule(ruleId: String) = geoRuleDao.softDelete(ruleId, timeSource.now())

    /**
     * 定位能力变化时调用。
     *
     * 不可用 → 全部暂停；恢复可用 → 只把用户此前确实开着的规则放回来。
     * 为什么不「一恢复就全开」：暂停可能是用户自己关的，能力恢复不该改变用户的决定。
     */
    suspend fun syncAvailability(availability: LocationAvailability, previouslyEnabledRuleIds: Set<String>): Int {
        val now = timeSource.now()
        var changed = 0
        val all = geoRuleDao.listAll()
        for (rule in all) {
            val shouldBeEnabled = availability.isUsable && rule.id in previouslyEnabledRuleIds
            if (rule.enabled != shouldBeEnabled) {
                geoRuleDao.setEnabled(rule.id, shouldBeEnabled, now)
                changed += 1
            }
        }
        return changed
    }

    suspend fun allRules(): List<GeoRuleRecord> = geoRuleDao.listAll()
}
