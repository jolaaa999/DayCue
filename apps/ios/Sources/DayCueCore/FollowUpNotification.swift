import Foundation

// 课后追问通知的「安排前检查」与「设置变化后重算」。
//
// 产品限制（写在代码里，防止以后被改成别的东西）：
// 课后追问是**提前排好的本地通知**，不存在「到点运行后台 AI」。
// 因此预算与静默必须在**安排的那一刻**就判完；等到通知到点再判，
// 就意味着那时候要有代码跑起来——那正是产品不做的事。
//
// 追问时刻来自 FollowUpScheduler（先算 scheduledAt / effectiveDate / 过期），
// 这一层只负责：安排前过预算 + 设置变化后重算并取消旧请求。

public struct FollowUpNotificationItem: Equatable, Sendable {

    public var followUpId: String
    public var dedupeKey: String
    public var identifier: String
    public var title: String
    public var body: String?
    /// 预算顺延之后的实际发出时刻（可能晚于追问的原始时刻）。
    public var fireAt: Date
    public var expiresAt: Date?
    public var courseId: String

    public init(
        followUpId: String,
        dedupeKey: String,
        identifier: String,
        title: String,
        body: String?,
        fireAt: Date,
        expiresAt: Date?,
        courseId: String
    ) {
        self.followUpId = followUpId
        self.dedupeKey = dedupeKey
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.expiresAt = expiresAt
        self.courseId = courseId
    }
}

/// 不安排的通知，及其可解释的原因。
public struct FollowUpNotificationSuppression: Equatable, Sendable {

    public var followUpId: String
    public var dedupeKey: String
    public var identifier: String
    public var state: ProactiveMessageState
    public var reason: String

    public init(
        followUpId: String,
        dedupeKey: String,
        identifier: String,
        state: ProactiveMessageState,
        reason: String
    ) {
        self.followUpId = followUpId
        self.dedupeKey = dedupeKey
        self.identifier = identifier
        self.state = state
        self.reason = reason
    }
}

public struct FollowUpNotificationPlan: Equatable, Sendable {

    public var items: [FollowUpNotificationItem]
    public var suppressions: [FollowUpNotificationSuppression]
    /// 需要取消的旧请求标识。包含被抑制/过期/终态的，以及本轮不再保留的野注册。
    public var identifiersToCancel: [String]
    public var warnings: [String]

    public init(
        items: [FollowUpNotificationItem],
        suppressions: [FollowUpNotificationSuppression],
        identifiersToCancel: [String],
        warnings: [String]
    ) {
        self.items = items
        self.suppressions = suppressions
        self.identifiersToCancel = identifiersToCancel
        self.warnings = warnings
    }
}

public enum FollowUpNotificationPlanner {

    public static let dedupeKeyPrefix = "followup:"

    /// 追问的去重键由追问 id 推导：一条追问在账本里只占一行，
    /// 重算时命中同一行而不是越排越多。
    public static func dedupeKey(followUpId: String) -> String {
        dedupeKeyPrefix + followUpId
    }

    /// 纯计算：给定追问、课程、账本与预算配置，算出该安排什么、该取消什么、哪些被抑制。
    ///
    /// - currentlyScheduledIdentifiers: 系统里现在真的排着的主动通知标识。
    ///   本轮不打算保留的一律取消，这样规则/设置变化后不会留下野注册。
    public static func plan(
        followUps: [FollowUpRecord],
        coursesById: [String: CourseRecord],
        ledger: [ProactiveMessageRecord],
        config: ProactiveBudgetConfig,
        timeZone: TimeZone,
        now: Date,
        graceMinutes: Int = FollowUpScheduler.defaultGraceMinutes,
        currentlyScheduledIdentifiers: Set<String> = []
    ) -> FollowUpNotificationPlan {

        var items: [FollowUpNotificationItem] = []
        var suppressions: [FollowUpNotificationSuppression] = []
        var cancel = Set<String>()
        var warnings: [String] = []

        for followUp in followUps {
            let key = dedupeKey(followUpId: followUp.id)
            let identifier = ProactiveNotificationIdentifier.identifier(forDedupeKey: key)

            // 1. 终态追问不再安排。只有它确实排过通知时才需要落一条取消记录，
            //    否则每处理一次历史追问都会往账本里灌一行噪音。
            if followUp.state.isTerminal {
                if currentlyScheduledIdentifiers.contains(identifier) {
                    cancel.insert(identifier)
                    suppressions.append(FollowUpNotificationSuppression(
                        followUpId: followUp.id,
                        dedupeKey: key,
                        identifier: identifier,
                        state: followUp.state == .expired ? .expired : .cancelled,
                        reason: "这条课后追问已经处理完（\(followUp.state.displayName)），对应的通知已取消。"
                    ))
                }
                continue
            }

            // 2. 已经发出过的追问不再重排，否则用户会被同一个问题问两遍。
            let alreadyDelivered = followUp.state == .delivered
                || ledger.contains { $0.dedupeKey == key && $0.state == .delivered }
            if alreadyDelivered {
                cancel.insert(identifier)
                continue
            }

            // 3. 时间无法解析就不猜，直接取消并留下告警。
            guard let effective = FollowUpScheduler.effectiveDate(of: followUp) else {
                warnings.append("追问 \(followUp.id) 的时间无法解析，已取消对应通知。")
                cancel.insert(identifier)
                continue
            }
            let deadline = FollowUpScheduler.expiryDeadline(of: followUp, graceMinutes: graceMinutes)

            // 4. 已过宽限期：落成 expired，不再打扰。
            if let deadline, deadline <= now {
                cancel.insert(identifier)
                suppressions.append(FollowUpNotificationSuppression(
                    followUpId: followUp.id,
                    dedupeKey: key,
                    identifier: identifier,
                    state: .expired,
                    reason: "这条课后追问已经过了有效期，不再提醒。"
                ))
                continue
            }

            // 5. 安排前的预算检查。这里必须排除「这件事自己的账本行」：
            //    设置变化后的重算不是新增一件事，如果被自己的旧行当成重复，
            //    用户改了预算反而永远排不上。
            let otherLedger = ledger.filter { $0.dedupeKey != key }
            let decision = ProactiveBudget.evaluate(ProactiveBudgetRequest(
                kind: .followUp,
                dedupeKey: key,
                scheduledAt: effective,
                expiresAt: deadline,
                targetRef: followUp.id,
                ledger: otherLedger,
                now: now,
                timeZone: timeZone,
                config: config
            ))

            switch decision {
            case let .suppressed(reason):
                cancel.insert(identifier)
                suppressions.append(FollowUpNotificationSuppression(
                    followUpId: followUp.id,
                    dedupeKey: key,
                    identifier: identifier,
                    state: .suppressed,
                    reason: reason
                ))
            case let .deliver(at, _):
                let courseName = coursesById[followUp.courseId]?.name ?? "这节课"
                items.append(FollowUpNotificationItem(
                    followUpId: followUp.id,
                    dedupeKey: key,
                    identifier: identifier,
                    title: "课后追问",
                    body: "「\(courseName)」刚下课，记一句？",
                    fireAt: at,
                    expiresAt: deadline,
                    courseId: followUp.courseId
                ))
            }
        }

        // 6. 野注册清理：本轮不打算保留、但系统里还排着的通知，一并取消。
        let kept = Set(items.map { $0.identifier })
        for identifier in currentlyScheduledIdentifiers where !kept.contains(identifier) {
            cancel.insert(identifier)
        }

        return FollowUpNotificationPlan(
            items: items,
            suppressions: suppressions,
            identifiersToCancel: cancel.sorted(),
            warnings: warnings
        )
    }
}

public struct FollowUpNotificationApplyOutcome: Equatable, Sendable {

    public var scheduledCount: Int
    public var cancelledCount: Int
    public var suppressedCount: Int
    public var warnings: [String]

    public init(
        scheduledCount: Int,
        cancelledCount: Int,
        suppressedCount: Int,
        warnings: [String]
    ) {
        self.scheduledCount = scheduledCount
        self.cancelledCount = cancelledCount
        self.suppressedCount = suppressedCount
        self.warnings = warnings
    }
}

/// 把计划落成实际动作：取消旧请求 + 落账本 + 安排通知。
///
/// 谁调用它：App 层 FollowUpNotificationCoordinator 在「重新安排课后追问」与
/// 主动提醒设置变化后调用。
public struct FollowUpNotificationRunner {

    private let store: DayCueStore
    private let notifier: any ProactiveNotificationScheduling

    public init(store: DayCueStore, notifier: any ProactiveNotificationScheduling) {
        self.store = store
        self.notifier = notifier
    }

    @discardableResult
    public func apply(
        _ plan: FollowUpNotificationPlan,
        at now: Date
    ) async throws -> FollowUpNotificationApplyOutcome {

        let nowString = RFC3339.utcString(from: now)

        // 先取消，再安排：顺序反过来的话，同名标识的安排可能被随后的取消误删。
        var cancelledCount = 0
        for identifier in plan.identifiersToCancel {
            await notifier.cancel(identifier: identifier)
            cancelledCount += 1
        }

        // 被抑制/过期也要落账本，界面才答得出「为什么没提醒我」。
        for suppression in plan.suppressions {
            let record = ProactiveMessageRecord(
                kind: .followUp,
                dedupeKey: suppression.dedupeKey,
                targetRef: suppression.followUpId,
                state: suppression.state,
                suppressReason: suppression.reason,
                scheduledAtUTC: nowString,
                deliveredAtUTC: nil,
                expiresAtUTC: nil,
                createdAt: nowString,
                updatedAt: nowString
            )
            _ = try store.recordProactiveMessage(record, at: now)
        }

        var scheduledCount = 0
        for item in plan.items {
            let record = ProactiveMessageRecord(
                kind: .followUp,
                dedupeKey: item.dedupeKey,
                targetRef: item.followUpId,
                state: .pending,
                suppressReason: nil,
                scheduledAtUTC: RFC3339.utcString(from: item.fireAt),
                deliveredAtUTC: nil,
                expiresAtUTC: item.expiresAt.map { RFC3339.utcString(from: $0) },
                createdAt: nowString,
                updatedAt: nowString
            )
            let saved = try store.recordProactiveMessage(record, at: now)

            let request = ProactiveNotificationRequest(
                kind: .followUp,
                dedupeKey: item.dedupeKey,
                identifier: item.identifier,
                title: item.title,
                body: item.body,
                fireAt: item.fireAt,
                targetRef: item.followUpId
            )
            let result = await notifier.schedule(request)
            switch result {
            case .scheduled:
                scheduledCount += 1
            case let .notScheduled(reason):
                // 排不上就不能留一条「等待发出」的假记录。
                try store.updateProactiveMessageState(
                    id: saved.id,
                    state: .cancelled,
                    suppressReason: reason,
                    at: now
                )
            }
        }

        return FollowUpNotificationApplyOutcome(
            scheduledCount: scheduledCount,
            cancelledCount: cancelledCount,
            suppressedCount: plan.suppressions.count,
            warnings: plan.warnings
        )
    }
}
