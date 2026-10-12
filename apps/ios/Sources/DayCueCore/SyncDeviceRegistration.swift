import Foundation

// 设备登记与能力上报。
//
// 服务端的 device.capabilities 是 map[string]bool，表达不了「未知」这个状态。
// 因此约定：**键存在 = 已确认，值 = 可用与否；键不存在 = 客户端没上报（未知）**。
// 能力未知时如实省略该键，绝不为了「看起来完整」而填 false ——
// 那会让服务端以为设备确实收不到通知，从而放弃推送。

/// 需要上报的设备能力。
public struct DeviceCapabilities: Equatable, Sendable {
    /// 通知权限（决定能不能走 APNs 推送）。
    public var notifications: Bool?
    /// 精确定位（决定能不能做位置触发，而非仅城市级）。
    public var preciseLocation: Bool?
    /// 日历写入（决定能不能把课程写进系统日历）。
    public var calendarWrite: Bool?
    /// 语音转写（决定能不能本地转写，而不是把音频上传）。
    public var speechTranscription: Bool?

    public init(
        notifications: Bool? = nil,
        preciseLocation: Bool? = nil,
        calendarWrite: Bool? = nil,
        speechTranscription: Bool? = nil
    ) {
        self.notifications = notifications
        self.preciseLocation = preciseLocation
        self.calendarWrite = calendarWrite
        self.speechTranscription = speechTranscription
    }

    /// 全部未知。默认值必须是它：任何「猜一个」的默认都在撒谎。
    public static let unknown = DeviceCapabilities()

    public static let notificationsKey = "notifications"
    public static let preciseLocationKey = "precise_location"
    public static let calendarWriteKey = "calendar_write"
    public static let speechTranscriptionKey = "speech_transcription"

    /// 只编码已确认的能力。
    public var wire: [String: Bool] {
        var result: [String: Bool] = [:]
        if let notifications { result[Self.notificationsKey] = notifications }
        if let preciseLocation { result[Self.preciseLocationKey] = preciseLocation }
        if let calendarWrite { result[Self.calendarWriteKey] = calendarWrite }
        if let speechTranscription { result[Self.speechTranscriptionKey] = speechTranscription }
        return result
    }

    public init(wire: [String: Bool]) {
        self.notifications = wire[Self.notificationsKey]
        self.preciseLocation = wire[Self.preciseLocationKey]
        self.calendarWrite = wire[Self.calendarWriteKey]
        self.speechTranscription = wire[Self.speechTranscriptionKey]
    }

    /// 界面上如实说明「未知」与「不可用」的区别。
    public var displaySummary: String {
        func text(_ name: String, _ value: Bool?) -> String {
            switch value {
            case .some(true): return name + "可用"
            case .some(false): return name + "不可用"
            case .none: return name + "未知"
            }
        }
        return [
            text("通知", notifications),
            text("精确定位", preciseLocation),
            text("日历写入", calendarWrite),
            text("语音转写", speechTranscription)
        ].joined(separator: "、")
    }
}

/// 平台取值必须与服务端 validPlatform 一致。
public enum SyncDevicePlatform: String, Sendable {
    case ios
    case android
    case macos
    case unknown
}

/// 提供本机身份。放在 App 层实现（需要 UIDevice / APNs 令牌）。
public protocol SyncDeviceIdentityProviding: AnyObject {
    var platform: SyncDevicePlatform { get }
    var deviceName: String { get }
    /// 当前的推送令牌；没有则为 nil。
    func pushToken() async -> String?
}

/// 提供当前权限状态到能力的映射。放在 App 层实现（需要 EventKit / CoreLocation / 通知中心）。
public protocol DeviceCapabilityReporting: AnyObject {
    func currentCapabilities() async -> DeviceCapabilities
}

/// 本地 device 表的一行投影。
public struct LocalDeviceSnapshot: Equatable, Sendable {
    public var id: String
    public var platform: String
    public var name: String
    public var capabilities: [String: Bool]
    public var capabilitiesJSON: String
    public var pushToken: String?
    public var lastSeenAt: String?
    public var createdAt: String
    public var updatedAt: String

    /// 是否已经在服务端登记成功过（last_seen_at 非空即为是）。
    public var isRegistered: Bool { !(lastSeenAt ?? "").isEmpty }

    public init(
        id: String,
        platform: String,
        name: String,
        capabilities: [String: Bool],
        capabilitiesJSON: String,
        pushToken: String?,
        lastSeenAt: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.capabilities = capabilities
        self.capabilitiesJSON = capabilitiesJSON
        self.pushToken = pushToken
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension DayCueStore {

    /// 读出本机设备行。本机只有一台设备，按创建时间取第一条。
    func localDeviceSnapshot() throws -> LocalDeviceSnapshot? {
        let statement = try database.prepare(
            """
            SELECT id, platform, name, capabilities_json, push_token, last_seen_at, created_at, updated_at
            FROM device ORDER BY created_at ASC LIMIT 1;
            """
        )
        guard try statement.step() else { return nil }
        return Self.makeLocalDevice(statement)
    }

    /// 写入（或更新）本机设备行。id 是主键，重复登记走同一个 id，服务端据此做 upsert。
    func saveLocalDevice(_ snapshot: LocalDeviceSnapshot) throws {
        let statement = try database.prepare(
            """
            INSERT INTO device
              (id, account_id, platform, name, capabilities_json, push_token, last_seen_at, created_at, updated_at)
            VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              platform = excluded.platform,
              name = excluded.name,
              capabilities_json = excluded.capabilities_json,
              push_token = excluded.push_token,
              last_seen_at = excluded.last_seen_at,
              updated_at = excluded.updated_at;
            """
        )
        try statement.bind([
            .text(snapshot.id),
            .text(snapshot.platform),
            .text(snapshot.name),
            .text(snapshot.capabilitiesJSON),
            .optionalText(snapshot.pushToken),
            .optionalText(snapshot.lastSeenAt),
            .text(snapshot.createdAt),
            .text(snapshot.updatedAt)
        ])
        try statement.run()
    }

    static func makeLocalDevice(_ statement: SQLiteStatement) -> LocalDeviceSnapshot {
        let capabilitiesJSON = statement.string(3) ?? "{}"
        let capabilities = (try? DayCueJSON.decode([String: Bool].self, from: capabilitiesJSON)) ?? [:]
        return LocalDeviceSnapshot(
            id: statement.string(0) ?? "",
            platform: statement.string(1) ?? "unknown",
            name: statement.string(2) ?? "",
            capabilities: capabilities,
            capabilitiesJSON: capabilitiesJSON,
            pushToken: statement.string(4),
            lastSeenAt: statement.string(5),
            createdAt: statement.string(6) ?? "",
            updatedAt: statement.string(7) ?? ""
        )
    }
}

/// 设备登记服务。
///
/// 调用时机：CloudSyncReplayer 每轮重放开始时调用一次（已登录才会走到这里）。
/// 已登记且能力/推送令牌没变时直接跳过，避免每次重放都打一次设备接口。
public final class DeviceRegistrationService {

    private let store: DayCueStore
    private let client: SyncClientProtocol
    private let identity: SyncDeviceIdentityProviding
    private let capabilities: DeviceCapabilityReporting

    public init(
        store: DayCueStore,
        client: SyncClientProtocol,
        identity: SyncDeviceIdentityProviding,
        capabilities: DeviceCapabilityReporting
    ) {
        self.store = store
        self.client = client
        self.identity = identity
        self.capabilities = capabilities
    }

    /// 登记或更新本机设备。
    ///
    /// 客户端自己先生成一个符合服务端校验规则的设备 ID（dev_ + 32 位十六进制）并落库，
    /// 再拿去登记：这样请求成功但响应丢失时，重试是同一个 id 的 upsert，
    /// 不会在服务端留下第二台「幽灵设备」。
    @discardableResult
    public func register(at: Date) async throws -> SyncDeviceResponse {
        let now = DayCueClock.nowUTCString(date: at)
        let wire = (await capabilities.currentCapabilities()).wire
        let capabilitiesJSON = try DayCueJSON.encodeToString(wire)
        let pushToken = await identity.pushToken()

        let existing = try store.localDeviceSnapshot()
        let deviceId = existing?.id ?? Self.makeDeviceID()
        let snapshot = LocalDeviceSnapshot(
            id: deviceId,
            platform: identity.platform.rawValue,
            name: identity.deviceName,
            capabilities: wire,
            capabilitiesJSON: capabilitiesJSON,
            pushToken: pushToken,
            lastSeenAt: existing?.lastSeenAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        // 先落库再发请求：请求失败也不影响下次用同一个 id 重试。
        try store.saveLocalDevice(snapshot)

        let unchanged = existing?.isRegistered == true
            && existing?.capabilitiesJSON == capabilitiesJSON
            && existing?.pushToken == pushToken
            && existing?.platform == snapshot.platform
        if unchanged {
            return Self.response(from: snapshot)
        }

        let registration = SyncDeviceRegistration(
            id: deviceId,
            platform: identity.platform.rawValue,
            name: identity.deviceName,
            capabilities: wire,
            pushToken: pushToken
        )
        let response = try await client.registerDevice(registration)
        // 服务端可能修正 id/name；以服务端返回为准再落一次。
        try store.saveLocalDevice(LocalDeviceSnapshot(
            id: response.id,
            platform: response.platform,
            name: response.name,
            capabilities: response.capabilities,
            capabilitiesJSON: try DayCueJSON.encodeToString(response.capabilities),
            pushToken: pushToken,
            lastSeenAt: response.lastSeenAt ?? now,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        ))
        return response
    }

    static func response(from snapshot: LocalDeviceSnapshot) -> SyncDeviceResponse {
        SyncDeviceResponse(
            id: snapshot.id,
            platform: snapshot.platform,
            name: snapshot.name,
            capabilities: snapshot.capabilities,
            lastSeenAt: snapshot.lastSeenAt,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
    }

    /// 生成 dev_ + 32 位小写十六进制。长度 36，落在服务端 validOpaqueID 的 8...64 区间内。
    static func makeDeviceID() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "dev_" + String(hex.prefix(32))
    }
}
