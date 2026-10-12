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
    /// dismissed 映射成 cancelled：Schema 只有 pending/delivered/suppressed/expired/cancelled 五态，
    /// 没有单独的「忽略」态。划掉意味着它不会再次出现，用一个明确的终态表示比留在 pending
    /// 继续占预算要诚实得多。
    public var resultingState: ProactiveMessageState {
        switch self {
        case .opened, .replied: return .delivered
        case .dismissed: return .cancelled
        case .expired: return .expired
        case .cancelled: return .cancelled
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
        let deliveredAt = state == .delivered ? receipt.at : nil

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
