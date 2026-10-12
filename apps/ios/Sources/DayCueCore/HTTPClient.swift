import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
    case patch = "PATCH"
}

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200...299).contains(statusCode) }

    public var bodyText: String { String(decoding: body, as: UTF8.self) }
}

/// 传输层抽象。
///
/// 抽出来是为了两件事：单元测试可以塞一个假 transport 验证「HTTP 4xx/5xx 按契约解析」，
/// 以及以后换 URLSession 配置（后台会话）时不用改业务代码。
public protocol HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum DayCueAPIError: Error, Equatable {
    case invalidBaseURL(String)
    /// 网络不可达（断网、DNS 失败、连接被拒）
    case networkUnreachable(String)
    case timedOut
    case cancelled
    /// 后端按 contracts/v1/error.schema.json 返回的结构化错误
    case server(code: ContractError.Code, message: String, retryable: Bool, traceId: String, httpStatus: Int)
    /// 非 2xx 但不是契约错误体（例如反向代理的 HTML 错误页）
    case unexpectedStatus(status: Int, snippet: String)
    case decodingFailed(String)
    case encodingFailed(String)

    /// 模型输出非法：必须提示「已保留记录，可稍后重试」，且不得触发任何系统写操作。
    public var isModelOutputInvalid: Bool {
        if case let .server(code, _, _, _, _) = self { return code.isModelOutputInvalid }
        return false
    }

    /// 是否值得自动重试。注意：即使 retryable=true，也只在网络类原因下自动重试，
    /// invalid_request / unauthorized 这类重复请求没有任何意义。
    public var isRetryable: Bool {
        switch self {
        case .networkUnreachable, .timedOut:
            return true
        case let .server(_, _, retryable, _, _):
            // 是否重试由后端在契约里声明，客户端不自行发明规则。
            return retryable
        case .cancelled, .invalidBaseURL, .decodingFailed, .encodingFailed, .unexpectedStatus:
            return false
        }
    }

    /// 面向用户的说明。禁止把原始用户文本或 token 拼进来。
    public var userFacingMessage: String {
        switch self {
        case let .invalidBaseURL(value):
            return "服务地址不合法：\(value)"
        case .networkUnreachable:
            return "网络不可达，记录已保存在本机。"
        case .timedOut:
            return "请求超时，记录已保存在本机，可稍后重试。"
        case .cancelled:
            return "请求已取消。"
        case let .server(code, message, _, traceId, _):
            let suffix = traceId.isEmpty ? "" : "（追踪号 \(traceId)）"
            return code.userFacingMessage + " " + message + suffix
        case let .unexpectedStatus(status, _):
            return "服务返回了非预期状态码 \(status)，记录已保存在本机。"
        case .decodingFailed:
            return "服务响应无法解析，记录已保存在本机。"
        case .encodingFailed:
            return "本地数据无法序列化，请检查内容长度。"
        }
    }
}

/// 基于 URLSession 的真实实现。没有第三方依赖。
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        // 不等待网络恢复：等下去会让「离线时立刻告诉用户」变成几十秒卡死。
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw DayCueAPIError.networkUnreachable("响应不是 HTTP 响应")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as DayCueAPIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw DayCueAPIError.timedOut
            case .cancelled:
                throw DayCueAPIError.cancelled
            default:
                throw DayCueAPIError.networkUnreachable(error.localizedDescription)
            }
        } catch {
            throw DayCueAPIError.networkUnreachable(error.localizedDescription)
        }
    }
}
