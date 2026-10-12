import Foundation

// 位置事件的标准化与新鲜度判定。**纯逻辑**：不 import CoreLocation、不读系统时钟。
//
// 为什么把「新鲜度」放在 Core 而不是适配层：
// 适配层手里只有 CLLocation，它无法判断这份坐标还能不能代表「现在」。
// 而「陈旧坐标绝不触发提醒」是产品底线，必须与设备无关地可测，
// 所以判定逻辑与 CLLocation 分开，适配层只负责把系统给的东西原样递进来。

/// 定位能力。
///
/// 刻意把「权限被拒」「定位服务关闭」「尚未询问」「系统失败」拆成不同 case：
/// 它们对用户的下一步操作完全不同（去系统设置 / 打开定位 / 先授权 / 稍后重试），
/// 折叠成一个笼统的「不可用」会让界面只能给出没用的提示。
public enum LocationCapability: Equatable, Sendable {

    case available
    /// 只有「使用 App 期间」权限：前台能收到区域事件，App 没运行时收不到。
    /// 仍然可用，但必须如实告诉用户能力边界，所以单独一态而不是混进 available。
    case foregroundOnly
    case notDetermined
    case denied
    case restricted
    case servicesDisabled
    /// 系统明确失败了（区域监控注册失败、定位返回错误）。带上原因，
    /// 这样「这条规则为什么不会触发」能有一句具体的话，而不是「未知错误」。
    case failed(reason: String)

    /// 能不能在这个状态下做地点判断。
    public var isUsable: Bool {
        switch self {
        case .available, .foregroundOnly: return true
        case .notDetermined, .denied, .restricted, .servicesDisabled, .failed: return false
        }
    }

    public var displayName: String {
        switch self {
        case .available: return "定位可用"
        case .foregroundOnly: return "仅前台可用"
        case .notDetermined: return "尚未询问定位权限"
        case .denied: return "定位权限被拒绝"
        case .restricted: return "定位受系统限制"
        case .servicesDisabled: return "系统定位服务已关闭"
        case .failed: return "定位暂时不可用"
        }
    }

    /// 完全不可用时的中文原因；可用时返回 nil。
    /// 界面直接展示这句话，所以不能出现「未知错误」这种没有信息量的兜底。
    public var unavailableReason: String? {
        switch self {
        case .available, .foregroundOnly:
            return nil
        case .notDetermined:
            return "还没有获得定位权限，地点规则不会触发。请先允许 DayCue 使用定位。"
        case .denied:
            return "定位权限被拒绝了，地点规则不会触发。DayCue 不会用其它线索推断你在哪里。"
        case .restricted:
            return "定位被系统限制（例如设备管理策略或家长控制），地点规则不会触发。"
        case .servicesDisabled:
            return "系统定位服务已关闭，地点规则不会触发。请在系统设置里打开定位服务。"
        case let .failed(reason):
            return "定位暂时不可用（\(reason)），地点规则不会触发。"
        }
    }

    /// 可用但有能力边界时的中文说明；没有边界时返回 nil。
    public var limitationReason: String? {
        switch self {
        case .foregroundOnly:
            return "现在只有「使用 App 期间」的定位权限，App 没打开时系统不会把地点变化告诉 DayCue，所以这些规则只可能在你打开 App 时触发。"
        default:
            return nil
        }
    }
}

/// 一次区域状态变化的语义描述。
///
/// 事件源只产出这四种，不产出坐标：坐标属于「观测」，语义属于「事件」，
/// 两者分开才能让规则判定不依赖任何定位框架。
public enum LocationEventKind: Equatable, Sendable {

    case entered
    case exited
    /// 连续停留在区域内。insideSince 是本次连续停留的起始时刻；
    /// 它缺失时上游必须改发 .indeterminate，而不是用「现在」冒充。
    case dwell(insideSince: Date)
    /// 系统给了变化但状态无法确定（拿不到坐标、区域状态未知、定位报错）。
    case indeterminate(reason: String)

    /// 与 GeoRuleTrigger 的对应关系。无法确定时没有对应规则，因此返回 nil。
    public var trigger: GeoRuleTrigger? {
        switch self {
        case .entered: return .enter
        case .exited: return .exit
        case .dwell: return .dwell
        case .indeterminate: return nil
        }
    }

    /// 事件蕴含的「上一次状态 -> 当前状态」。
    /// enter 必然是 outside -> inside，exit 必然是 inside -> outside；
    /// 这样调用方不用自己维护上一次状态，也就不会和事件语义打架。
    public var impliedTransition: GeoRegionTransition? {
        switch self {
        case .entered: return GeoRegionTransition(previous: .outside, current: .inside)
        case .exited: return GeoRegionTransition(previous: .inside, current: .outside)
        case .dwell: return GeoRegionTransition(previous: .inside, current: .inside)
        case .indeterminate: return nil
        }
    }
}

/// 区域状态迁移。单独一个类型是为了让「上一次/这一次」成对出现，
/// 避免两个同型参数传反。
public struct GeoRegionTransition: Equatable, Sendable {

    public var previous: GeoRegionState
    public var current: GeoRegionState

    public init(previous: GeoRegionState, current: GeoRegionState) {
        self.previous = previous
        self.current = current
    }
}

/// 适配层递进来的原始观测。
///
/// 这里刻意不带任何 CoreLocation 类型：适配层负责把 CLLocation 的
/// 坐标、时间戳与水平精度拆成这三个标量，Core 才能在不依赖 iOS 框架的前提下判断它是否可信。
public struct RawLocationObservation: Equatable, Sendable {

    public var placeId: String
    public var kind: LocationEventKind
    /// 观测时刻。用 CLLocation.timestamp，而不是「回调被执行的时刻」——
    /// 后者会把一份陈旧的坐标包装成新鲜的，正是这里要防的事。
    public var observedAt: Date
    /// 水平精度（米）。系统给不出可信值时传 0 或非有限值，由判定层丢弃。
    public var horizontalAccuracyMeters: Double
    public var capability: LocationCapability
    /// 显式传入的「现在」。Core 不读系统时钟。
    public var now: Date

    public init(
        placeId: String,
        kind: LocationEventKind,
        observedAt: Date,
        horizontalAccuracyMeters: Double,
        capability: LocationCapability,
        now: Date
    ) {
        self.placeId = placeId
        self.kind = kind
        self.observedAt = observedAt
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.capability = capability
        self.now = now
    }
}

/// 新鲜度阈值。
///
/// 这些数字决定「多旧的坐标还算数」，所以集中一处并允许显式传入，
/// 测试才能给出确定结论，产品也能按需要收紧。
public struct LocationFreshnessPolicy: Equatable, Sendable {

    /// 观测时刻到「现在」的最大允许间隔（秒）。默认 2 分钟：
    /// 区域事件本来就可能有几十秒延迟，再宽松就谈不上「刚刚到达」了。
    public var maximumAgeSeconds: TimeInterval
    /// 允许的最大水平精度（米）。默认 150 米，与区域监控本身的量级一致。
    public var maximumHorizontalAccuracyMeters: Double
    /// 时间戳最多允许超前多少秒。超过就判为设备时钟异常，不拿它做判断。
    public var maximumFutureSkewSeconds: TimeInterval

    public init(
        maximumAgeSeconds: TimeInterval = 120,
        maximumHorizontalAccuracyMeters: Double = 150,
        maximumFutureSkewSeconds: TimeInterval = 30
    ) {
        self.maximumAgeSeconds = maximumAgeSeconds
        self.maximumHorizontalAccuracyMeters = maximumHorizontalAccuracyMeters
        self.maximumFutureSkewSeconds = maximumFutureSkewSeconds
    }

    public static let standard = LocationFreshnessPolicy()
}

/// 通过新鲜度检查的语义事件。
public struct LocationSemanticEvent: Equatable, Sendable {

    public var placeId: String
    public var kind: LocationEventKind
    public var observedAt: Date
    public var horizontalAccuracyMeters: Double
    /// 事件发生时的定位能力。判定层据此决定是否允许触发，
    /// 而不是让上层自己记住一个可能已经过期的权限状态。
    public var capability: LocationCapability
    public var trigger: GeoRuleTrigger
    public var transition: GeoRegionTransition
    public var insideSince: Date?

    public init(
        placeId: String,
        kind: LocationEventKind,
        observedAt: Date,
        horizontalAccuracyMeters: Double,
        capability: LocationCapability,
        trigger: GeoRuleTrigger,
        transition: GeoRegionTransition,
        insideSince: Date?
    ) {
        self.placeId = placeId
        self.kind = kind
        self.observedAt = observedAt
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.capability = capability
        self.trigger = trigger
        self.transition = transition
        self.insideSince = insideSince
    }
}

/// 被丢弃的观测。丢弃必须有名字和原因，
/// 否则「规则没触发」就无法区分「没到条件」和「位置不可信」。
public struct LocationEventDiscard: Equatable, Sendable {

    public var placeId: String
    public var reason: String
    /// 静默降级（位置不可用）为 true；规则自身原因（规则关闭等）为 false。
    public var isSilent: Bool
    public var at: Date

    public init(placeId: String, reason: String, isSilent: Bool, at: Date) {
        self.placeId = placeId
        self.reason = reason
        self.isSilent = isSilent
        self.at = at
    }
}

/// 新鲜度判定的结果。
public enum LocationEventNormalization: Equatable, Sendable {

    case accepted(LocationSemanticEvent)
    case discarded(reason: String, isSilent: Bool)

    public var event: LocationSemanticEvent? {
        if case let .accepted(event) = self { return event }
        return nil
    }

    public var isAccepted: Bool { event != nil }

    public var discardReason: String? {
        if case let .discarded(reason, _) = self { return reason }
        return nil
    }

    public var isSilent: Bool {
        if case let .discarded(_, isSilent) = self { return isSilent }
        return false
    }
}

/// 标准化与新鲜度判定。
public enum LocationEventNormalizer {

    /// 判定顺序刻意从「环境能不能信」开始：
    /// 1. 能力不可用 -> 丢弃（静默降级）。
    /// 2. 事件本身无法确定 -> 丢弃。绝不把「不知道」当成 outside。
    /// 3. 时间戳过旧或来自未来 -> 丢弃。
    /// 4. 精度不足 -> 丢弃。
    /// 只有全部通过才产出语义事件。
    public static func normalize(
        _ observation: RawLocationObservation,
        policy: LocationFreshnessPolicy = .standard
    ) -> LocationEventNormalization {

        // 1. 能力。权限被拒 / 定位关闭时必须是明确的「不可用」，不是空结果。
        guard observation.capability.isUsable else {
            let reason = observation.capability.unavailableReason
                ?? "定位当前不可用，本次不做任何地点判断。"
            return .discarded(reason: reason, isSilent: true)
        }

        // 2. 事件可判定性。
        if case let .indeterminate(reason) = observation.kind {
            return .discarded(
                reason: "位置状态无法确定（\(reason)），本次不触发地点规则，也不会用猜测代替。",
                isSilent: true
            )
        }

        // 3. 时间戳。
        let age = observation.now.timeIntervalSince(observation.observedAt)
        if age < -policy.maximumFutureSkewSeconds {
            let ahead = Int((-age).rounded())
            return .discarded(
                reason: "位置观测的时间戳比当前时间还晚 \(ahead) 秒，判定为设备时钟异常，本次不判断地点规则。",
                isSilent: true
            )
        }
        if age > policy.maximumAgeSeconds {
            let stale = Int(age.rounded())
            let limit = Int(policy.maximumAgeSeconds.rounded())
            return .discarded(
                reason: "位置观测已经过去 \(stale) 秒（上限 \(limit) 秒），这条位置太旧，已丢弃，绝不用它触发提醒。",
                isSilent: true
            )
        }

        // 4. 精度。
        let accuracy = observation.horizontalAccuracyMeters
        guard accuracy.isFinite, accuracy > 0 else {
            return .discarded(reason: "系统没有给出可用的定位精度，本次不判断地点规则。", isSilent: true)
        }
        guard accuracy <= policy.maximumHorizontalAccuracyMeters else {
            let got = Int(accuracy.rounded())
            let limit = Int(policy.maximumHorizontalAccuracyMeters.rounded())
            return .discarded(
                reason: "定位精度不足（±\(got) 米，要求 ±\(limit) 米以内），本次不触发地点规则。",
                isSilent: true
            )
        }

        guard let trigger = observation.kind.trigger,
              let transition = observation.kind.impliedTransition else {
            return .discarded(reason: "这个位置事件无法对应任何规则触发条件，已忽略。", isSilent: true)
        }

        var insideSince: Date?
        if case let .dwell(since) = observation.kind {
            insideSince = since
        }

        return .accepted(LocationSemanticEvent(
            placeId: observation.placeId,
            kind: observation.kind,
            observedAt: observation.observedAt,
            horizontalAccuracyMeters: observation.horizontalAccuracyMeters,
            capability: observation.capability,
            trigger: trigger,
            transition: transition,
            insideSince: insideSince
        ))
    }
}

/// 位置事件源。适配层实现它，Core 只通过它拿事件与能力状态。
///
/// 之所以要有这个协议：规则求值与预算判定必须能在没有定位框架的环境里测试，
/// 所以「谁来产生事件」被隔离在协议后面。
public protocol LocationEventSource: AnyObject {

    /// 当前定位能力。权限被拒 / 定位关闭时必须是明确不可用，不是空结果。
    var capability: LocationCapability { get }
    /// 已经注册监控的地点 id。注册表由此读取，避免适配层与编排层各记一份。
    var monitoredPlaceIds: Set<String> { get }
    var onSemanticEvent: ((LocationSemanticEvent) -> Void)? { get set }
    var onDiscardedEvent: ((LocationEventDiscard) -> Void)? { get set }
    var onCapabilityChange: ((LocationCapability) -> Void)? { get set }

    /// 重新读取系统权限与定位开关，并返回最新能力。
    @discardableResult
    func refreshCapability() -> LocationCapability
    func requestAuthorizationIfNeeded()
    /// 申请后台定位权限。用户不给也不报错，只是能力停留在 .foregroundOnly。
    func requestBackgroundAuthorizationIfNeeded()
    func startMonitoring(places: [PlaceRecord])
    func stopMonitoring(placeIds: [String])
    func stopAllMonitoring()
}
