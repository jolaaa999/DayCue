package com.daycue.android.domain.location

import java.time.Instant

/**
 * 注册监控需要的地点信息。
 *
 * 只带围栏必需的四项：坐标、半径、以及「是否被用户确认」。
 * 未确认的坐标只是草稿，不参与触发——这是 PlaceRepository 里那条硬约束的领域层表达。
 */
data class GeoMonitoredPlace(
    val id: String,
    val latitude: Double,
    val longitude: Double,
    val radiusMeters: Double,
)

/** 规则判定需要的地点视图，比 GeoMonitoredPlace 多带展示与确认状态。 */
data class GeoPlaceSpec(
    val id: String,
    val name: String,
    val latitude: Double,
    val longitude: Double,
    val radiusMeters: Double,
    val confirmedByUser: Boolean,
    val deleted: Boolean,
)

/**
 * 一条规则当前的可触发状态。
 *
 * 界面据此如实展示「这条规则现在会不会触发、为什么」，
 * 而不是在定位被撤销之后还显示成正常运行的绿色开关。
 */
data class GeoRuleReadiness(
    val ruleId: String,
    val placeId: String,
    val isActive: Boolean,
    /** 当前不会触发的中文原因；isActive 为 true 时为 null。 */
    val blockingReason: String?,
    /** 仍然会触发，但能力有边界（当前 Android 端没有这类状态，保留字段以便将来扩展）。 */
    val limitationReason: String?,
) {
    /** 给用户看的一句话。生效时也明确说「可以触发」，而不是留空让人猜。 */
    val displayText: String
        get() = when {
            blockingReason != null -> "当前不会触发：" + blockingReason
            limitationReason != null -> "可以触发，但有边界：" + limitationReason
            else -> "可以触发。"
        }
}

/**
 * 规则可触发性的判定。
 *
 * 判定顺序与 GeoRuleEvaluator 保持一致（先环境、再规则自身、最后地点），
 * 这样界面上的「为什么不会触发」与实际判定用的理由是同一套口径。
 */
object GeoRuleReadinessEvaluator {

    fun evaluate(
        rule: GeoRuleSpec,
        place: GeoPlaceSpec?,
        capability: LocationCapability,
        locationRulesEnabled: Boolean,
        now: Instant,
    ): GeoRuleReadiness {

        fun blocked(reason: String) = GeoRuleReadiness(
            ruleId = rule.id,
            placeId = rule.placeId,
            isActive = false,
            blockingReason = reason,
            limitationReason = null,
        )

        // 1. 用户总开关。位置是敏感能力，用户关掉就是关掉，不能靠「规则还是 enabled」推断。
        if (!locationRulesEnabled) {
            return blocked("位置规则总开关未打开。")
        }

        // 2. 环境。定位不可用时，任何地点规则都不可能在正常工作。
        capability.unavailableReason?.let { return blocked(it) }

        // 3. 规则自身。
        if (!rule.enabled) {
            return blocked("这条地点规则已被关闭。")
        }
        if (rule.expiresAt != null && !now.isBefore(rule.expiresAt)) {
            return blocked("这条地点规则已经过期。")
        }

        // 4. 地点必须存在且被用户确认过。
        if (place == null) {
            return blocked("规则对应的地点已不存在，先重新选择地点。")
        }
        if (place.deleted) {
            return blocked("规则对应的地点已经删除。")
        }
        if (!place.confirmedByUser) {
            return blocked("这个地点还没有被确认，规则不会触发。")
        }

        return GeoRuleReadiness(
            ruleId = rule.id,
            placeId = rule.placeId,
            isActive = true,
            blockingReason = null,
            limitationReason = null,
        )
    }
}

/** 注册对账计划。 */
data class GeoRegistrationPlan(
    /** 需要新注册监控的地点（按 id 排序，便于断言与日志比对）。 */
    val placesToStartMonitoring: List<GeoMonitoredPlace>,
    /** 需要停止监控的地点 id。 */
    val placeIdsToStopMonitoring: List<String>,
    /** 每条规则的可触发状态。 */
    val readiness: List<GeoRuleReadiness>,
    /** 本轮之后应当处于监控中的地点 id。 */
    val desiredPlaceIds: List<String>,
    val capability: LocationCapability,
    val locationRulesEnabled: Boolean,
)

/**
 * 地点监控注册的对账。
 *
 * 单独一层的理由：注册表与规则表是两份状态。规则被改、被删、权限被撤销时，
 * 如果没人把「应该监控的地点集合」和「实际已注册集合」对一次账，就会留下野注册——
 * 用户删掉的规则仍然会在后台触发提醒，这是最难排查的一类问题。
 */
object GeoRegistrationPlanner {

    fun plan(
        rules: List<GeoRuleSpec>,
        placesById: Map<String, GeoPlaceSpec>,
        capability: LocationCapability,
        locationRulesEnabled: Boolean,
        currentlyMonitoredPlaceIds: Set<String>,
        now: Instant,
    ): GeoRegistrationPlan {

        val readiness = ArrayList<GeoRuleReadiness>()
        val desired = LinkedHashSet<String>()

        for (rule in rules) {
            val status = GeoRuleReadinessEvaluator.evaluate(
                rule = rule,
                place = placesById[rule.placeId],
                capability = capability,
                locationRulesEnabled = locationRulesEnabled,
                now = now,
            )
            readiness += status
            if (status.isActive) desired += rule.placeId
        }

        val toStart = desired.filter { it !in currentlyMonitoredPlaceIds }.sorted()
        val toStop = currentlyMonitoredPlaceIds.filter { it !in desired }.sorted()

        return GeoRegistrationPlan(
            placesToStartMonitoring = toStart.mapNotNull { placeId ->
                placesById[placeId]?.let {
                    GeoMonitoredPlace(
                        id = it.id,
                        latitude = it.latitude,
                        longitude = it.longitude,
                        radiusMeters = it.radiusMeters,
                    )
                }
            },
            placeIdsToStopMonitoring = toStop,
            readiness = readiness,
            desiredPlaceIds = desired.sorted(),
            capability = capability,
            locationRulesEnabled = locationRulesEnabled,
        )
    }
}
