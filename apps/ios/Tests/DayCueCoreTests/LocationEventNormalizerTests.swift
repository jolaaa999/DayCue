import Foundation
import XCTest
@testable import DayCueCore

/// 位置事件标准化与新鲜度判定测试。
///
/// 状态：已编写、未运行（本机没有 Swift 工具链）。
/// 这里验证的是编排逻辑，不是设备行为：没有真机、没有 CLLocationManager，
/// 适配层把 CLLocation 拆成标量之后的一切都由这些用例覆盖。
final class LocationEventNormalizerTests: XCTestCase {

    /// 固定基准时刻，避免任何用例依赖执行日期。
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func observation(
        kind: LocationEventKind = .entered,
        observedAt: Date? = nil,
        accuracy: Double = 20,
        capability: LocationCapability = .available,
        now: Date? = nil
    ) -> RawLocationObservation {
        let resolvedNow = now ?? base
        return RawLocationObservation(
            placeId: "place_1",
            kind: kind,
            observedAt: observedAt ?? resolvedNow.addingTimeInterval(-5),
            horizontalAccuracyMeters: accuracy,
            capability: capability,
            now: resolvedNow
        )
    }

    // MARK: - 通过

    func testFreshObservationIsAcceptedWithSemanticFields() throws {
        let result = LocationEventNormalizer.normalize(observation())
        XCTAssertTrue(result.isAccepted)

        let event = try XCTUnwrap(result.event)
        XCTAssertEqual(event.placeId, "place_1")
        XCTAssertEqual(event.trigger, .enter)
        XCTAssertEqual(event.transition, GeoRegionTransition(previous: .outside, current: .inside))
        XCTAssertNil(event.insideSince)
        XCTAssertEqual(event.horizontalAccuracyMeters, 20)
    }

    func testDwellEventCarriesInsideSince() throws {
        let since = base.addingTimeInterval(-600)
        let result = LocationEventNormalizer.normalize(observation(kind: .dwell(insideSince: since)))

        let event = try XCTUnwrap(result.event)
        XCTAssertEqual(event.trigger, .dwell)
        XCTAssertEqual(event.insideSince, since)
        XCTAssertEqual(event.transition, GeoRegionTransition(previous: .inside, current: .inside))
    }

    func testExitEventImpliesInsideToOutside() throws {
        let result = LocationEventNormalizer.normalize(observation(kind: .exited))
        let event = try XCTUnwrap(result.event)
        XCTAssertEqual(event.trigger, .exit)
        XCTAssertEqual(event.transition, GeoRegionTransition(previous: .inside, current: .outside))
    }

    // MARK: - 陈旧

    func testStaleObservationIsDiscardedWithReason() {
        let result = LocationEventNormalizer.normalize(
            observation(observedAt: base.addingTimeInterval(-600))
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertNil(result.event)
        XCTAssertTrue(result.isSilent, "位置不可信属于静默降级")
        let reason = result.discardReason ?? ""
        XCTAssertTrue(reason.contains("太旧"), "必须说明为什么丢弃，实际是：\(reason)")
    }

    func testFutureTimestampIsDiscardedAsClockAnomaly() {
        let result = LocationEventNormalizer.normalize(
            observation(observedAt: base.addingTimeInterval(300))
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue((result.discardReason ?? "").contains("时钟"))
    }

    func testFreshnessPolicyIsRespected() {
        // 把上限收紧到 10 秒，同一份「20 秒前」的观测就从合格变成陈旧。
        let policy = LocationFreshnessPolicy(
            maximumAgeSeconds: 10,
            maximumHorizontalAccuracyMeters: 150,
            maximumFutureSkewSeconds: 30
        )
        let result = LocationEventNormalizer.normalize(
            observation(observedAt: base.addingTimeInterval(-20)),
            policy: policy
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue((result.discardReason ?? "").contains("上限 10 秒"))
    }

    // MARK: - 精度

    func testPoorAccuracyIsDiscardedWithReason() {
        let result = LocationEventNormalizer.normalize(observation(accuracy: 900))
        XCTAssertFalse(result.isAccepted)
        XCTAssertNil(result.event)
        XCTAssertTrue((result.discardReason ?? "").contains("精度"), "实际是：\(result.discardReason ?? "")")
    }

    func testMissingAccuracyIsDiscarded() {
        let result = LocationEventNormalizer.normalize(observation(accuracy: 0))
        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue((result.discardReason ?? "").contains("精度"))
    }

    func testNonFiniteAccuracyIsDiscarded() {
        let result = LocationEventNormalizer.normalize(observation(accuracy: Double.nan))
        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue((result.discardReason ?? "").contains("精度"))
    }

    // MARK: - 未知状态

    func testIndeterminateKindIsDiscardedAndNeverBecomesOutside() {
        let result = LocationEventNormalizer.normalize(
            observation(kind: .indeterminate(reason: "区域状态未知"))
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertNil(result.event)
        let reason = result.discardReason ?? ""
        XCTAssertTrue(reason.contains("无法确定"), "实际是：\(reason)")
        XCTAssertTrue(reason.contains("区域状态未知"), "要带上系统的原始原因")
    }

    // MARK: - 能力不可用

    func testDeniedCapabilityIsReportedAndProducesNoEvent() {
        let result = LocationEventNormalizer.normalize(observation(capability: .denied))
        XCTAssertFalse(result.isAccepted)
        XCTAssertNil(result.event)
        XCTAssertTrue(result.isSilent)
        XCTAssertTrue((result.discardReason ?? "").contains("权限"))
    }

    func testServicesDisabledIsReportedDistinctlyFromDenied() {
        let denied = LocationEventNormalizer.normalize(observation(capability: .denied)).discardReason ?? ""
        let disabled = LocationEventNormalizer.normalize(observation(capability: .servicesDisabled)).discardReason ?? ""

        XCTAssertNotEqual(denied, disabled, "两种情况对用户的下一步操作不同，不能给同一句话")
        XCTAssertTrue(disabled.contains("定位服务"))
        XCTAssertTrue(denied.contains("权限"))
    }

    func testCapabilityUsabilityAndLimitations() {
        XCTAssertTrue(LocationCapability.available.isUsable)
        XCTAssertTrue(LocationCapability.foregroundOnly.isUsable, "只有前台权限仍然能触发，只是有边界")
        XCTAssertFalse(LocationCapability.denied.isUsable)
        XCTAssertFalse(LocationCapability.restricted.isUsable)
        XCTAssertFalse(LocationCapability.servicesDisabled.isUsable)
        XCTAssertFalse(LocationCapability.notDetermined.isUsable)
        XCTAssertFalse(LocationCapability.failed(reason: "注册失败").isUsable)

        XCTAssertNil(LocationCapability.available.unavailableReason)
        XCTAssertNotNil(LocationCapability.denied.unavailableReason)
        XCTAssertNotNil(LocationCapability.foregroundOnly.limitationReason)
        XCTAssertNil(LocationCapability.available.limitationReason)
    }
}
