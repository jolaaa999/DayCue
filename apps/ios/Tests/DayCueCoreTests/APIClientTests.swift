import Foundation
import XCTest
@testable import DayCueCore

/// 假传输层：把「HTTP 状态码 + 响应体」直接喂给客户端，用来验证错误分类。
private final class StubTransport: HTTPTransport {
    private let response: HTTPResponse?
    private let error: Error?
    private(set) var lastRequest: HTTPRequest?

    init(response: HTTPResponse) {
        self.response = response
        self.error = nil
    }

    init(error: Error) {
        self.response = nil
        self.error = error
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lastRequest = request
        if let error { throw error }
        guard let response else { throw DayCueAPIError.networkUnreachable("stub 未配置响应") }
        return response
    }
}

final class APIClientTests: XCTestCase {

    private func makeClient(transport: HTTPTransport) -> DayCueAPIClient {
        DayCueAPIClient(
            transport: transport,
            baseURLProvider: { "http://127.0.0.1:8787" },
            tokenProvider: { "secret-token" }
        )
    }

    func testExtractionRequestCarriesHeadersAndDecodesResponse() async throws {
        let body = #"""
        {
          "schema_version": "1.0",
          "capture_id": "cap_1",
          "mode": "live",
          "items": [],
          "warnings": ["样例告警"]
        }
        """#
        let transport = StubTransport(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(body.utf8)
        ))
        let client = makeClient(transport: transport)

        let request = ExtractionRequest(
            captureId: "cap_1",
            source: ExtractionRequestSource(type: .text, text: "明晚八点复习"),
            recordedAt: "2026-10-11T13:00:00Z",
            timezone: "Asia/Shanghai"
        )
        let result = try await client.extract(request)

        XCTAssertEqual(result.response.captureId, "cap_1")
        XCTAssertEqual(result.response.warnings, ["样例告警"])
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "http://127.0.0.1:8787/v1/extractions")
        XCTAssertEqual(transport.lastRequest?.method, .post)
        XCTAssertEqual(transport.lastRequest?.headers["Content-Type"], "application/json")
        XCTAssertEqual(transport.lastRequest?.headers["X-DayCue-Client"]?.isEmpty, false)
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer secret-token")
    }

    func testContractErrorIsParsedIntoStructuredFailure() async throws {
        let body = #"""
        {
          "error": {
            "code": "model_output_invalid",
            "message": "模型返回的内容无法解析为结构化候选。",
            "retryable": true,
            "trace_id": "trace_1"
          }
        }
        """#
        let transport = StubTransport(response: HTTPResponse(
            statusCode: 502,
            headers: [:],
            body: Data(body.utf8)
        ))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.health()
            XCTFail("期望抛出错误")
        } catch let error as DayCueAPIError {
            XCTAssertTrue(error.isModelOutputInvalid)
            XCTAssertTrue(error.isRetryable)
            XCTAssertTrue(error.userFacingMessage.contains("已保留记录"))
            if case let .server(code, _, retryable, traceId, status) = error {
                XCTAssertEqual(code, .modelOutputInvalid)
                XCTAssertTrue(retryable)
                XCTAssertEqual(traceId, "trace_1")
                XCTAssertEqual(status, 502)
            } else {
                XCTFail("期望 server 分支")
            }
        }
    }

    func testNonContractErrorBecomesUnexpectedStatus() async throws {
        let transport = StubTransport(response: HTTPResponse(
            statusCode: 502,
            headers: [:],
            body: Data("<html>bad gateway</html>".utf8)
        ))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.health()
            XCTFail("期望抛出错误")
        } catch let error as DayCueAPIError {
            guard case let .unexpectedStatus(status, _) = error else {
                return XCTFail("期望 unexpectedStatus，实际 \(error)")
            }
            XCTAssertEqual(status, 502)
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testNetworkFailureIsClassifiedAsUnreachableAndRetryable() async throws {
        let transport = StubTransport(error: DayCueAPIError.networkUnreachable("无法连接"))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.health()
            XCTFail("期望抛出错误")
        } catch let error as DayCueAPIError {
            XCTAssertTrue(error.isRetryable)
            XCTAssertTrue(error.userFacingMessage.contains("记录已保存在本机"))
        }
    }

    func testTranscriptionSendsRawAudioWithLanguageAndTimezoneHeaders() async throws {
        let body = #"""
        { "schema_version": "1.0", "text": "今天讲了 PV 操作", "mode": "live" }
        """#
        let transport = StubTransport(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(body.utf8)
        ))
        let client = makeClient(transport: transport)

        let response = try await client.transcribe(
            audioData: Data([0x00, 0x01, 0x02]),
            language: "zh-CN",
            timezone: "Asia/Shanghai"
        )

        XCTAssertEqual(response.text, "今天讲了 PV 操作")
        XCTAssertEqual(transport.lastRequest?.headers["Content-Type"], "audio/mp4")
        XCTAssertEqual(transport.lastRequest?.headers["X-DayCue-Language"], "zh-CN")
        XCTAssertEqual(transport.lastRequest?.headers["X-DayCue-Timezone"], "Asia/Shanghai")
        XCTAssertEqual(transport.lastRequest?.body, Data([0x00, 0x01, 0x02]))
    }

    func testInvalidBaseURLIsRejectedBeforeAnyNetworkCall() async throws {
        let transport = StubTransport(error: DayCueAPIError.networkUnreachable("不应该被调用"))
        let client = DayCueAPIClient(
            transport: transport,
            baseURLProvider: { "   " },
            tokenProvider: { nil }
        )

        do {
            _ = try await client.health()
            XCTFail("期望抛出错误")
        } catch let error as DayCueAPIError {
            guard case .invalidBaseURL = error else {
                return XCTFail("期望 invalidBaseURL，实际 \(error)")
            }
        }
    }
}
