import Foundation

/// 后端客户端。
///
/// 只做三件事：拼 URL、发请求、把响应翻译成契约类型或 DayCueAPIError。
/// 所有「失败之后怎么办」的决策留在调用方（outbox / 视图模型），这里不自动重试。
public struct ExtractionResult: Equatable, Sendable {
    public let response: ExtractionResponse
    /// 后端原文，直接落 extraction_proposal.payload_json，便于日后追溯与对账。
    public let rawJSON: String
}

public final class DayCueAPIClient {

    private let transport: HTTPTransport
    private let baseURLProvider: () -> String
    private let tokenProvider: () -> String?
    private let clientIdentifier: String

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        baseURLProvider: @escaping () -> String,
        tokenProvider: @escaping () -> String? = { nil },
        clientIdentifier: String = "daycue-ios/0.1.0"
    ) {
        self.transport = transport
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.clientIdentifier = clientIdentifier
    }

    // MARK: - 公开接口

    /// GET /v1/health。健康检查的响应体没有进契约，所以这里只要求 2xx 并回传原始文本，
    /// 不去猜后端返回了哪些字段。
    public func health() async throws -> String {
        let request = try makeRequest(method: .get, path: "/v1/health", timeout: 10)
        let response = try await transport.send(request)
        try validate(response)
        return response.bodyText
    }

    /// POST /v1/extractions
    public func extract(_ extractionRequest: ExtractionRequest) async throws -> ExtractionResult {
        let body: Data
        do {
            body = try DayCueJSON.encoder.encode(extractionRequest)
        } catch {
            throw DayCueAPIError.encodingFailed(error.localizedDescription)
        }

        var request = try makeRequest(method: .post, path: "/v1/extractions", timeout: 60)
        request.headers["Content-Type"] = "application/json"
        request.body = body

        let response = try await transport.send(request)
        try validate(response)

        do {
            let decoded = try DayCueJSON.decoder.decode(ExtractionResponse.self, from: response.body)
            return ExtractionResult(response: decoded, rawJSON: response.bodyText)
        } catch {
            // 2xx 但结构不符合契约：当成「服务响应无法解析」，绝不猜内容。
            throw DayCueAPIError.decodingFailed(error.localizedDescription)
        }
    }

    /// POST /v1/transcriptions，原始音频字节。
    public func transcribe(
        audioData: Data,
        language: String?,
        timezone: String
    ) async throws -> TranscriptionResponse {
        var request = try makeRequest(method: .post, path: "/v1/transcriptions", timeout: 120)
        request.headers["Content-Type"] = "audio/mp4"
        if let language, !language.isEmpty {
            request.headers["X-DayCue-Language"] = language
        }
        request.headers["X-DayCue-Timezone"] = timezone
        request.body = audioData

        let response = try await transport.send(request)
        try validate(response)

        do {
            return try DayCueJSON.decoder.decode(TranscriptionResponse.self, from: response.body)
        } catch {
            throw DayCueAPIError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - 内部

    private func makeRequest(method: HTTPMethod, path: String, timeout: TimeInterval) throws -> HTTPRequest {
        let rawBase = baseURLProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty else { throw DayCueAPIError.invalidBaseURL("（空）") }
        let base = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + suffix) else {
            throw DayCueAPIError.invalidBaseURL(rawBase)
        }

        var headers: [String: String] = [
            // 后端用这个头区分客户端来源，方便排查问题。
            "X-DayCue-Client": clientIdentifier,
            "Accept": "application/json"
        ]
        if let token = tokenProvider(), !token.isEmpty {
            headers["Authorization"] = "Bearer " + token
        }
        return HTTPRequest(method: method, url: url, headers: headers, body: nil, timeout: timeout)
    }

    private func validate(_ response: HTTPResponse) throws {
        guard response.isSuccess else {
            // 先把响应体当契约错误解析；解析不出来才是 unexpectedStatus，
            // 这样「代理返回 HTML 错误页」和「后端按契约报错」在 UI 上能区分。
            if let errorResponse = try? DayCueJSON.decoder.decode(ErrorResponse.self, from: response.body) {
                throw DayCueAPIError.server(
                    code: errorResponse.error.code,
                    message: errorResponse.error.message,
                    retryable: errorResponse.error.retryable,
                    traceId: errorResponse.error.traceId,
                    httpStatus: response.statusCode
                )
            }
            let snippet = String(response.bodyText.prefix(200))
            throw DayCueAPIError.unexpectedStatus(status: response.statusCode, snippet: snippet)
        }
    }
}
