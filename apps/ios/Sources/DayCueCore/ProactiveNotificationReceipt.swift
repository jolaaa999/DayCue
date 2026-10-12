import Foundation

// 通知交互回执：用户点开、忽略、回复，以及通知被系统取消或过期。
//
// 回执必须回写账本，否则「发出去了没有、用户看没看到」就无从判断，
// 预算也会因为状态停在 pending 而一直占着当天额度。

/// 用户在通知上的动作。
public enum ProactiveInteraction: String, Codable, CaseIterable, Sendable {

    case opened
    case replied
    /// 用户把通知划掉/清掉，没有点开。
    case dismissed
    /// 系统在通知生效前把它丢掉了（例如设备关机、超时）。
    case expired
    /// 被应用主动取消（规则改了、设置重算、时间已过）。
    case cancelled

    public var displayName: String {
        switch self {
        case .opened: return "已点开"
        case .replied: return "已回复"
        case .dismissed: return "已忽略"
        case .expired: return "已过期"
        case .cancelled: return "已取消"
        }
    }

    /// 对应的账本状态。
    ///
    /// dismissed 必须映射成 delivered，不能映射成 cancelled。这两件事完全不同：
    /// - delivered 是「消息已经到达设备」（用户看到后才可能划掉），要占预算；
    /// - cancelled 是「投递前被应用取消」（规则改了、地点删了），根本没发出去，不占预算。
    ///
    /// 把「用户划掉已收到的通知」记成 cancelled 的后果很具体：账本 deliveredAt 为空，
    /// 当日额度会被**退还**，系统于是有额度继续发同类提醒——用户越划越收到，正是他想避免的。
    public var resultingState: ProactiveMessageState {
        switch self {
        case .opened, .replied, .dismissed: return .delivered
        case .expired: return .expired
        case .cancelled: return .cancelled
        }
    }

    /// 这次交互是否**证明消息确实到达了设备**。
    ///
    /// opened / replied / dismissed 都只可能发生在用户已经看到这条通知之后，
    /// 因此它们构成「到达设备」的可信证据（虽然只是反推，但来自用户侧，不是猜的）。
    ///
    /// expired / cancelled 是系统或应用单方面结束，**不构成任何到达证据**：
    /// 极可能根本就没显示过，所以绝不能因此写下 deliveredAt。
    public var provesDeviceReached: Bool {
        switch self {
        case .opened, .replied, .dismissed: return true
        case .expired, .cancelled: return false
        }
    }

    /// 写进账本的中文说明。opened/replied 不额外解释，其余给一句可读的原因。
    public var stateReason: String? {
        switch self {
        case .opened, .replied:
            return nil
        case .dismissed:
            return "用户忽略了这条通知，不再等它。"
        case .expired:
            return "这条主动提醒已经过期，没有发出。"
        case .cancelled:
            return "这条主动提醒已被取消。"
        }
    }
}

/// 一次交互回执。dedupeKey 是账本主键，适配层从通知的 userInfo 里取。
public struct ProactiveInteractionReceipt: Equatable, Sendable {

    public var dedupeKey: String
    public var interaction: ProactiveInteraction
    /// 交互发生的时刻，由适配层显式传入。
    public var at: Date
    /// 用户直接回复的正文。账本没有存放回复正文的列，
    /// 因此这里只用于回执说明，回复正文由 FollowUpArchivePlanner 归档成笔记。
    public var userText: String?

    public init(
        dedupeKey: String,
        interaction: ProactiveInteraction,
        at: Date,
        userText: String? = nil
    ) {
        self.dedupeKey = dedupeKey
        self.interaction = interaction
        self.at = at
        self.userText = userText
    }
}

public struct ProactiveReceiptOutcome: Equatable, Sendable {

    public var dedupeKey: String
    public var state: ProactiveMessageState
    public var reason: String?
    public var deliveredAt: Date?
    /// 账本里没有这条记录时为 nil。绝不能凭空造一条「已发出」。
    public var record: ProactiveMessageRecord?
    public var applied: Bool
    /// 如果这是课后追问的通知，顺带把追问行标成「已发出」，返回一句说明。
    public var followUpNote: String?

    public init(
        dedupeKey: String,
        state: ProactiveMessageState,
        reason: String?,
        deliveredAt: Date?,
        record: ProactiveMessageRecord?,
        applied: Bool,
        followUpNote: String? = nil
    ) {
        self.dedupeKey = dedupeKey
        self.state = state
        self.reason = reason
        self.deliveredAt = deliveredAt
        self.record = record
        self.applied = applied
        self.followUpNote = followUpNote
    }
}

/// 回执落库。
///
/// 谁调用它：App 层 ProactiveGeoCoordinator 把系统通知回调转成回执后调用；
/// 地点与课后追问两条路径共用这一份状态映射。
public struct ProactiveReceiptService {

    private let store: DayCueStore

    public init(store: DayCueStore) {
        self.store = store
    }

    @discardableResult
    public func apply(_ receipt: ProactiveInteractionReceipt) throws -> ProactiveReceiptOutcome {

        guard let existing = try store.proactiveMessage(dedupeKey: receipt.dedupeKey) else {
            return ProactiveReceiptOutcome(
                dedupeKey: receipt.dedupeKey,
                state: .cancelled,
                reason: "账本里没有这条主动提醒，回执被忽略。",
                deliveredAt: nil,
                record: nil,
                applied: false
            )
        }

        // 终态不因迟到回执而反转：已经取消/过期的提醒被点开，也不能复活成 delivered 再占预算。
        if existing.state.isTerminal {
            return ProactiveReceiptOutcome(
                dedupeKey: receipt.dedupeKey,
                state: existing.state,
                reason: "这条主动提醒已经处于终态（\(existing.state.displayName)），回执不再改变状态。",
                deliveredAt: existing.deliveredAtUTC.flatMap { RFC3339.date(fromUTC: $0) },
                record: existing,
                applied: false
            )
        }

        let state = receipt.interaction.resultingState

        // deliveredAt 的准确含义是「我们最后一次确认它到达了设备的时刻」，
        // 而**不是**「iOS 报告它被展示的时刻」—— iOS 不提供展示回执，那个时刻根本拿不到。
        // 这里的时间来自用户交互反推（点开/回复/划掉都证明用户看见过它），
        // 所以只在 provesDeviceReached 为真时写入；系统过期或应用取消一律留空，
        // 否则就等于把「没送到」记成「送到了」。
        let deliveredAt = receipt.interaction.provesDeviceReached ? receipt.at : nil

        try store.updateProactiveMessageState(
            id: existing.id,
            state: state,
            suppressReason: receipt.interaction.stateReason,
            deliveredAt: deliveredAt,
            at: receipt.at
        )

        let followUpNote = try markFollowUpDeliveredIfNeeded(existing: existing, receipt: receipt)
        let updated = try store.proactiveMessage(id: existing.id)

        return ProactiveReceiptOutcome(
            dedupeKey: receipt.dedupeKey,
            state: state,
            reason: receipt.interaction.stateReason,
            deliveredAt: deliveredAt,
            record: updated,
            applied: true,
            followUpNote: followUpNote
        )
    }

    /// 课后追问的通知被点开/忽略后，把追问行也标成「已发出」。
    ///
    /// 这一步不能省：追问行停在 scheduled 的话，下次设置变化重算时会再安排一次通知，
    /// 用户就会被同一个问题问两遍。
    private func markFollowUpDeliveredIfNeeded(
        existing: ProactiveMessageRecord,
        receipt: ProactiveInteractionReceipt
    ) throws -> String? {

        guard existing.kind == .followUp else { return nil }
        guard let followUpId = existing.targetRef else { return nil }
        switch receipt.interaction {
        case .opened, .replied, .dismissed:
            break
        case .expired, .cancelled:
            return nil
        }

        guard let followUp = try store.followUp(id: followUpId) else {
            return "找不到对应的课后追问（\(followUpId)）。"
        }
        guard let updated = FollowUpScheduler.applying(
            followUp,
            state: .delivered,
            at: receipt.at,
            deliveredAt: receipt.at
        ) else {
            return "课后追问已经处于终态，未改动。"
        }
        guard (try store.applyFollowUpState(updated)) != nil else { return nil }
        return "课后追问已记为「已发出」。"
    }
}
