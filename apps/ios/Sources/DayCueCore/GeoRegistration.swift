import Foundation

// 地点监控注册的编排：哪些地点现在应该被监控、哪些旧注册必须取消、每条规则当前为什么不会触发。
//
// 单独一层的理由：注册表与规则表是两份状态，规则被改、被删、权限被撤销时，
// 如果没人把「应该监控的地点集合」和「实际已注册集合」对一次账，就会留下野注册——
// 用户删掉的规则仍然会在后台触发提醒，这是最难排查的一类问题。

/// 一条规则当前的可触发状态。界面据此如实展示「这条规则现在会不会触发、为什么」。
public struct GeoRuleReadiness: Equatable, Sendable {

    public var ruleId: String
    public var placeId: String
    public var isActive: Bool
    /// 当前不会触发的中文原因；isActive 为 true 时为 nil。
    public var blockingReason: String?
    /// 仍然会触发，但能力有边界（例如只有前台定位权限）。
    public var limitationReason: String?

    public init(
        ruleId: String,
        placeId: String,
        isActive: Bool,
        blockingReason: String?,
        limitationReason: String?
    ) {
        self.ruleId = ruleId
        self.placeId = placeId
        self.isActive = isActive
        self.blockingReason = blockingReason
        self.limitationReason = limitationReason
    }

    /// 给用户看的一句话。生效时也要说明能力边界，而不是只显示「正常」。
    public var displayText: String {
        if let blockingReason { return "当前不会触发：\(blockingReason)" }
        if let limitationReason { return "可以触发，但有边界：\(limitationReason)" }
        return "可以触发。"
    }
}

/// 规则可触发性的判定。
///
/// 判定顺序与 GeoRuleEvaluator 保持一致（先环境、再规则自身、最后地点），
/// 这样界面上的「为什么不会触发」与实际判定用的理由是同一套口径。
public enum GeoRuleReadinessEvaluator {

    public static func evaluate(
        rule: GeoRuleRecord,
        place: PlaceRecord?,
        capability: LocationCapability,
        now: Date
    ) -> GeoRuleReadiness {

        func blocked(_ reason: String) -> GeoRuleReadiness {
            GeoRuleReadiness(
                ruleId: rule.id,
                placeId: rule.placeId,
                isActive: false,
                blockingReason: reason,
                limitationReason: nil
            )
        }

        // 1. 环境。定位不可用时，任何地点规则都不可能在正常工作。
        if let reason = capability.unavailableReason {
            return blocked(reason)
        }

        // 2. 规则自身。
        if rule.deletedAt != nil {
            return blocked("这条地点规则已经删除。")
        }
        if !rule.enabled {
            return blocked("这条地点规则已被关闭。")
        }

        // 3. 地点必须存在且被用户确认过，未确认的坐标只是草稿。
        guard let place else {
            return blocked("规则对应的地点已不存在，先重新选择地点。")
        }
        if place.deletedAt != nil {
            return blocked("规则对应的地点已经删除。")
        }
        if !place.confirmedByUser {
            return blocked("这个地点还没有被确认，规则不会触发。")
        }

        // 4. 过期。
        if let expiresAt = rule.expiresAtUTC,
           let expiry = RFC3339.date(fromUTC: expiresAt),
           expiry <= now {
            return blocked("这条地点规则已经过期。")
        }

        return GeoRuleReadiness(
            ruleId: rule.id,
            placeId: rule.placeId,
            isActive: true,
            blockingReason: nil,
            limitationReason: capability.limitationReason
        )
    }
}

/// 注册对账计划。
public struct GeoRegistrationPlan: Equatable, Sendable {

    /// 需要新注册监控的地点（按 id 排序，便于断言与日志比对）。
    public var placesToStartMonitoring: [PlaceRecord]
    /// 需要停止监控的地点 id。
    public var placeIdsToStopMonitoring: [String]
    /// 每条规则的可触发状态。
    public var readiness: [GeoRuleReadiness]
    /// 本轮之后应当处于监控中的地点 id。
    public var desiredPlaceIds: [String]
    public var capability: LocationCapability

    public init(
        placesToStartMonitoring: [PlaceRecord],
        placeIdsToStopMonitoring: [String],
        readiness: [GeoRuleReadiness],
        desiredPlaceIds: [String],
        capability: LocationCapability
    ) {
        self.placesToStartMonitoring = placesToStartMonitoring
        self.placeIdsToStopMonitoring = placeIdsToStopMonitoring
        self.readiness = readiness
        self.desiredPlaceIds = desiredPlaceIds
        self.capability = capability
    }
}

public enum GeoRegistrationPlanner {

    /// 对账：应该监控哪些地点 vs 已经注册了哪些。
    ///
    /// 能力不可用时 desired 会被清空，于是所有旧注册都会被取消——
    /// 这正是「没有定位能力时不能假装规则在正常运行」在注册表上的落点。
    public static func plan(
        rules: [GeoRuleRecord],
        placesById: [String: PlaceRecord],
        capability: LocationCapability,
        currentlyMonitoredPlaceIds: Set<String>,
        now: Date
    ) -> GeoRegistrationPlan {

        var readiness: [GeoRuleReadiness] = []
        var desired: Set<String> = []

        for rule in rules {
            let status = GeoRuleReadinessEvaluator.evaluate(
                rule: rule,
                place: placesById[rule.placeId],
                capability: capability,
                now: now
            )
            readiness.append(status)
            if status.isActive { desired.insert(rule.placeId) }
        }

        let toStart = desired.subtracting(currentlyMonitoredPlaceIds).sorted()
        let toStop = currentlyMonitoredPlaceIds.subtracting(desired).sorted()

        return GeoRegistrationPlan(
            placesToStartMonitoring: toStart.compactMap { placesById[$0] },
            placeIdsToStopMonitoring: toStop,
            readiness: readiness,
            desiredPlaceIds: desired.sorted(),
            capability: capability
        )
    }
}
