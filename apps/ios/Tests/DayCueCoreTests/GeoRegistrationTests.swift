import Foundation
import XCTest
@testable import DayCueCore

/// 地点监控注册对账测试（纯逻辑，不需要数据库）。
///
/// 状态：已编写、未运行（本机没有 Swift 工具链）。
/// 这里验证的是「该注册谁、该取消谁、为什么不会触发」的编排，
/// 不代表 CLLocationManager 在真机上真的注册成功了。
final class GeoRegistrationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makePlace(id: String, confirmed: Bool = true, deletedAt: String? = nil) -> PlaceRecord {
        PlaceRecord(
            id: id,
            name: "地点 " + id,
            latitude: 31.2304,
            longitude: 121.4737,
            radiusMeters: 200,
            address: nil,
            confirmedByUser: confirmed,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z",
            deletedAt: deletedAt
        )
    }

    private func makeRule(
        id: String,
        placeId: String,
        enabled: Bool = true,
        deletedAt: String? = nil
    ) -> GeoRuleRecord {
        GeoRuleRecord(
            id: id,
            placeId: placeId,
            trigger: .enter,
            title: "规则 " + id,
            body: nil,
            minDwellSeconds: 0,
            cooldownSeconds: 0,
            activeFromLocal: nil,
            activeToLocal: nil,
            weekdays: nil,
            enabled: enabled,
            expiresAtUTC: nil,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z",
            deletedAt: deletedAt
        )
    }

    func testOnlyActiveConfirmedRulesAreDesired() {
        let places = [
            "place_ok": makePlace(id: "place_ok"),
            "place_unconfirmed": makePlace(id: "place_unconfirmed", confirmed: false)
        ]
        let rules = [
            makeRule(id: "rule_ok", placeId: "place_ok"),
            makeRule(id: "rule_off", placeId: "place_ok", enabled: false),
            makeRule(id: "rule_unconfirmed", placeId: "place_unconfirmed")
        ]

        let plan = GeoRegistrationPlanner.plan(
            rules: rules,
            placesById: places,
            capability: .available,
            currentlyMonitoredPlaceIds: [],
            now: now
        )

        XCTAssertEqual(plan.desiredPlaceIds, ["place_ok"])
        XCTAssertEqual(plan.placesToStartMonitoring.map { $0.id }, ["place_ok"])
        XCTAssertTrue(plan.placeIdsToStopMonitoring.isEmpty)
    }

    func testCapabilityLossStopsEveryRegistrationAndExplainsWhy() {
        let places = ["place_ok": makePlace(id: "place_ok")]
        let rules = [makeRule(id: "rule_ok", placeId: "place_ok")]

        let plan = GeoRegistrationPlanner.plan(
            rules: rules,
            placesById: places,
            capability: .denied,
            currentlyMonitoredPlaceIds: ["place_ok"],
            now: now
        )

        XCTAssertTrue(plan.desiredPlaceIds.isEmpty)
        XCTAssertEqual(plan.placeIdsToStopMonitoring, ["place_ok"], "没有权限就必须取消旧注册，不能留着野注册")
        XCTAssertTrue(plan.placesToStartMonitoring.isEmpty)

        XCTAssertEqual(plan.readiness.count, 1)
        XCTAssertFalse(plan.readiness[0].isActive)
        XCTAssertTrue(plan.readiness[0].blockingReason?.contains("权限") ?? false, "降级必须给出原因，不能显示成正常")
    }

    func testDeletedRuleStopsPlaceAndExplainsWhy() {
        let places = ["place_ok": makePlace(id: "place_ok")]
        let rules = [makeRule(id: "rule_deleted", placeId: "place_ok", deletedAt: "2026-10-02T00:00:00Z")]

        let plan = GeoRegistrationPlanner.plan(
            rules: rules,
            placesById: places,
            capability: .available,
            currentlyMonitoredPlaceIds: ["place_ok"],
            now: now
        )

        XCTAssertEqual(plan.placeIdsToStopMonitoring, ["place_ok"], "规则删除后旧注册必须被取消")
        XCTAssertFalse(plan.readiness[0].isActive)
        XCTAssertTrue((plan.readiness[0].blockingReason ?? "").contains("删除"))
    }

    func testMissingOrUnconfirmedPlaceIsBlockedWithReason() {
        let rules = [
            makeRule(id: "rule_missing", placeId: "place_missing"),
            makeRule(id: "rule_unconfirmed", placeId: "place_unconfirmed")
        ]
        let places = ["place_unconfirmed": makePlace(id: "place_unconfirmed", confirmed: false)]

        let plan = GeoRegistrationPlanner.plan(
            rules: rules,
            placesById: places,
            capability: .available,
            currentlyMonitoredPlaceIds: [],
            now: now
        )

        XCTAssertTrue(plan.desiredPlaceIds.isEmpty)
        XCTAssertTrue((plan.readiness[0].blockingReason ?? "").contains("不存在"))
        XCTAssertTrue((plan.readiness[1].blockingReason ?? "").contains("确认"))
    }

    func testForegroundOnlyKeepsRuleActiveWithLimitation() {
        let places = ["place_ok": makePlace(id: "place_ok")]
        let rules = [makeRule(id: "rule_ok", placeId: "place_ok")]

        let plan = GeoRegistrationPlanner.plan(
            rules: rules,
            placesById: places,
            capability: .foregroundOnly,
            currentlyMonitoredPlaceIds: [],
            now: now
        )

        XCTAssertEqual(plan.desiredPlaceIds, ["place_ok"], "只有前台权限时规则仍然生效")
        XCTAssertTrue(plan.readiness[0].isActive)
        XCTAssertNil(plan.readiness[0].blockingReason)
        XCTAssertNotNil(plan.readiness[0].limitationReason, "但要如实说明 App 没打开时收不到")
        XCTAssertTrue(plan.readiness[0].displayText.contains("边界"))
    }

    func testReadinessDisplayTextShowsBlockingReason() {
        let rule = makeRule(id: "rule_off", placeId: "place_ok", enabled: false)
        let status = GeoRuleReadinessEvaluator.evaluate(
            rule: rule,
            place: makePlace(id: "place_ok"),
            capability: .available,
            now: now
        )
        XCTAssertFalse(status.isActive)
        XCTAssertTrue(status.displayText.contains("当前不会触发"))
        XCTAssertTrue(status.displayText.contains("关闭"))
    }
}
