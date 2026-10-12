import Foundation

// 地点规则触发后的「候选 -> 预算 -> 通知安排」链路的编排。
//
// 这一层只做编排，不做判断：
// - 触发条件与冷却在 GeoRuleEvaluator（纯逻辑）
// - 预算、静默、冷却、去重在 ProactiveBudget（纯逻辑）
// - 真正发通知由 ProactiveNotificationScheduling 的实现负责（iOS 上是 UNUserNotificationCenter）
//
// 编排放在 Core 而不是 App，是为了让「被抑制时通知安排环节真的没被调用」这件事可测：
// 测试注入一个记录调用次数的替身，就能证明抑制不是只算出一个 decision。

/// 一条待安排的主动通知。
public struct ProactiveNotificationRequest: Equatable, Sendable {

    public var kind: ProactiveMessageKind
    /// 与账本一致的去重键。
    public var dedupeKey: String
    /// 系统通知标识。由 ProactiveNotificationIdentifier 统一生成，取消时用同一把钥匙。
    public var identifier: String
    public var title: String
    public var body: String?
    /// 期望发出时刻。静默时段顺延后的时刻会落在这里。
    public var fireAt: Date
    public var targetRef: String?

    public init(
        kind: ProactiveMessageKind,
        dedupeKey: String,
        identifier: String,
        title: String,
        body: String? = nil,
        fireAt: Date,
        targetRef: String? = nil
    ) {
        self.kind = kind
        self.dedupeKey = dedupeKey
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.targetRef = targetRef
    }
}

/// 安排结果。不能安排时必须给出中文原因，账本要如实记录。
public enum ProactiveNotificationScheduleResult: Equatable, Sendable {

    case scheduled(identifier: String, at: Date)
    case notScheduled(reason: String)

    public var isScheduled: Bool {
        if case .scheduled = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case let .scheduled(identifier, _): return "已安排通知：\(identifier)"
        case let .notScheduled(reason): return reason
        }
    }
}

/// 通知安排器协议。实现方可以是系统通知中心，也可以是测试替身。
public protocol ProactiveNotificationScheduling: AnyObject {

    func schedule(_ request: ProactiveNotificationRequest) async -> ProactiveNotificationScheduleResult
    func cancel(identifier: String) async
}

/// 通知标识的唯一生成处。
///
/// 主动提醒用独立前缀，与 NotificationService 的任务提醒（daycue.task.reminder.）互不干扰：
/// 两条路径各自取消自己的通知，不会误删对方排的提醒。
public enum ProactiveNotificationIdentifier {

    public static let prefix = "daycue.proactive."

    public static func identifier(forDedupeKey key: String) -> String {
        prefix + key
    }
}

/// 参与求值的一条规则被跳过的原因。
public struct GeoTriggerSkip: Equatable, Sendable {

    public var ruleId: String
    public var reason: String
    /// true 表示因为位置不可信而静默降级，界面必须与「没到条件」区分开。
    public var isSilent: Bool

    public init(ruleId: String, reason: String, isSilent: Bool) {
        self.ruleId = ruleId
        self.reason = reason
        self.isSilent = isSilent
    }
}

/// 通过规则求值、进入预算环节的候选。
public struct GeoTriggerCandidate: Equatable, Sendable {

    public var ruleId: String
    public var placeId: String
    public var dedupeKey: String
    public var title: String
    public var body: String?
    public var scheduledAt: Date
    /// .pending 表示允许安排；.suppressed 表示被预算/静默/冷却/去重挡住。
    public var state: ProactiveMessageState
    public var reason: String
    public var suppressReason: String?
    public var shouldNotify: Bool

    public init(
        ruleId: String,
        placeId: String,
        dedupeKey: String,
        title: String,
        body: String?,
        scheduledAt: Date,
        state: ProactiveMessageState,
        reason: String,
        suppressReason: String?,
        shouldNotify: Bool
    ) {
        self.ruleId = ruleId
        self.placeId = placeId
        self.dedupeKey = dedupeKey
        self.title = title
        self.body = body
        self.scheduledAt = scheduledAt
        self.state = state
        self.reason = reason
        self.suppressReason = suppressReason
        self.shouldNotify = shouldNotify
    }
}

/// 纯计算的结果：哪些要安排、哪些被抑制、哪些跳过。
public struct GeoTriggerPlan: Equatable, Sendable {

    public var candidates: [GeoTriggerCandidate]
    public var skips: [GeoTriggerSkip]

    public init(candidates: [GeoTriggerCandidate], skips: [GeoTriggerSkip]) {
        self.candidates = candidates
        self.skips = skips
    }

    public var notifyCount: Int { candidates.filter { $0.shouldNotify }.count }
    public var suppressedCount: Int { candidates.filter { !$0.shouldNotify }.count }
}

/// 规则求值到候选的纯逻辑。不碰数据库、不读时钟、不发通知。
public enum GeoTriggerPlanner {

    public static func plan(
        event: LocationSemanticEvent,
        rules: [GeoRuleRecord],
        placesById: [String: PlaceRecord],
        ledger: [ProactiveMessageRecord],
        config: ProactiveBudgetConfig,
        timeZone: TimeZone,
        now: Date
    ) -> GeoTriggerPlan {

        var candidates: [GeoTriggerCandidate] = []
        var skips: [GeoTriggerSkip] = []

        for rule in rules {
            // 只评估「事件地点上的、且触发条件与事件同类」的规则。
            // 一次进入不该去评估「离开时」规则，否则每类规则都会各判一遍，结论必然错。
            guard rule.placeId == event.placeId else { continue }
            guard rule.trigger == event.trigger else { continue }

            let request = GeoEvaluationRequest(
                rule: rule,
                place: placesById[rule.placeId],
                previousState: event.transition.previous,
                currentState: event.transition.current,
                insideSince: event.insideSince,
                locationAuthorizationGranted: event.capability.isUsable,
                locationServicesAvailable: event.capability.isUsable,
                lastDeliveredAt: lastDeliveredAt(ruleId: rule.id, ledger: ledger),
                now: now,
                timeZone: timeZone
            )

            switch GeoRuleEvaluator.evaluate(request) {
            case let .skip(reason, isSilent):
                skips.append(GeoTriggerSkip(ruleId: rule.id, reason: reason, isSilent: isSilent))

            case let .trigger(dedupeKey, triggerReason):
                // 候选在安排之前就要过预算：预算、静默、冷却、去重在这里一次性判完。
                let expiry = rule.expiresAtUTC.flatMap { RFC3339.date(fromUTC: $0) }
                let budgetDecision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
                    kind: .geo,
                    dedupeKey: dedupeKey,
                    scheduledAt: now,
                    expiresAt: expiry,
                    targetRef: rule.id,
                    cooldownOverride: TimeInterval(max(0, rule.cooldownSeconds)),
                    ledger: ledger,
                    now: now,
                    timeZone: timeZone,
                    config: config
                ))

                switch budgetDecision {
                case let .suppressed(suppressReason):
                    candidates.append(GeoTriggerCandidate(
                        ruleId: rule.id,
                        placeId: rule.placeId,
                        dedupeKey: dedupeKey,
                        title: rule.title,
                        body: rule.body,
                        scheduledAt: now,
                        state: .suppressed,
                        reason: suppressReason,
                        suppressReason: suppressReason,
                        shouldNotify: false
                    ))

                case let .deliver(at, budgetReason):
                    let combined = budgetReason == "可以提醒。"
                        ? triggerReason
                        : "\(triggerReason) \(budgetReason)"
                    candidates.append(GeoTriggerCandidate(
                        ruleId: rule.id,
                        placeId: rule.placeId,
                        dedupeKey: dedupeKey,
                        title: rule.title,
                        body: rule.body,
                        scheduledAt: at,
                        state: .pending,
                        reason: combined,
                        suppressReason: nil,
                        shouldNotify: true
                    ))
                }
            }
        }

        return GeoTriggerPlan(candidates: candidates, skips: skips)
    }

    /// 这条规则上一次真正发出消息的时刻。冷却判断用它，而不是靠内存里的标记。
    public static func lastDeliveredAt(ruleId: String, ledger: [ProactiveMessageRecord]) -> Date? {
        ledger
            .filter { $0.kind == .geo && $0.targetRef == ruleId && $0.state == .delivered }
            .compactMap { $0.effectiveAt }
            .max()
    }
}

/// 一次编排的结果，直接给界面/日志看。
public struct GeoTriggerResult: Equatable, Sendable {

    public var ruleId: String
    public var dedupeKey: String
    public var state: ProactiveMessageState
    public var scheduledAt: Date
    public var reason: String
    /// 通知安排环节是否真的被调用过。抑制路径必须为 false。
    public var notifierCalled: Bool
    public var notifierOutcome: String?

    public init(
        ruleId: String,
        dedupeKey: String,
        state: ProactiveMessageState,
        scheduledAt: Date,
        reason: String,
        notifierCalled: Bool,
        notifierOutcome: String?
    ) {
        self.ruleId = ruleId
        self.dedupeKey = dedupeKey
        self.state = state
        self.scheduledAt = scheduledAt
        self.reason = reason
        self.notifierCalled = notifierCalled
        self.notifierOutcome = notifierOutcome
    }
}

public struct GeoTriggerRunOutcome: Equatable, Sendable {

    public var results: [GeoTriggerResult]
    public var skips: [GeoTriggerSkip]
    /// 实际调用通知安排器的次数。测试用它证明抑制真的拦住了安排。
    public var notifierCallCount: Int

    public init(results: [GeoTriggerResult], skips: [GeoTriggerSkip], notifierCallCount: Int) {
        self.results = results
        self.skips = skips
        self.notifierCallCount = notifierCallCount
    }
}

/// 地点事件的完整落地：落库候选 + 过预算 + 真安排通知。
///
/// 谁调用它：App 层的 ProactiveGeoCoordinator 在收到位置事件时调用。
public struct GeoTriggerRunner {

    private let store: DayCueStore
    private let notifier: any ProactiveNotificationScheduling

    public init(store: DayCueStore, notifier: any ProactiveNotificationScheduling) {
        self.store = store
        self.notifier = notifier
    }

    /// 处理一条已经通过新鲜度检查的位置事件。
    ///
    /// 被预算抑制的候选也会落库（state = suppressed，带中文原因），
    /// 这样「为什么没提醒」在账本里查得到，而不是静默消失。
    @discardableResult
    public func handle(
        event: LocationSemanticEvent,
        config: ProactiveBudgetConfig,
        timeZone: TimeZone,
        now: Date
    ) async throws -> GeoTriggerRunOutcome {

        let rules = try store.geoRules(includeDeleted: false, limit: 500)
        let places = try store.places(includeDeleted: false, limit: 500)
        var placesById: [String: PlaceRecord] = [:]
        for place in places { placesById[place.id] = place }

        // 账本要往前多取一天：跨零点的冷却需要看到昨晚发出的那条记录，
        // 只取当天会漏判「刚过零点又触发」。
        let dayStart = ProactiveBudget.startOfLocalDay(for: now, timeZone: timeZone)
            ?? now.addingTimeInterval(-86400)
        let ledger = try store.proactiveLedger(since: dayStart.addingTimeInterval(-86400), limit: 1000)

        let plan = GeoTriggerPlanner.plan(
            event: event,
            rules: rules,
            placesById: placesById,
            ledger: ledger,
            config: config,
            timeZone: timeZone,
            now: now
        )

        let nowString = RFC3339.utcString(from: now)
        var results: [GeoTriggerResult] = []
        var notifierCallCount = 0

        for candidate in plan.candidates {
            let record = ProactiveMessageRecord(
                kind: .geo,
                dedupeKey: candidate.dedupeKey,
                targetRef: candidate.ruleId,
                state: candidate.state,
                suppressReason: candidate.suppressReason,
                scheduledAtUTC: RFC3339.utcString(from: candidate.scheduledAt),
                deliveredAtUTC: nil,
                expiresAtUTC: nil,
                createdAt: nowString,
                updatedAt: nowString
            )
            let saved = try store.recordProactiveMessage(record, at: now)

            guard candidate.shouldNotify else {
                results.append(GeoTriggerResult(
                    ruleId: candidate.ruleId,
                    dedupeKey: candidate.dedupeKey,
                    state: .suppressed,
                    scheduledAt: candidate.scheduledAt,
                    reason: candidate.reason,
                    notifierCalled: false,
                    notifierOutcome: nil
                ))
                continue
            }

            notifierCallCount += 1
            let request = ProactiveNotificationRequest(
                kind: .geo,
                dedupeKey: candidate.dedupeKey,
                identifier: ProactiveNotificationIdentifier.identifier(forDedupeKey: candidate.dedupeKey),
                title: candidate.title,
                body: candidate.body,
                fireAt: candidate.scheduledAt,
                targetRef: candidate.ruleId
            )
            let outcome = await notifier.schedule(request)

            switch outcome {
            case .scheduled:
                results.append(GeoTriggerResult(
                    ruleId: candidate.ruleId,
                    dedupeKey: candidate.dedupeKey,
                    state: .pending,
                    scheduledAt: candidate.scheduledAt,
                    reason: candidate.reason,
                    notifierCalled: true,
                    notifierOutcome: nil
                ))
            case let .notScheduled(reason):
                // 安排失败不能留一条「等待发出」的假记录，落成 cancelled 并写明原因。
                try store.updateProactiveMessageState(
                    id: saved.id,
                    state: .cancelled,
                    suppressReason: reason,
                    at: now
                )
                results.append(GeoTriggerResult(
                    ruleId: candidate.ruleId,
                    dedupeKey: candidate.dedupeKey,
                    state: .cancelled,
                    scheduledAt: candidate.scheduledAt,
                    reason: reason,
                    notifierCalled: true,
                    notifierOutcome: reason
                ))
            }
        }

        return GeoTriggerRunOutcome(
            results: results,
            skips: plan.skips,
            notifierCallCount: notifierCallCount
        )
    }
}
