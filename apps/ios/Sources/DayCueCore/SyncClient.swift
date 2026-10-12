import Foundation

// 云同步客户端：/v1/sync/push、/v1/sync/pull、/v1/devices。
//
// 只做三件事：拼请求、解响应、把失败翻译成「能不能重试」明确的类别。
// 所有「失败之后怎么办」的决策（退避、停止重试、要求重新登录）都留给重放器，
// 这样重试策略只有一处，也才能在测试里用假客户端替换掉网络。
//
// 令牌失效（401）必须与网络失败区分开：前者重试多少次都没用，只能请用户重新登录。

/// 同步客户端失败分类。
public enum SyncClientError: Error, Equatable {
    /// 本机没有登录令牌。**不允许**走到发请求这一步。
    case notSignedIn
    /// 令牌无效或账号已删除。进入「需要重新登录」，不是重试。
    case unauthorized
    /// 网络类失败（断网、超时、服务端 5xx、可重试的契约错误）。可以退避重试。
    case retryable(String)
    /// 服务端明确拒绝（请求本身不合法）。重复请求没有意义。
    case rejected(code: String, message: String)
    /// 无法归类：响应格式不对、地址不合法等。
    case unexpected(String)

    public var isUnauthorized: Bool { self == .unauthorized }

    public var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }

    public var userFacingMessage: String {
        switch self {
        case .notSignedIn: return "未登录，云同步未启用。"
        case .unauthorized: return "登录状态已失效，请重新登录后再同步。"
        case let .retryable(detail): return "网络不可用，已保留本地改动，稍后自动重试。" + (detail.isEmpty ? "" : "（\(detail)）")
        case let .rejected(_, message): return "服务端拒绝了这个请求：" + message
        case let .unexpected(detail): return "同步失败：" + detail
        }
    }
}

// MARK: - 请求 / 响应类型

/// 一条要推送的变更。字段名与服务端 syncsvc.PushItem 对齐。
public struct SyncPushItem: Encodable, Equatable, Sendable {
    public var type: String
    public var id: String
    public var baseVersion: Int64
    /// 删除时为 nil，服务端据此写墓碑。
    public var payload: SyncEntityPayload?
    public var updatedAt: String
    public var deleted: Bool

    public init(
        type: String,
        id: String,
        baseVersion: Int64,
        payload: SyncEntityPayload?,
        updatedAt: String,
        deleted: Bool
    ) {
        self.type = type
        self.id = id
        self.baseVersion = baseVersion
        self.payload = payload
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey {
        case type, id, payload, deleted
        case baseVersion = "base_version"
        case updatedAt = "updated_at"
    }
}

struct SyncPushRequest: Encodable {
    var items: [SyncPushItem]
}

/// 一条变更的结算结果。
public struct SyncPushResult: Decodable, Equatable, Sendable {
    public var type: String
    public var id: String
    /// accepted / conflict / rejected。用字符串而不是枚举：出现没见过的取值时
    /// 应当当作「不能自动处理」，而不是解码失败把整批结果丢掉。
    public var outcome: String
    public var version: Int64?
    public var serverVersion: Int64?
    public var serverDeleted: Bool?
    /// 冲突时服务端的内容。保存原始 JSON 值，避免我们没建模的字段被丢掉。
    public var serverPayload: SyncJSONValue?
    public var reason: String?

    public var isAccepted: Bool { outcome == "accepted" }
    public var isConflict: Bool { outcome == "conflict" }
    public var isRejected: Bool { outcome == "rejected" }

    enum CodingKeys: String, CodingKey {
        case type, id, outcome, version, reason
        case serverVersion = "server_version"
        case serverDeleted = "server_deleted"
        case serverPayload = "server_payload"
    }

    /// 显式构造器：假客户端与测试需要直接造结算结果（Decodable 的 init 覆盖不了）。
    public init(
        type: String,
        id: String,
        outcome: String,
        version: Int64? = nil,
        serverVersion: Int64? = nil,
        serverDeleted: Bool? = nil,
        serverPayload: SyncJSONValue? = nil,
        reason: String? = nil
    ) {
        self.type = type
        self.id = id
        self.outcome = outcome
        self.version = version
        self.serverVersion = serverVersion
        self.serverDeleted = serverDeleted
        self.serverPayload = serverPayload
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        outcome = try container.decode(String.self, forKey: .outcome)
        version = try container.decodeIfPresent(Int64.self, forKey: .version)
        serverVersion = try container.decodeIfPresent(Int64.self, forKey: .serverVersion)
        serverDeleted = try container.decodeIfPresent(Bool.self, forKey: .serverDeleted)
        // 服务端内容解不出来时按「没有内容」处理：宁可让用户看到一版缺失，
        // 也不能因为一条坏 payload 让整批结算结果解码失败。
        serverPayload = (try? container.decodeIfPresent(SyncJSONValue.self, forKey: .serverPayload)) ?? nil
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

struct SyncPushResponse: Decodable {
    var results: [SyncPushResult]
}

/// 一条服务端变更。
public struct SyncPullChange: Decodable, Equatable, Sendable {
    public var type: String
    public var id: String
    public var version: Int64
    public var updatedAt: String
    public var deleted: Bool
    public var tombstone: Bool
    public var payload: SyncJSONValue?

    public var entityType: SyncEntityType? { SyncEntityType(rawValue: type) }
    public var isDeletion: Bool { deleted || tombstone }

    enum CodingKeys: String, CodingKey {
        case type, id, version, deleted, tombstone, payload
        case updatedAt = "updated_at"
    }

    /// 显式构造器：假客户端与测试需要直接造一条服务端变更。
    public init(
        type: String,
        id: String,
        version: Int64,
        updatedAt: String,
        deleted: Bool = false,
        tombstone: Bool = false,
        payload: SyncJSONValue? = nil
    ) {
        self.type = type
        self.id = id
        self.version = version
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.tombstone = tombstone
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        tombstone = try container.decodeIfPresent(Bool.self, forKey: .tombstone) ?? false
        payload = (try? container.decodeIfPresent(SyncJSONValue.self, forKey: .payload)) ?? nil
    }
}

/// 一页增量拉取结果。
public struct SyncPullPage: Decodable, Equatable, Sendable {
    public var changes: [SyncPullChange]
    public var cursor: String
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case changes, cursor
        case hasMore = "has_more"
    }

    public init(changes: [SyncPullChange] = [], cursor: String, hasMore: Bool = false) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// 设备登记载荷。字段名与服务端 devicePayload 对齐。
///
/// id 为 nil 时由服务端生成（服务端会拒绝未知字段，所以 nil 必须整键省略）。
public struct SyncDeviceRegistration: Encodable, Equatable, Sendable {
    public var id: String?
    public var platform: String
    public var name: String
    /// 键存在表示「已知」，值表示可用与否；键不存在表示「未知」。
    /// 服务端的 capabilities 是 map[string]bool，表达不了 unknown，所以只能靠缺键。
    public var capabilities: [String: Bool]
    public var pushToken: String?

    public init(
        id: String? = nil,
        platform: String,
        name: String,
        capabilities: [String: Bool],
        pushToken: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.capabilities = capabilities
        self.pushToken = pushToken
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, name, capabilities
        case pushToken = "push_token"
    }
}

public struct SyncDeviceResponse: Decodable, Equatable, Sendable {
    public var id: String
    public var platform: String
    public var name: String
    public var capabilities: [String: Bool]
    public var lastSeenAt: String?
    public var createdAt: String?
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, name, capabilities
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - 协议

/// 重放器依赖的同步客户端。抽成协议是为了在测试里注入假客户端，
/// 断言「调用了几次、推了什么载荷」。
public protocol SyncClientProtocol: AnyObject {
    func push(_ items: [SyncPushItem]) async throws -> [SyncPushResult]
    func pull(cursor: String?, limit: Int) async throws -> SyncPullPage
    func registerDevice(_ registration: SyncDeviceRegistration) async throws -> SyncDeviceResponse
}

// MARK: - 真实实现

public final class SyncClient: SyncClientProtocol {

    private let transport: HTTPTransport
    private let baseURLProvider: () -> String
    private let tokenProvider: () -> String?
    private let clientIdentifier: String

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        baseURLProvider: @escaping () -> String,
        tokenProvider: @escaping () -> String?,
        clientIdentifier: String = "daycue-ios/0.1.0"
    ) {
        self.transport = transport
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.clientIdentifier = clientIdentifier
    }

    public func push(_ items: [SyncPushItem]) async throws -> [SyncPushResult] {
        let body = try encode(SyncPushRequest(items: items))
        let response = try await send(method: .post, path: "/v1/sync/push", body: body, timeout: 60)
        return try decode(SyncPushResponse.self, from: response).results
    }

    public func pull(cursor: String?, limit: Int) async throws -> SyncPullPage {
        var path = "/v1/sync/pull"
        var query: [String] = []
        if let cursor, !cursor.isEmpty {
            query.append("cursor=" + (cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor))
        }
        let clamped = max(1, min(limit, 500))
        query.append("limit=\(clamped)")
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        let response = try await send(method: .get, path: path, body: nil, timeout: 60)
        return try decode(SyncPullPage.self, from: response)
    }

    public func registerDevice(_ registration: SyncDeviceRegistration) async throws -> SyncDeviceResponse {
        let body = try encode(registration)
        let response = try await send(method: .post, path: "/v1/devices", body: body, timeout: 30)
        return try decode(SyncDeviceResponse.self, from: response)
    }

    // MARK: - 内部

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try DayCueJSON.encoder.encode(value)
        } catch {
            throw SyncClientError.unexpected("本地数据无法序列化：" + error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try DayCueJSON.decoder.decode(type, from: response.body)
        } catch {
            throw SyncClientError.unexpected("服务响应无法解析：" + error.localizedDescription)
        }
    }

    private func send(
        method: HTTPMethod,
        path: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        // 未登录绝不发请求：这既是产品要求（完全本地可用、不弹窗），
        // 也避免拿一个空令牌去换一个必然的 401。
        guard let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw SyncClientError.notSignedIn
        }
        let rawBase = baseURLProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty else { throw SyncClientError.unexpected("服务地址为空") }
        let base = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        guard let url = URL(string: base + path) else {
            throw SyncClientError.unexpected("服务地址不合法：" + rawBase)
        }

        var headers: [String: String] = [
            "X-DayCue-Client": clientIdentifier,
            "Accept": "application/json",
            "Authorization": "Bearer " + token
        ]
        if body != nil { headers["Content-Type"] = "application/json" }

        let request = HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: timeout)
        do {
            let response = try await transport.send(request)
            guard response.isSuccess else { throw Self.mapHTTPFailure(response) }
            return response
        } catch let error as SyncClientError {
            throw error
        } catch let error as DayCueAPIError {
            throw Self.mapAPIError(error)
        } catch {
            throw SyncClientError.retryable(error.localizedDescription)
        }
    }

    static func mapHTTPFailure(_ response: HTTPResponse) -> SyncClientError {
        if response.statusCode == 401 { return .unauthorized }
        if let errorResponse = try? DayCueJSON.decoder.decode(ErrorResponse.self, from: response.body) {
            if errorResponse.error.code == .unauthorized { return .unauthorized }
            if errorResponse.error.retryable { return .retryable(errorResponse.error.message) }
            return .rejected(code: errorResponse.error.code.rawValue, message: errorResponse.error.message)
        }
        if (500...599).contains(response.statusCode) {
            return .retryable("服务返回 \(response.statusCode)")
        }
        return .unexpected("服务返回了非预期状态码 \(response.statusCode)")
    }

    static func mapAPIError(_ error: DayCueAPIError) -> SyncClientError {
        switch error {
        case .networkUnreachable, .timedOut:
            return .retryable(error.userFacingMessage)
        case let .server(code, message, retryable, _, httpStatus):
            if httpStatus == 401 || code == .unauthorized { return .unauthorized }
            if retryable { return .retryable(message) }
            return .rejected(code: code.rawValue, message: message)
        case .cancelled:
            return .unexpected("请求已取消")
        case .invalidBaseURL:
            return .unexpected(error.userFacingMessage)
        case .decodingFailed, .encodingFailed, .unexpectedStatus:
            return .unexpected(error.userFacingMessage)
        }
    }
}
