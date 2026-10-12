package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.data.local.dao.GeoRuleDao
import com.daycue.android.data.local.dao.PlaceDao
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.data.local.entity.PlaceRecord
import com.daycue.android.domain.location.GeoPlaceSpec
import com.daycue.android.domain.location.GeoRuleCatalog
import com.daycue.android.domain.location.GeoRuleSpec
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.domain.model.PlaceTrigger
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.LocalTime

/**
 * 地点与位置规则仓储。
 *
 * 一条硬约束：定位不可用时，规则**不得**被静默忽略——要么明确禁用并在界面上说明原因，
 * 要么不创建。绝不允许用陈旧坐标或 (0,0) 触发「你到图书馆了」这样的判断。
 *
 * 同时它是 GeoRuleCatalog 的生产实现：地点规则链路的编排层（GeoProactiveCoordinator）
 * 只通过那个接口读规则与地点，因此换掉 Room 也不会动到判定逻辑。
 */
class PlaceRepository(
    private val placeDao: PlaceDao,
    private val geoRuleDao: GeoRuleDao,
    private val timeSource: TimeSource = SystemTimeSource,
) : GeoRuleCatalog {

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
        availability: LocationCapability,
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
    override suspend fun syncAvailability(
        capability: LocationCapability,
        previouslyEnabledRuleIds: Set<String>,
    ): Int {
        val now = timeSource.now()
        var changed = 0
        val all = geoRuleDao.listAll()
        for (rule in all) {
            val shouldBeEnabled = capability.isUsable && rule.id in previouslyEnabledRuleIds
            if (rule.enabled != shouldBeEnabled) {
                geoRuleDao.setEnabled(rule.id, shouldBeEnabled, now)
                changed += 1
            }
        }
        return changed
    }

    // ---- GeoRuleCatalog：给编排层用的领域视图 ----
    // 注意：这里刻意不保留「返回 Room 实体」的 allRules()。同一个方法名不可能既返回实体又返回
    // 领域视图，而编排层必须拿到领域视图；需要实体时请用 observeRules() 或下面的 DAO 直读。

    override suspend fun rulesForEvaluation(): List<GeoRuleSpec> = geoRuleDao.listEnabled().map { it.toSpec() }

    override suspend fun allRules(): List<GeoRuleSpec> = geoRuleDao.listAll().map { it.toSpec() }

    override suspend fun placesById(): Map<String, GeoPlaceSpec> =
        placeDao.listAll().associate { it.id to it.toSpec() }

    /**
     * 实体 -> 领域视图。
     *
     * 领域层不引入 Room 实体，所以换算只发生在这一处；少一处换算就少一处双端 / 双层的字段漂移。
     */
    private fun GeoRuleRecord.toSpec() = GeoRuleSpec(
        id = id,
        placeId = placeId,
        trigger = trigger,
        title = title,
        body = body,
        minDwellSeconds = minDwellSeconds,
        cooldownSeconds = cooldownSeconds,
        activeFromLocal = activeFromLocal,
        activeToLocal = activeToLocal,
        weekdays = weekdays,
        enabled = enabled,
        expiresAt = expiresAtUtc,
    )

    private fun PlaceRecord.toSpec() = GeoPlaceSpec(
        id = id,
        name = name,
        latitude = latitude,
        longitude = longitude,
        radiusMeters = radiusMeters,
        confirmedByUser = confirmedByUser,
        deleted = deletedAt != null,
    )
}
