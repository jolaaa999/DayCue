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
import com.daycue.android.domain.model.CoordinateSystem
import com.daycue.android.domain.model.PlaceTrigger
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.LocalTime

/**
 * 地点链路对「规则集合变了」这件事的接收口。
 *
 * 为什么单独抽一个窄接口而不是让界面直接拿 GeoProactiveCoordinator：
 * 界面只需要「重新注册」与「取消这些规则的待发通知」两件事，
 * 依赖整个协调器会让 ViewModel 的单元测试必须构造六七个替身（ledger、notifier、source…），
 * 而真正要断言的行为只有「有没有调用」——窄接口让这件事在 JVM 上一条用例就能证明。
 * 生产实现在 AppContainer：GeoProactiveCoordinator 自适应实现它。
 */
interface GeoRuleChangeListener {

    /**
     * 规则 / 地点增删改之后重新对账注册（围栏 + 停留复查 + 权限同步都在里面）。
     *
     * 不带时刻参数：界面关心的是「现在重新对账」，「现在」由协调器自己的时钟给出。
     * 需要固定时刻的测试直接用具体类型的那两个重载。
     */
    suspend fun onRuleChanged()

    /** 规则被删除：先取消它们已经排上的通知，再重新对账。 */
    suspend fun onRulesRemoved(ruleIds: List<String>)
}

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

    suspend fun findRule(id: String): GeoRuleRecord? = geoRuleDao.findById(id)

    /**
     * 新建一个用户确认过的地点。
     *
     * coordinateSystem 没有默认值：默认值会把「调用方忘了传」伪装成「确实是 WGS84」，
     * 而这正是坐标系这一列存在的意义——将来接入 GCJ-02 取点来源时，两类数据必须一眼可分。
     *
     * 校验放在仓储而不是界面：界面只是入口之一，围栏注册读的是库里的值，
     * 一条经度 200 的记录会被系统围栏直接拒绝注册，表现出来就是「规则开着但永远不响」。
     */
    suspend fun createConfirmedPlace(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        coordinateSystem: CoordinateSystem,
        address: String? = null,
    ): String {
        require(name.isNotBlank()) { "地点名称不能为空" }
        require(latitude in -90.0..90.0) { "纬度必须在 -90..90" }
        require(longitude in -180.0..180.0) { "经度必须在 -180..180" }
        require(radiusMeters > 0) { "半径必须为正数" }
        require(!latitude.isNaN() && !longitude.isNaN() && !radiusMeters.isNaN()) { "坐标与半径必须是有效数字" }
        val now = timeSource.now()
        val id = DayCueId.new()
        placeDao.insert(
            PlaceRecord(
                id = id,
                name = name.trim(),
                latitude = latitude,
                longitude = longitude,
                radiusMeters = radiusMeters,
                address = address?.trim()?.takeIf { it.isNotEmpty() },
                coordinateSystem = coordinateSystem,
                confirmedByUser = true,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    /**
     * 新建或更新一条地点规则。
     *
     * ruleId 的默认值是**新建语义**（生成一个新 id）；编辑必须显式传入既有 id，
     * 因为 upsertRule 是 @Insert(ABORT)，传新 id 就会在库里多出一条规则，
     * 而那条新规则会以同一个 dedupe_key 前缀重新注册围栏——表现为「改一次规则，收到两份提醒」。
     * 编辑路径由 GeoRuleDao.findById 读回 createdAt，不让「创建时间」被一次编辑改写。
     *
     * enabled 是用户在这个界面上的意图，但还是会被能力再夹一次：
     * 定位不可用时规则必须落成「已暂停」并写明原因，不能显示成正常运行。
     */
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
        enabled: Boolean = true,
        linkedTaskId: String? = null,
    ): GeoRuleRecord {
        require(title.isNotBlank()) { "规则标题不能为空" }
        // 停留时长只对「停留」有意义：其余触发条件置 0，否则界面上会出现一个永远不参与判定的秒数。
        val dwell = if (trigger == PlaceTrigger.DWELL) minDwellSeconds else 0
        require(dwell >= 0) { "最短停留秒数不能为负" }
        require(cooldownSeconds >= 0) { "冷却秒数不能为负" }
        require(weekdays.all { it in 1..7 }) { "生效星期取值必须在 1..7 之间" }
        // 先确认地点真的存在且是用户确认过的：geo_rule 有指向 place 的外键，
        // 指向不存在的地点会让插入直接抛 SQLiteConstraintException（用户看到的是一个英文堆栈），
        // 指向未确认的地点则会静默生成一条永远不会触发的规则。
        val place = placeDao.findById(placeId)
        requireNotNull(place) { "规则必须挂在一个已存在的地点上" }
        require(place.confirmedByUser) { "这个地点还没有被用户确认，不能为它建规则" }
        val now = timeSource.now()

        val existing = geoRuleDao.findById(ruleId)
        val usable = availability.isUsable && enabled
        val record = GeoRuleRecord(
            id = ruleId,
            placeId = placeId,
            trigger = trigger,
            title = title.trim(),
            body = body?.trim()?.takeIf { it.isNotEmpty() }
                ?: if (usable) null else "定位不可用（" + availability.displayName + "），这条规则已暂停",
            minDwellSeconds = dwell,
            cooldownSeconds = cooldownSeconds,
            activeFromLocal = activeFrom,
            activeToLocal = activeTo,
            weekdays = weekdays.distinct().sorted(),
            enabled = usable,
            linkedTaskId = linkedTaskId?.takeIf { it.isNotBlank() },
            expiresAtUtc = expiresAt,
            createdAt = existing?.createdAt ?: now,
            updatedAt = now,
            deletedAt = null,
        )
        geoRuleDao.insert(record)
        return record
    }

    suspend fun setEnabled(ruleId: String, enabled: Boolean) =
        geoRuleDao.setEnabled(ruleId, enabled, timeSource.now())

    suspend fun enabledRulesFor(placeId: String): List<GeoRuleRecord> = geoRuleDao.listEnabledForPlace(placeId)

    suspend fun listConfirmedPlaces(): List<PlaceRecord> = placeDao.listConfirmed()

    /**
     * 更新一个已有地点（名称 / 坐标 / 半径 / 地址）。
     *
     * 与 createConfirmedPlace 一样在这里做校验：改半径是最容易出错的入口
     * （用户把半径删空、或滑到 0），落库前必须挡住。
     */
    suspend fun updatePlace(place: PlaceRecord): PlaceRecord {
        require(place.name.isNotBlank()) { "地点名称不能为空" }
        require(place.latitude in -90.0..90.0) { "纬度必须在 -90..90" }
        require(place.longitude in -180.0..180.0) { "经度必须在 -180..180" }
        require(place.radiusMeters > 0) { "半径必须为正数" }
        val updated = place.copy(
            name = place.name.trim(),
            address = place.address?.trim()?.takeIf { it.isNotEmpty() },
            updatedAt = timeSource.now(),
        )
        placeDao.update(updated)
        return updated
    }

    /** 删除地点下的全部规则。编辑 / 删除地点时必须先撤掉这些规则，见 deletePlace。 */
    suspend fun rulesForPlace(placeId: String): List<GeoRuleRecord> = geoRuleDao.listForPlace(placeId)

    /**
     * 删除地点。
     *
     * 必须**同时**软删除它下面的规则，不能只靠外键 CASCADE：
     * CASCADE 只在物理 DELETE 时触发，而这里是软删除（行还在，只置 deleted_at），
     * 于是规则会留下来指向一个已删地点，界面上表现为一条「地点已不存在」的僵尸规则。
     *
     * 返回被一起删掉的规则 id，调用方要拿它去取消已经排上的通知。
     */
    suspend fun deletePlace(placeId: String): List<String> {
        val now = timeSource.now()
        val rules = geoRuleDao.listForPlace(placeId)
        for (rule in rules) {
            geoRuleDao.softDelete(rule.id, now)
        }
        placeDao.softDelete(placeId, now)
        return rules.map { it.id }
    }

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
        linkedTaskId = linkedTaskId,
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
