import Foundation

// 主动提醒的预算与节流。**纯逻辑**：不读系统时钟、不碰数据库、不发起定位。
// 「现在」、时区、账本、配置全部由调用方传入，所以同一份输入在任何设备上都得到同一结论。
//
// 产品底线：
// - 静默时段内**延迟而不是丢弃**：用户设置了夜间不打扰，那就顺延到白天再发。
// - 每日预算按**自然日**计，跨零点必须重置；用「发出时刻所在的当地日期」判定。
// - 超预算、冷却中、重复、已过期都必须返回**中文原因**，界面直接展示，不出现「未知原因」。

/// 静默时段（当地墙面时间）。
///
/// 用「日内分钟数」而不是 Date：静默时段是每天重复的墙面时间，
/// 存成绝对时刻会在夏令时切换那天算错。
public struct ProactiveQuietWindow: Codable, Equatable, Sendable {

    public var startMinutes: Int
    public var endMinutes: Int

    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    public var startText: String { GeoRuleClock.text(minutes: startMinutes) }
    public var endText: String { GeoRuleClock.text(minutes: endMinutes) }

    /// 跨零点，例如 22:30–07:00。
    public var isOvernight: Bool { startMinutes > endMinutes }

    /// 起止相同视为「没有设置静默时段」。
    /// 若判成全天静默，用户误把两个指针拨到同一位置就会收不到任何提醒，
    /// 而且很难想到是这里的问题；不静默至少不会静默地坏掉。
    public var isEmpty: Bool { startMinutes == endMinutes }

    public func contains(minutesOfDay minutes: Int) -> Bool {
        if isEmpty { return false }
        if startMinutes < endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        }
        return minutes >= startMinutes || minutes < endMinutes
    }

    /// 从 date 起，本时段的结束时刻。已经过了今天的结束点就用明天。
    public func nextEndDate(after date: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = endMinutes / 60
        components.minute = endMinutes % 60
        components.second = 0
        guard let boundary = calendar.date(from: components) else { return nil }
        if boundary <= date {
            return calendar.date(byAdding: .day, value: 1, to: boundary)
        }
        return boundary
    }
}

/// 预算配置。字典的键用 rawValue 字符串而不是枚举：
/// JSON 里键必须是字符串，用枚举做 Dictionary 的键会被编码成数组，持久化格式会变得难读也难改。
public struct ProactiveBudgetConfig: Codable, Equatable, Sendable {

    public var disabledKinds: [String]
    public var dailyLimitByKind: [String: Int]
    public var defaultDailyLimit: Int
    public var cooldownByKind: [String: TimeInterval]
    public var defaultCooldown: TimeInterval
    public var quietWindows: [ProactiveQuietWindow]

    public init(
        disabledKinds: [String] = [],
        dailyLimitByKind: [String: Int] = [:],
        defaultDailyLimit: Int = 3,
        cooldownByKind: [String: TimeInterval] = [:],
        defaultCooldown: TimeInterval = 3600,
        quietWindows: [ProactiveQuietWindow] = [ProactiveQuietWindow(startMinutes: 22 * 60 + 30, endMinutes: 7 * 60)]
    ) {
        self.disabledKinds = disabledKinds
        self.dailyLimitByKind = dailyLimitByKind
        self.defaultDailyLimit = defaultDailyLimit
        self.cooldownByKind = cooldownByKind
        self.defaultCooldown = defaultCooldown
        self.quietWindows = quietWindows
    }

    /// 默认值：每天最多 3 条主动提醒、同类冷却 1 小时、22:30–07:00 静默。
    public static let standard = ProactiveBudgetConfig()

    public func isEnabled(kind: ProactiveMessageKind) -> Bool {
        !disabledKinds.contains(kind.rawValue)
    }

    public func dailyLimit(for kind: ProactiveMessageKind) -> Int {
        dailyLimitByKind[kind.rawValue] ?? defaultDailyLimit
    }

    public func cooldown(for kind: ProactiveMessageKind) -> TimeInterval {
        cooldownByKind[kind.rawValue] ?? defaultCooldown
    }

    public mutating func setEnabled(_ enabled: Bool, for kind: ProactiveMessageKind) {
        var set = Set(disabledKinds)
        if enabled { set.remove(kind.rawValue) } else { set.insert(kind.rawValue) }
        disabledKinds = set.sorted()
    }

    public mutating func setDailyLimit(_ limit: Int, for kind: ProactiveMessageKind) {
        dailyLimitByKind[kind.rawValue] = max(0, limit)
    }

    public mutating func setCooldown(_ seconds: TimeInterval, for kind: ProactiveMessageKind) {
        cooldownByKind[kind.rawValue] = max(0, seconds)
    }
}

/// 配置的存取口径。
///
/// 解析失败时回退到 standard 而不是抛错：预算配置坏掉不应该让 App 起不来，
/// 回到默认值至少行为是安全且可预期的。
public enum ProactiveBudgetConfigCodec {

    public static func encode(_ config: ProactiveBudgetConfig) -> String? {
        try? DayCueJSON.encodeToString(config)
    }

    public static func decode(_ raw: String?) -> ProactiveBudgetConfig {
        guard let raw, !raw.isEmpty else { return .standard }
        return (try? DayCueJSON.decode(ProactiveBudgetConfig.self, from: raw)) ?? .standard
    }
}

/// 设置项的 key。放在这里让界面与后台任务用同一个字符串。
public enum ProactiveSettingsKey {
    public static let config = "proactive.budget.config"
}

public struct ProactiveBudgetRequest: Equatable, Sendable {

    public var kind: ProactiveMessageKind
    public var dedupeKey: String
    /// 期望发出的时刻。早于 now 时会被顶到 now，绝不在过去发消息。
    public var scheduledAt: Date
    public var expiresAt: Date?
    public var targetRef: String?
    /// 覆盖配置里的冷却时间。地点规则自带 cooldown_seconds，用它而不是全局值。
    public var cooldownOverride: TimeInterval?
    /// 当前账本。调用方按需要取一段（跨零点的冷却需要包含前一天）。
    public var ledger: [ProactiveMessageRecord]
    public var now: Date
    public var timeZone: TimeZone
    public var config: ProactiveBudgetConfig

    public init(
        kind: ProactiveMessageKind,
        dedupeKey: String,
        scheduledAt: Date,
        expiresAt: Date? = nil,
        targetRef: String? = nil,
        cooldownOverride: TimeInterval? = nil,
        ledger: [ProactiveMessageRecord] = [],
        now: Date,
        timeZone: TimeZone,
        config: ProactiveBudgetConfig = .standard
    ) {
        self.kind = kind
        self.dedupeKey = dedupeKey
        self.scheduledAt = scheduledAt
        self.expiresAt = expiresAt
        self.targetRef = targetRef
        self.cooldownOverride = cooldownOverride
        self.ledger = ledger
        self.now = now
        self.timeZone = timeZone
        self.config = config
    }
}

public enum ProactiveBudgetDecision: Equatable, Sendable {

    /// 允许发出。at 可能因为静默时段被顺延到未来。
    case deliver(at: Date, reason: String)
    /// 不发。reason 是中文原因，界面直接展示。
    case suppressed(reason: String)

    public var isSuppressed: Bool {
        if case .suppressed = self { return true }
        return false
    }

    public var deliveryDate: Date? {
        if case let .deliver(at, _) = self { return at }
        return nil
    }

    public var reason: String {
        switch self {
        case let .deliver(_, reason): return reason
        case let .suppressed(reason): return reason
        }
    }
}

public enum ProactiveBudget {

    /// 判断一条主动消息现在能不能发。
    public static func evaluate(_ request: ProactiveBudgetRequest) -> ProactiveBudgetDecision {
        let config = request.config

        guard config.isEnabled(kind: request.kind) else {
            return .suppressed(reason: "「\(request.kind.displayName)」已经在设置里关掉了，不会主动提醒。")
        }

        // 迟到的排程（App 没运行时到点）不应该在过去发，最早只能是现在。
        var deliveryAt = max(request.scheduledAt, request.now)

        if let expiresAt = request.expiresAt, expiresAt <= request.now {
            return .suppressed(
                reason: "这条「\(request.kind.displayName)」已经过期（有效期到 \(localText(expiresAt, request.timeZone))），不再打扰。"
            )
        }

        // 去重：同一把 dedupe_key 只要已经排过或发过，就不再发第二次。
        if request.ledger.contains(where: { $0.dedupeKey == request.dedupeKey && $0.state.consumesBudget }) {
            return .suppressed(reason: "同一件事已经排过或发过了，不会重复打扰。")
        }

        // 静默时段：顺延，不丢弃。
        var deferredReason: String?
        if isQuiet(deliveryAt, windows: config.quietWindows, timeZone: request.timeZone) {
            guard let shifted = nextAllowedTime(
                after: deliveryAt,
                windows: config.quietWindows,
                timeZone: request.timeZone
            ) else {
                return .suppressed(reason: "现在是静默时段，但无法推算出可提醒的时刻，先不发出。")
            }
            deferredReason = "现在是静默时段，已顺延到 \(localText(shifted, request.timeZone)) 再提醒。"
            deliveryAt = shifted
            // 顺延之后可能已经越过了有效期，那就没有发的必要了。
            if let expiresAt = request.expiresAt, expiresAt <= deliveryAt {
                return .suppressed(reason: "顺延到静默时段结束会超过有效期，这条提醒作废。")
            }
        }

        // 冷却：同类（或地点规则自己的冷却）距上次真正发出不足时长就不发。
        let cooldown = request.cooldownOverride ?? config.cooldown(for: request.kind)
        if cooldown > 0, let last = lastDelivered(kind: request.kind, in: request.ledger) {
            let elapsed = deliveryAt.timeIntervalSince(last)
            if elapsed < cooldown {
                let remaining = Int(ceil((cooldown - elapsed) / 60))
                return .suppressed(
                    reason: "距离上一次「\(request.kind.displayName)」提醒还不到冷却时间，约 \(max(remaining, 1)) 分钟后才能再提醒。"
                )
            }
        }

        // 每日预算：按发出时刻所在的自然日统计，跨零点自然从 0 开始。
        let limit = config.dailyLimit(for: request.kind)
        if limit <= 0 {
            return .suppressed(reason: "「\(request.kind.displayName)」的每日预算是 0，不会主动提醒。")
        }
        let used = consumedCount(
            kind: request.kind,
            onLocalDayOf: deliveryAt,
            timeZone: request.timeZone,
            ledger: request.ledger
        )
        if used >= limit {
            return .suppressed(
                reason: "今天的「\(request.kind.displayName)」主动提醒已经用满 \(limit) 条，剩下的留到明天。"
            )
        }

        if let deferredReason {
            return .deliver(at: deliveryAt, reason: deferredReason)
        }
        return .deliver(at: deliveryAt, reason: "可以提醒。")
    }

    // MARK: - 判定辅助（都是纯函数）

    public static func isQuiet(_ date: Date, windows: [ProactiveQuietWindow], timeZone: TimeZone) -> Bool {
        let minutes = GeoRuleEvaluator.minutesOfDay(date, timeZone: timeZone)
        return windows.contains { $0.contains(minutesOfDay: minutes) }
    }

    /// 找到下一个不在任何静默时段内的时刻。
    ///
    /// 加迭代上限是为了防止两个互相重叠的时段让循环转不出去；
    /// 转不出去时返回 nil，调用方按「无法推算」处理，而不是死循环。
    public static func nextAllowedTime(
        after date: Date,
        windows: [ProactiveQuietWindow],
        timeZone: TimeZone
    ) -> Date? {
        var candidate = date
        for _ in 0..<8 {
            let minutes = GeoRuleEvaluator.minutesOfDay(candidate, timeZone: timeZone)
            guard let window = windows.first(where: { $0.contains(minutesOfDay: minutes) }) else {
                return candidate
            }
            guard let boundary = window.nextEndDate(after: candidate, timeZone: timeZone), boundary > candidate else {
                return nil
            }
            candidate = boundary
        }
        return nil
    }

    /// 某类消息最近一次真正发出的时刻。
    public static func lastDelivered(kind: ProactiveMessageKind, in ledger: [ProactiveMessageRecord]) -> Date? {
        ledger
            .filter { $0.kind == kind && $0.state == .delivered }
            .compactMap { $0.effectiveAt }
            .max()
    }

    /// 某个自然日里已经占用预算的条数（pending + delivered）。
    public static func consumedCount(
        kind: ProactiveMessageKind,
        onLocalDayOf date: Date,
        timeZone: TimeZone,
        ledger: [ProactiveMessageRecord]
    ) -> Int {
        let targetDay = RFC3339.localDateString(from: date, timeZone: timeZone)
        return ledger.filter { record in
            guard record.kind == kind, record.state.consumesBudget else { return false }
            guard let effectiveAt = record.effectiveAt else { return false }
            return RFC3339.localDateString(from: effectiveAt, timeZone: timeZone) == targetDay
        }.count
    }

    /// 当天起点（当地 00:00）的绝对时刻。取账本时用它当 since，正好覆盖整个自然日。
    public static func startOfLocalDay(for date: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    private static func localText(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
