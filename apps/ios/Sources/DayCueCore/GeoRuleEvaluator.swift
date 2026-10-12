import Foundation

// 地点规则判定。纯逻辑：不读系统时钟、不碰数据库、不发起定位请求。
//
// 产品底线（这些不是注释，是行为）：
// 1. 区域状态为 unknown（定位不可用 / 权限被拒 / 精度不足）时**绝不触发**任何规则。
//    位置拿不到就静默降级，不产生消息，也不用别的线索去猜。
// 2. 不承诺精确室内定位：这里只消费调用方给出的 inside / outside / unknown，
//    不自己算距离，也不假装知道你在楼里哪一层。
// 3. dwell 是「持续在区域内达到 min_dwell」，不是「曾经到过」。

/// 相对某个地点的区域状态。
public enum GeoRegionState: String, Codable, CaseIterable, Sendable {

    case inside
    case outside
    /// 定位不可用、权限被拒、结果不可信。它**不是** outside，两者绝不能混淆。
    case unknown

    public var displayName: String {
        switch self {
        case .inside: return "在区域内"
        case .outside: return "在区域外"
        case .unknown: return "位置未知"
        }
    }

    /// 只有明确的两种状态才能参与触发判断。
    public var isDeterminate: Bool { self != .unknown }
}

/// 一次判定的输入。所有时间都由调用方显式给出。
public struct GeoEvaluationRequest: Equatable, Sendable {

    public var rule: GeoRuleRecord
    /// 地点可能为空（规则悬挂）、已删除或未经用户确认，三种情况都不触发。
    public var place: PlaceRecord?
    /// 上一次已知的区域状态。
    public var previousState: GeoRegionState
    /// 本次的区域状态。
    public var currentState: GeoRegionState
    /// 连续处于区域内的起始时刻，dwell 判断用。
    public var insideSince: Date?
    /// 定位权限是否已授予。
    public var locationAuthorizationGranted: Bool
    /// 定位服务当前是否可用（关闭定位、飞行模式、系统定位失败都算不可用）。
    public var locationServicesAvailable: Bool
    /// 这条规则上次真正发出消息的时刻，用于冷却判断。
    public var lastDeliveredAt: Date?
    public var now: Date
    public var timeZone: TimeZone

    public init(
        rule: GeoRuleRecord,
        place: PlaceRecord? = nil,
        previousState: GeoRegionState,
        currentState: GeoRegionState,
        insideSince: Date? = nil,
        locationAuthorizationGranted: Bool,
        locationServicesAvailable: Bool,
        lastDeliveredAt: Date? = nil,
        now: Date,
        timeZone: TimeZone
    ) {
        self.rule = rule
        self.place = place
        self.previousState = previousState
        self.currentState = currentState
        self.insideSince = insideSince
        self.locationAuthorizationGranted = locationAuthorizationGranted
        self.locationServicesAvailable = locationServicesAvailable
        self.lastDeliveredAt = lastDeliveredAt
        self.now = now
        self.timeZone = timeZone
    }
}

/// 判定结果。
///
/// isSilent 单独标出来，是为了让上层的日志与调试面板能区分
/// 「正常地没到触发条件」与「因为拿不到位置而静默降级」——
/// 后者要如实告诉用户，不能假装规则在正常工作。
public enum GeoRuleDecision: Equatable, Sendable {

    case trigger(dedupeKey: String, reason: String)
    case skip(reason: String, isSilent: Bool)

    public var triggers: Bool {
        if case .trigger = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case let .trigger(_, reason): return reason
        case let .skip(reason, _): return reason
        }
    }

    public var isSilent: Bool {
        switch self {
        case .trigger: return false
        case let .skip(_, isSilent): return isSilent
        }
    }

    public var dedupeKey: String? {
        if case let .trigger(dedupeKey, _) = self { return dedupeKey }
        return nil
    }
}

/// 「HH:mm」与「HH:mm:ss」的解析。解析失败返回 nil，绝不猜时刻。
public enum GeoRuleClock {

    public static func minutes(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              hour >= 0, hour <= 23, minute >= 0, minute <= 59 else {
            return nil
        }
        return hour * 60 + minute
    }

    public static func text(minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

/// 生效星期。库里是 TEXT，这里定义唯一的编解码口径：逗号分隔的 1...7，1 表示周一。
public enum GeoRuleWeekdays {

    public static let all: [Int] = [1, 2, 3, 4, 5, 6, 7]

    public static let displayNames: [Int: String] = [
        1: "周一", 2: "周二", 3: "周三", 4: "周四", 5: "周五", 6: "周六", 7: "周日"
    ]

    /// 编码。全选或空数组写 NULL：库里只有一种「每天」的表示。
    public static func encode(_ days: [Int]) -> String? {
        let normalized = normalize(days)
        guard !normalized.isEmpty, normalized.count < 7 else { return nil }
        return normalized.map(String.init).joined(separator: ",")
    }

    /// 解析。NULL 或空串表示每天；非空但解析不出任何一天时返回空数组，
    /// 调用方据此判定「规则不生效」并如实说明，而不是当成每天。
    public static func parse(_ raw: String?) -> [Int] {
        guard let raw else { return all }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let values = trimmed
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { all.contains($0) }
        return normalize(values)
    }

    public static func normalize(_ days: [Int]) -> [Int] {
        Array(Set(days.filter { all.contains($0) })).sorted()
    }

    public static func displayText(_ raw: String?) -> String {
        if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parse(raw)
            if parsed.isEmpty { return "星期设置无效" }
            if parsed.count == 7 { return "每天" }
            return parsed.map { displayNames[$0] ?? "第\($0)天" }.joined(separator: "、")
        }
        return "每天"
    }
}

public enum GeoRuleEvaluator {

    /// 判定一条规则现在是否应该触发。
    ///
    /// 检查顺序刻意从「环境能不能信」开始，再到「规则本身有效吗」，最后才是触发条件与冷却。
    /// 这样任何一步不确定都会先返回 skip，而不是让后面某一步误判成触发。
    public static func evaluate(_ request: GeoEvaluationRequest) -> GeoRuleDecision {
        // 1. 权限。被拒就静默降级，绝不产生消息。
        guard request.locationAuthorizationGranted else {
            return .skip(
                reason: "没有定位权限，地点规则不会触发。DayCue 不会用其它线索推断你在哪里。",
                isSilent: true
            )
        }

        // 2. 位置可用性与状态确定性。unknown 绝不触发，enter/exit 也必须两边都确定才有意义。
        guard request.locationServicesAvailable else {
            return .skip(reason: "定位服务当前不可用，本次不做任何地点判断。", isSilent: true)
        }
        guard request.currentState.isDeterminate, request.previousState.isDeterminate else {
            return .skip(reason: "位置暂时无法确定，本次不触发地点规则，也不会用猜测代替。", isSilent: true)
        }

        // 3. 规则自身的生命周期。
        if request.rule.deletedAt != nil {
            return .skip(reason: "这条地点规则已经删除。", isSilent: false)
        }
        guard request.rule.enabled else {
            return .skip(reason: "这条地点规则已被关闭。", isSilent: false)
        }

        // 4. 地点必须由用户确认过。未确认的坐标只是草稿，不能拿来打扰用户。
        guard let place = request.place else {
            return .skip(reason: "规则对应的地点已不存在，先重新选择地点。", isSilent: false)
        }
        if place.deletedAt != nil {
            return .skip(reason: "规则对应的地点已经删除。", isSilent: false)
        }
        guard place.confirmedByUser else {
            return .skip(reason: "这个地点还没有被确认，规则不会触发。", isSilent: false)
        }

        // 5. 过期。
        if let expiresAt = request.rule.expiresAtUTC,
           let expiry = RFC3339.date(fromUTC: expiresAt),
           expiry <= request.now {
            return .skip(reason: "这条地点规则已经过期。", isSilent: false)
        }

        // 6. 生效星期。
        let weekdays = GeoRuleWeekdays.parse(request.rule.weekdays)
        if weekdays.isEmpty {
            return .skip(reason: "这条规则的生效星期无法识别，请重新设置后再用。", isSilent: false)
        }
        guard weekdays.contains(weekdayNumber(request.now, timeZone: request.timeZone)) else {
            return .skip(reason: "今天不在规则的生效星期里。", isSilent: false)
        }

        // 7. 生效时段。
        guard isInsideActiveWindow(request.rule, at: request.now, timeZone: request.timeZone) else {
            let from = GeoRuleClock.minutes(from: request.rule.activeFromLocal).map(GeoRuleClock.text) ?? "--:--"
            let to = GeoRuleClock.minutes(from: request.rule.activeToLocal).map(GeoRuleClock.text) ?? "--:--"
            return .skip(reason: "现在不在规则的生效时段（\(from)–\(to)）内。", isSilent: false)
        }

        // 8. 触发条件。
        switch request.rule.trigger {
        case .enter:
            guard request.previousState == .outside, request.currentState == .inside else {
                return .skip(reason: "还没有出现「从区域外进入」的变化。", isSilent: false)
            }
            return triggering(request, insideSince: nil)

        case .exit:
            guard request.previousState == .inside, request.currentState == .outside else {
                return .skip(reason: "还没有出现「从区域内离开」的变化。", isSilent: false)
            }
            return triggering(request, insideSince: nil)

        case .dwell:
            guard request.currentState == .inside else {
                return .skip(reason: "现在还不在区域内，不满足停留条件。", isSilent: false)
            }
            let requiredSeconds = max(0, request.rule.minDwellSeconds)
            if requiredSeconds > 0 {
                guard let insideSince = request.insideSince else {
                    // 不知道从什么时候开始待着，就不能声称「待够了」。
                    return .skip(reason: "还不知道你是从什么时候开始待在这里的，暂不触发。", isSilent: false)
                }
                let stayed = request.now.timeIntervalSince(insideSince)
                guard stayed >= Double(requiredSeconds) else {
                    let remaining = Int(ceil((Double(requiredSeconds) - stayed) / 60))
                    return .skip(reason: "停留时长还差约 \(max(remaining, 1)) 分钟。", isSilent: false)
                }
                return triggering(request, insideSince: insideSince)
            }
            return triggering(request, insideSince: request.insideSince)
        }
    }

    /// 触发条件已满足后，再过一道冷却。
    private static func triggering(_ request: GeoEvaluationRequest, insideSince: Date?) -> GeoRuleDecision {
        let cooldown = Double(max(0, request.rule.cooldownSeconds))
        if cooldown > 0, let last = request.lastDeliveredAt {
            let elapsed = request.now.timeIntervalSince(last)
            if elapsed < cooldown {
                let minutes = Int(ceil((cooldown - elapsed) / 60))
                return .skip(reason: "距离上次触发还不到冷却时间，约 \(max(minutes, 1)) 分钟后再判断。", isSilent: false)
            }
        }
        let key = dedupeKey(rule: request.rule, at: request.now, insideSince: insideSince, timeZone: request.timeZone)
        return .trigger(dedupeKey: key, reason: triggerReason(request))
    }

    private static func triggerReason(_ request: GeoEvaluationRequest) -> String {
        let placeName = request.place?.name ?? "这个地点"
        switch request.rule.trigger {
        case .enter: return "你刚刚进入「\(placeName)」。"
        case .exit: return "你刚刚离开「\(placeName)」。"
        case .dwell: return "你在「\(placeName)」已经停留了一会儿。"
        }
    }

    /// 去重键。
    ///
    /// enter / exit 按「规则 + 当天」去重：一天只提醒一次，跨零点自然重新计数。
    /// dwell 按「规则 + 本次连续停留的起始时刻」去重：同一次停留只提醒一次，
    /// 离开再回来则是一次新的停留，应该允许再提醒。
    public static func dedupeKey(
        rule: GeoRuleRecord,
        at now: Date,
        insideSince: Date?,
        timeZone: TimeZone
    ) -> String {
        switch rule.trigger {
        case .dwell:
            if let insideSince {
                return "geo:\(rule.id):dwell:\(RFC3339.utcString(from: insideSince))"
            }
            return "geo:\(rule.id):dwell:\(RFC3339.localDateString(from: now, timeZone: timeZone))"
        case .enter, .exit:
            return "geo:\(rule.id):\(rule.trigger.rawValue):\(RFC3339.localDateString(from: now, timeZone: timeZone))"
        }
    }

    /// 是否落在生效时段内。起止都为空表示全天；只有一个边界时视为半开区间。
    public static func isInsideActiveWindow(_ rule: GeoRuleRecord, at now: Date, timeZone: TimeZone) -> Bool {
        let from = GeoRuleClock.minutes(from: rule.activeFromLocal)
        let to = GeoRuleClock.minutes(from: rule.activeToLocal)
        if from == nil, to == nil { return true }

        let minutes = minutesOfDay(now, timeZone: timeZone)

        guard let from else {
            return minutes < (to ?? 0)
        }
        guard let to else {
            return minutes >= from
        }
        // 起止相同视为全天：用户把两个 00:00 留在那里多半是想表示「不限时段」，
        // 判成空窗口会让规则静默地永不生效，那更难排查。
        if from == to { return true }
        if from < to { return minutes >= from && minutes < to }
        // 跨零点，例如 22:00–07:00。
        return minutes >= from || minutes < to
    }

    /// 当地时间的「日内分钟数」。显式传入时区，不读系统时区。
    public static func minutesOfDay(_ date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// ISO 星期序号：1 = 周一 … 7 = 周日。
    /// Calendar 的 weekday 是 1 = 周日，所以这里做一次显式换算，避免调用点各换一次换错。
    public static func weekdayNumber(_ date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }
}
