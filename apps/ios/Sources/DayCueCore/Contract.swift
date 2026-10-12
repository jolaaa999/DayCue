import Foundation

// 本文件是 contracts/v1/*.schema.json 在 Swift 侧的镜像。
// 规则：字段名与 schema 完全一致；遇到 schema 里 additionalProperties: false 的对象，
// 解码时也只关心已声明字段，多余字段由后端保证不出现，客户端不因此报错（向前兼容）。

public enum ContractVersion {
    public static let v1 = "1.0"
}

// MARK: - 请求

public struct ExtractionRequestSource: Codable, Equatable, Sendable {
    public enum SourceType: String, Codable, Sendable {
        case text
        case asr
        case ocr
    }

    public var type: SourceType
    public var text: String
    public var language: String?

    public init(type: SourceType, text: String, language: String? = nil) {
        self.type = type
        self.text = text
        self.language = language
    }
}

public struct ExtractionClientContext: Codable, Equatable, Sendable {
    public var hasCourseSchedule: Bool?
    public var knownPlaces: [String]?

    enum CodingKeys: String, CodingKey {
        case hasCourseSchedule = "has_course_schedule"
        case knownPlaces = "known_places"
    }

    public init(hasCourseSchedule: Bool? = nil, knownPlaces: [String]? = nil) {
        self.hasCourseSchedule = hasCourseSchedule
        self.knownPlaces = knownPlaces
    }
}

public struct ExtractionRequest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var captureId: String
    public var source: ExtractionRequestSource
    public var recordedAt: String
    public var timezone: String
    public var clientContext: ExtractionClientContext?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureId = "capture_id"
        case source
        case recordedAt = "recorded_at"
        case timezone
        case clientContext = "client_context"
    }

    public init(
        captureId: String,
        source: ExtractionRequestSource,
        recordedAt: String,
        timezone: String,
        clientContext: ExtractionClientContext? = nil,
        schemaVersion: String = ContractVersion.v1
    ) {
        self.schemaVersion = schemaVersion
        self.captureId = captureId
        self.source = source
        self.recordedAt = recordedAt
        self.timezone = timezone
        self.clientContext = clientContext
    }
}

// MARK: - 解析响应

/// due 对象。注意 utc 只在 kind=datetime 时有值；date 型不允许伪造 UTC 时刻。
public struct ContractDue: Codable, Equatable, Sendable {
    public var kind: DueKind
    public var local: String?
    public var utc: String?
    public var timezone: String?

    enum CodingKeys: String, CodingKey {
        case kind, local, utc, timezone
    }

    public init(kind: DueKind, local: String? = nil, utc: String? = nil, timezone: String? = nil) {
        self.kind = kind
        self.local = local
        self.utc = utc
        self.timezone = timezone
    }
}

/// remind。null 表示没有提醒时刻，但不等于没有截止时间。
public struct ContractRemind: Codable, Equatable, Sendable {
    public enum RemindKind: String, Codable, Sendable {
        case absolute
    }

    public var kind: RemindKind
    public var local: String
    public var utc: String
    public var timezone: String

    public init(kind: RemindKind = .absolute, local: String, utc: String, timezone: String) {
        self.kind = kind
        self.local = local
        self.utc = utc
        self.timezone = timezone
    }
}

public struct ContractAmbiguity: Codable, Equatable, Sendable {
    public var code: AmbiguityCode
    public var field: String
    public var message: String

    enum CodingKeys: String, CodingKey {
        case code, field, message
    }

    public init(code: AmbiguityCode, field: String, message: String) {
        self.code = code
        self.field = field
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode = try c.decode(String.self, forKey: .code)
        code = AmbiguityCode(rawValue: rawCode)
        field = try c.decode(String.self, forKey: .field)
        message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code.rawValue, forKey: .code)
        try c.encode(field, forKey: .field)
        try c.encode(message, forKey: .message)
    }
}

public struct ContractExtractionItem: Codable, Equatable, Sendable {
    public var itemId: String
    public var kind: ProposalItemKind
    public var title: String
    public var detail: String?
    public var sourceEvidence: String
    public var dateExpression: String?
    public var due: ContractDue
    public var remind: ContractRemind?
    public var courseHint: String?
    public var placeHint: String?
    public var ambiguities: [ContractAmbiguity]
    public var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case kind
        case title
        case detail
        case sourceEvidence = "source_evidence"
        case dateExpression = "date_expression"
        case due
        case remind
        case courseHint = "course_hint"
        case placeHint = "place_hint"
        case ambiguities
        case confidence
    }

    public init(
        itemId: String,
        kind: ProposalItemKind,
        title: String,
        detail: String? = nil,
        sourceEvidence: String,
        dateExpression: String? = nil,
        due: ContractDue,
        remind: ContractRemind? = nil,
        courseHint: String? = nil,
        placeHint: String? = nil,
        ambiguities: [ContractAmbiguity] = [],
        confidence: Double? = nil
    ) {
        self.itemId = itemId
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sourceEvidence = sourceEvidence
        self.dateExpression = dateExpression
        self.due = due
        self.remind = remind
        self.courseHint = courseHint
        self.placeHint = placeHint
        self.ambiguities = ambiguities
        self.confidence = confidence
    }

    /// 出现未知歧义 code、或出现必须澄清的歧义时为 true。
    public var requiresClarification: Bool {
        ambiguities.contains { $0.code.requiresClarification }
    }

    /// 「只设了截止日」的标记。UI 据此显示「尚未设置提醒时间」，绝不能自动补一个时刻。
    public var isDeadlineOnly: Bool {
        remind == nil && ambiguities.contains { $0.code == .deadlineOnly }
    }
}

public struct ContractUsage: Codable, Equatable, Sendable {
    public var provider: String?
    public var model: String?
    public var latencyMs: Int?
    public var promptTokens: Int?
    public var completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case provider, model
        case latencyMs = "latency_ms"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }

    public init(
        provider: String? = nil,
        model: String? = nil,
        latencyMs: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.provider = provider
        self.model = model
        self.latencyMs = latencyMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct ExtractionResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var captureId: String
    public var mode: ExtractionMode
    public var items: [ContractExtractionItem]
    public var warnings: [String]
    public var usage: ContractUsage?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureId = "capture_id"
        case mode
        case items
        case warnings
        case usage
    }

    public init(
        schemaVersion: String,
        captureId: String,
        mode: ExtractionMode,
        items: [ContractExtractionItem],
        warnings: [String],
        usage: ContractUsage? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.captureId = captureId
        self.mode = mode
        self.items = items
        self.warnings = warnings
        self.usage = usage
    }
}

// MARK: - 转写响应

public struct TranscriptionResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var text: String
    public var mode: ExtractionMode
    public var language: String?
    public var durationMs: Int?
    public var warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case text
        case mode
        case language
        case durationMs = "duration_ms"
        case warnings
    }

    public init(
        schemaVersion: String,
        text: String,
        mode: ExtractionMode,
        language: String? = nil,
        durationMs: Int? = nil,
        warnings: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.text = text
        self.mode = mode
        self.language = language
        self.durationMs = durationMs
        self.warnings = warnings
    }
}

// MARK: - 错误响应

public struct ContractError: Codable, Equatable, Sendable {
    /// 与 AmbiguityCode 同理：只声明 RawRepresentable/Hashable，
    /// 编解码由 ContractError 用 rawValue 手工完成。
    public enum Code: RawRepresentable, Equatable, Hashable, Sendable {
        case invalidRequest
        case unauthorized
        case notFound
        case payloadTooLarge
        case unsupportedMediaType
        case unprocessable
        case rateLimited
        case upstreamTimeout
        case upstreamError
        case modelOutputInvalid
        case internalError
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "invalid_request": self = .invalidRequest
            case "unauthorized": self = .unauthorized
            case "not_found": self = .notFound
            case "payload_too_large": self = .payloadTooLarge
            case "unsupported_media_type": self = .unsupportedMediaType
            case "unprocessable": self = .unprocessable
            case "rate_limited": self = .rateLimited
            case "upstream_timeout": self = .upstreamTimeout
            case "upstream_error": self = .upstreamError
            case "model_output_invalid": self = .modelOutputInvalid
            case "internal": self = .internalError
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .invalidRequest: return "invalid_request"
            case .unauthorized: return "unauthorized"
            case .notFound: return "not_found"
            case .payloadTooLarge: return "payload_too_large"
            case .unsupportedMediaType: return "unsupported_media_type"
            case .unprocessable: return "unprocessable"
            case .rateLimited: return "rate_limited"
            case .upstreamTimeout: return "upstream_timeout"
            case .upstreamError: return "upstream_error"
            case .modelOutputInvalid: return "model_output_invalid"
            case .internalError: return "internal"
            case .unknown(let raw): return raw
            }
        }

        /// 模型输出非法时客户端只能提示「已保留记录，可稍后重试」，不得触发任何系统写操作。
        public var isModelOutputInvalid: Bool {
            self == .modelOutputInvalid
        }

        public var userFacingMessage: String {
            switch self {
            case .invalidRequest: return "请求内容不合法，记录已保留。"
            case .unauthorized: return "服务未授权，请检查设置里的 Bearer Token。"
            case .notFound: return "服务接口不存在，请确认版本。"
            case .payloadTooLarge: return "内容过大，请缩短或改用录音。"
            case .unsupportedMediaType: return "服务不支持该媒体类型。"
            case .unprocessable: return "无法处理这条记录，已保留可稍后重试。"
            case .rateLimited: return "请求过于频繁，已保留记录，稍后自动重试。"
            case .upstreamTimeout: return "AI 服务超时，已保留记录，可稍后重试。"
            case .upstreamError: return "AI 服务出错，已保留记录，可稍后重试。"
            case .modelOutputInvalid: return "已保留记录，可稍后重试（模型返回无法解析的结果）。"
            case .internalError: return "服务内部错误，已保留记录，可稍后重试。"
            case .unknown(let raw): return "服务返回错误（\(raw)），记录已保留。"
            }
        }
    }

    public var code: Code
    public var message: String
    public var retryable: Bool
    public var traceId: String

    enum CodingKeys: String, CodingKey {
        case code, message, retryable
        case traceId = "trace_id"
    }

    public init(code: Code, message: String, retryable: Bool, traceId: String) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.traceId = traceId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = Code(rawValue: try c.decode(String.self, forKey: .code))
        message = try c.decode(String.self, forKey: .message)
        retryable = try c.decode(Bool.self, forKey: .retryable)
        traceId = try c.decode(String.self, forKey: .traceId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code.rawValue, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encode(retryable, forKey: .retryable)
        try c.encode(traceId, forKey: .traceId)
    }
}

public struct ErrorResponse: Codable, Equatable, Sendable {
    public var error: ContractError

    public init(error: ContractError) {
        self.error = error
    }
}
