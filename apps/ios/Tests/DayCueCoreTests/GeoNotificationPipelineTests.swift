import Foundation
import XCTest
@testable import DayCueCore

// 地点链路测试的共用替身。
//
// 这是**替身验证编排**：它只记录「安排/取消被调用了几次」，
// 不证明系统通知中心真的弹了通知，也不证明区域监控在真机上工作。

/// 记录调用次数的通知安排器替身。
final class RecordingNotifier: ProactiveNotificationScheduling {

    private(set) var scheduledRequests: [ProactiveNotificationRequest] = []
    private(set) var cancelledIdentifiers: [String] = []
    /// 非 nil 时每次安排都返回失败，用来验证失败也被如实落库。
    var failureReason: String?

    var scheduleCallCount: Int { scheduledRequests.count }
    var cancelCallCount: Int { cancelledIdentifiers.count }

    func schedule(_ request: ProactiveNotificationRequest) async -> ProactiveNotificationScheduleResult {
        scheduledRequests.append(request)
        if let failureReason {
            return .notScheduled(reason: failureReason)
        }
        return .scheduled(identifier: request.identifier, at: request.fireAt)
    }

    func cancel(identifier: String) async {
        cancelledIdentifiers.append(identifier)
    }
}

/// 测试用的临时库。每个用例一个独立目录，避免互相污染。
enum GeoTestSupport {

    static func makeStore() throws -> (store: DayCueStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daycue-geo-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try DayCueStore(baseDirectory: directory), directory)
    }

    static func cleanUp(_ directory: URL?) {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// 地点事件 -> 规则求值 -> 预算 -> 通知安排的链路测试。
///
/// 状态：已编写、未运行（本机没有 Swift 工具链）。
final class GeoNotificationPipelineTests: XCTestCase {

    private var store: DayCueStore!
    private var directory: URL!
    private let zone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = try GeoTestSupport.makeStore()
        store = made.store
        directory = made.directory
    }

    override func tearDownWithError() throws {
        store = nil
        GeoTestSupport.cleanUp(directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - 固定数据

    private func fixedDate(_ string: String) -> Date {
        guard let date = RFC3339.date(fromUTC: string) else {
            fatalError("测试用的固定时间写错了：\(string)")
        }
        return date
    }

    private func makePlace(confirmed: Bool = true) -> PlaceRecord {
        PlaceRecord(
            id: "place_1",
            name: "三教",
            latitude: 31.2304,
            longitude: 121.4737,
            radiusMeters: 200,
            address: "教学楼",
            confirmedByUser: confirmed,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z",
            deletedAt: nil
        )
    }

    private func makeRule(
        trigger: GeoRuleTrigger = .enter,
        minDwellSeconds: Int = 0,
        cooldownSeconds: Int = 0,
        enabled: Bool = true,
        expiresAtUTC: String? = nil
    ) -> GeoRuleRecord {
        GeoRuleRecord(
            id: "rule_1",
            placeId: "place_1",
            trigger: trigger,
            title: "到达三教",
            body: "别忘了打卡",
            minDwellSeconds: minDwellSeconds,
            cooldownSeconds: cooldownSeconds,
            activeFromLocal: nil,
            activeToLocal: nil,
            weekdays: nil,
            enabled: enabled,
            expiresAtUTC: expiresAtUTC,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-01T00:00:00Z",
            deletedAt: nil
        )
    }

    @discardableResult
    private func seedPlaceAndRule(
        rule: GeoRuleRecord? = nil,
        place: PlaceRecord? = nil
    ) throws -> (PlaceRecord, GeoRuleRecord) {
        let storedPlace = try store.insertPlace(place ?? makePlace())
        let storedRule = try store.insertGeoRule(rule ?? makeRule())
        return (storedPlace, storedRule)
    }

    /// 通过 normalizer 生产事件，保证测试走的是与生产相同的标准化路径。
    private func makeEvent(
        kind: LocationEventKind = .entered,
        observedAt: Date,
        accuracy: Double = 20,
        capability: LocationCapability = .available
    ) throws -> LocationSemanticEvent {
        let normalized = LocationEventNormalizer.normalize(RawLocationObservation(
            placeId: "place_1",
            kind: kind,
            observedAt: observedAt,
            horizontalAccuracyMeters: accuracy,
            capability: capability,
            now: observedAt.addingTimeInterval(5)
        ))
        return try XCTUnwrap(normalized.event)
    }

    // MARK: - 有效事件产生候选

    func testValidEventProducesCandidateAndSchedulesNotification() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")   // 上海周一 10:00
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()
        let event = try makeEvent(observedAt: now)
        let runner = GeoTriggerRunner(store: store, notifier: notifier)

        let outcome = try await runner.handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertEqual(notifier.scheduleCallCount, 1, "有效事件必须真的去安排通知")
        XCTAssertEqual(outcome.notifierCallCount, 1)
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.state, .pending)
        XCTAssertTrue(outcome.skips.isEmpty)

        let rows = try store.proactiveMessages(kind: .geo)
        XCTAssertEqual(rows.count, 1, "候选必须落库")
        XCTAssertEqual(rows.first?.state, .pending)
        XCTAssertEqual(rows.first?.targetRef, "rule_1")
        XCTAssertEqual(rows.first?.dedupeKey, outcome.results.first?.dedupeKey)
    }

    func testExitRuleTriggersOnExitEvent() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule(rule: makeRule(trigger: .exit))
        let notifier = RecordingNotifier()
        let event = try makeEvent(kind: .exited, observedAt: now)

        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(notifier.scheduleCallCount, 1)
    }

    // MARK: - 陈旧 / 精度差 / 未知状态：不产生候选

    func testStaleObservationNeverReachesCandidateStage() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()

        let stale = LocationEventNormalizer.normalize(RawLocationObservation(
            placeId: "place_1",
            kind: .entered,
            observedAt: now.addingTimeInterval(-900),
            horizontalAccuracyMeters: 20,
            capability: .available,
            now: now
        ))
        XCTAssertNil(stale.event, "陈旧观测不能变成语义事件")
        XCTAssertTrue((stale.discardReason ?? "").contains("太旧"))
        XCTAssertEqual(try store.proactiveMessages(kind: .geo).count, 0, "没有事件就没有候选")

        // 同一套数据换成新鲜观测，链路立刻工作——证明上面的「没有候选」不是因为链路坏了。
        let fresh = try makeEvent(observedAt: now)
        _ = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: fresh, config: .standard, timeZone: zone, now: now)
        XCTAssertEqual(notifier.scheduleCallCount, 1)
        XCTAssertEqual(try store.proactiveMessages(kind: .geo).count, 1)
    }

    func testPoorAccuracyNeverReachesCandidateStage() throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()

        let result = LocationEventNormalizer.normalize(RawLocationObservation(
            placeId: "place_1",
            kind: .entered,
            observedAt: now,
            horizontalAccuracyMeters: 800,
            capability: .available,
            now: now
        ))
        XCTAssertNil(result.event)
        XCTAssertTrue((result.discardReason ?? "").contains("精度"))
        XCTAssertEqual(try store.proactiveMessages(kind: .geo).count, 0)
    }

    func testUnavailableCapabilityReportsReasonAndProducesNoCandidate() throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()

        let result = LocationEventNormalizer.normalize(RawLocationObservation(
            placeId: "place_1",
            kind: .entered,
            observedAt: now,
            horizontalAccuracyMeters: 20,
            capability: .denied,
            now: now
        ))
        XCTAssertNil(result.event)
        XCTAssertTrue((result.discardReason ?? "").contains("权限"))
        XCTAssertFalse(result.isAccepted)
        XCTAssertEqual(try store.proactiveMessages(kind: .geo).count, 0)
    }

    // MARK: - 预算与静默真的拦住通知安排

    func testDailyBudgetExhaustedPreventsNotificationScheduling() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()

        // 当天已经发出 1 条，而配置把地点提醒的每日上限定成 1。
        _ = try store.recordProactiveMessage(ProactiveMessageRecord(
            kind: .geo,
            dedupeKey: "geo:rule_9:enter:2026-10-12",
            targetRef: "rule_9",
            state: .delivered,
            suppressReason: nil,
            scheduledAtUTC: "2026-10-12T01:00:00Z",
            deliveredAtUTC: "2026-10-12T01:00:00Z",
            expiresAtUTC: nil,
            createdAt: "2026-10-12T01:00:00Z",
            updatedAt: "2026-10-12T01:00:00Z"
        ))
        var config = ProactiveBudgetConfig.standard
        config.setDailyLimit(1, for: .geo)

        let event = try makeEvent(observedAt: now)
        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: config, timeZone: zone, now: now)

        XCTAssertEqual(notifier.scheduleCallCount, 0, "超预算时安排环节必须真的没被调用")
        XCTAssertEqual(outcome.notifierCallCount, 0)
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.state, .suppressed)
        XCTAssertEqual(outcome.results.first?.notifierCalled, false)

        let suppressed = try store.proactiveMessage(dedupeKey: try XCTUnwrap(outcome.results.first?.dedupeKey))
        XCTAssertEqual(suppressed?.state, .suppressed)
        XCTAssertTrue((suppressed?.suppressReason ?? "").contains("用满"), "被抑制要有可解释的记录")
    }

    func testDuplicateDedupeKeyPreventsNotificationScheduling() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()

        let dedupeKey = GeoRuleEvaluator.dedupeKey(
            rule: makeRule(),
            at: now,
            insideSince: nil,
            timeZone: zone
        )
        _ = try store.recordProactiveMessage(ProactiveMessageRecord(
            kind: .geo,
            dedupeKey: dedupeKey,
            targetRef: "rule_1",
            state: .pending,
            suppressReason: nil,
            scheduledAtUTC: "2026-10-12T02:00:00Z",
            deliveredAtUTC: nil,
            expiresAtUTC: nil,
            createdAt: "2026-10-12T02:00:00Z",
            updatedAt: "2026-10-12T02:00:00Z"
        ))

        let event = try makeEvent(observedAt: now)
        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertEqual(notifier.scheduleCallCount, 0, "同一件事已经排过就不再安排")
        XCTAssertEqual(outcome.results.first?.state, .suppressed)
        XCTAssertTrue((outcome.results.first?.reason ?? "").contains("重复"))
    }

    func testQuietWindowDefersRatherThanDrops() async throws {
        // 上海周一 23:00，落在默认静默时段 22:30–07:00 内。
        let now = fixedDate("2026-10-12T15:00:00Z")
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()
        let event = try makeEvent(observedAt: now)

        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        // 静默时段按产品约定是顺延，所以这里仍然安排，但时刻被推到静默结束之后。
        XCTAssertEqual(notifier.scheduleCallCount, 1)
        let fireAt = try XCTUnwrap(notifier.scheduledRequests.first?.fireAt)
        XCTAssertGreaterThan(fireAt, now, "顺延后的时刻必须晚于现在")
        XCTAssertFalse(ProactiveBudget.isQuiet(
            fireAt,
            windows: ProactiveBudgetConfig.standard.quietWindows,
            timeZone: zone
        ), "顺延后不能再落在静默时段里")
        XCTAssertEqual(outcome.results.first?.state, .pending)
    }

    func testQuietWindowBeyondExpiryPreventsNotificationScheduling() async throws {
        // 上海周一 23:00，静默时段内；规则 23:30 过期，顺延到次日 07:00 已经超过有效期。
        let now = fixedDate("2026-10-12T15:00:00Z")
        try seedPlaceAndRule(rule: makeRule(expiresAtUTC: "2026-10-12T15:30:00Z"))
        let notifier = RecordingNotifier()
        let event = try makeEvent(observedAt: now)

        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertEqual(notifier.scheduleCallCount, 0, "顺延之后越过有效期就不能再安排")
        XCTAssertEqual(outcome.results.first?.state, .suppressed)
        XCTAssertTrue((outcome.results.first?.reason ?? "").contains("有效期"))
    }

    func testDisabledGeoKindPreventsNotificationScheduling() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()

        var config = ProactiveBudgetConfig.standard
        config.setEnabled(false, for: .geo)

        let event = try makeEvent(observedAt: now)
        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: config, timeZone: zone, now: now)

        XCTAssertEqual(notifier.scheduleCallCount, 0, "类别被关掉就不该安排通知")
        XCTAssertEqual(outcome.results.first?.state, .suppressed)
        XCTAssertTrue((outcome.results.first?.reason ?? "").contains("关掉"))
    }

    // MARK: - 规则生命周期与失败落库

    func testDisabledRuleIsSkippedWithReasonAndSchedulesNothing() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule(rule: makeRule(enabled: false))
        let notifier = RecordingNotifier()
        let event = try makeEvent(observedAt: now)

        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(notifier.scheduleCallCount, 0)
        XCTAssertTrue(outcome.skips.contains { $0.reason.contains("关闭") }, "跳过要给出原因")
        XCTAssertEqual(try store.proactiveMessages(kind: .geo).count, 0, "跳过的规则不落候选")
    }

    func testUnconfirmedPlaceIsSkippedWithReason() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule(place: makePlace(confirmed: false))
        let notifier = RecordingNotifier()
        let event = try makeEvent(observedAt: now)

        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(notifier.scheduleCallCount, 0)
        XCTAssertTrue(outcome.skips.contains { $0.reason.contains("确认") })
    }

    func testNotifierFailureIsRecordedAsCancelledNotPending() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule()
        let notifier = RecordingNotifier()
        notifier.failureReason = "通知权限没有打开，主动提醒不会发出。"
        let event = try makeEvent(observedAt: now)

        let outcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: event, config: .standard, timeZone: zone, now: now)

        XCTAssertEqual(outcome.results.first?.state, .cancelled)
        let rows = try store.proactiveMessages(kind: .geo)
        XCTAssertEqual(rows.first?.state, .cancelled, "安排失败不能留一条「等待发出」的假记录")
        XCTAssertEqual(rows.first?.suppressReason, notifier.failureReason)
    }

    func testDwellRuleOnlyTriggersWhenDurationSatisfied() async throws {
        let now = fixedDate("2026-10-12T02:00:00Z")
        try seedPlaceAndRule(rule: makeRule(trigger: .dwell, minDwellSeconds: 600))
        let notifier = RecordingNotifier()

        let tooShort = try makeEvent(kind: .dwell(insideSince: now.addingTimeInterval(-300)), observedAt: now)
        let shortOutcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: tooShort, config: .standard, timeZone: zone, now: now)

        XCTAssertTrue(shortOutcome.results.isEmpty)
        XCTAssertEqual(notifier.scheduleCallCount, 0)
        XCTAssertTrue(shortOutcome.skips.contains { $0.reason.contains("停留时长") })

        let longEnough = try makeEvent(kind: .dwell(insideSince: now.addingTimeInterval(-900)), observedAt: now)
        let longOutcome = try await GeoTriggerRunner(store: store, notifier: notifier)
            .handle(event: longEnough, config: .standard, timeZone: zone, now: now)

        XCTAssertEqual(longOutcome.results.count, 1)
        XCTAssertEqual(notifier.scheduleCallCount, 1)
    }
}
