import Foundation

// 云同步实体的规范化载荷。
//
// 服务端只把 payload 当不透明 JSON 存（Go 侧是 json.RawMessage / JSONB），
// 所以「哪些字段参与同步」完全由客户端定义。这里用一个大而全的可选字段结构体，
// 而不是按类型各写一套：合并、比较、逐字段裁决都需要在**同一套表示**上做，
// 各写一套迟早会分叉。
//
// 所有字段都是可选，nil 的键在编码时被省略（Codable 对 optional 的默认行为），
// 因此不同实体类型用同一个类型也不会互相污染。

/// 一个 JSON 值的自描述表示。
///
/// 不用 JSONSerialization/Any 的原因：Any 不是 Sendable，且 NSNumber 在
/// true/false 与 1/0 之间来回转换会让 Bool 字段解码失败。这里显式建型，
/// 冲突字段合并时才不会出现「本地选服务端，结果把布尔值写成数字」。
public enum SyncJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SyncJSONValue])
    case object([String: SyncJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SyncJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SyncJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// 给人看的字符串。用于冲突页展示「本地 vs 服务端」的取值。
    public var displayText: String {
        switch self {
        case let .string(value): return value
        case let .number(value):
            // 3.0 显示成 3：整数型字段不该在界面上显示小数尾巴。
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case let .bool(value): return value ? "是" : "否"
        case let .array(value): return value.map(\.displayText).joined(separator: "、")
        case let .object(value):
            return value.keys.sorted().map { "\($0)=\(value[$0]?.displayText ?? "")" }.joined(separator: "、")
        case .null: return "（空）"
        }
    }
}

/// 云同步的实体载荷。字段名即 JSON 键名，同时也是协议的一部分。
public struct SyncEntityPayload: Codable, Equatable, Sendable {
    // 任务
    public var title: String?
    public var detail: String?
    public var status: String?
    public var dueKind: String?
    public var dueLocal: String?
    public var dueUTC: String?
    public var timezone: String?
    public var remindLocal: String?
    public var remindUTC: String?
    public var courseHint: String?
    public var originCaptureId: String?
    public var originItemId: String?

    // 笔记
    public var body: String?
    public var tags: [String]?
    public var originKind: String?
    public var userEdited: Bool?
    public var occurredAt: String?

    // 记录（capture）
    public var kind: String?
    public var rawText: String?
    public var transcript: String?
    public var ocrText: String?
    public var mediaPath: String?
    public var recordedAt: String?
    public var recordedTimezone: String?

    // 课程
    public var name: String?
    public var teacher: String?
    public var location: String?
    public var term: String?
    public var color: String?
    public var followUpEnabled: Bool?
    public var followUpDelayMinutes: Int?

    // 记忆
    public var category: String?
    public var statement: String?
    public var sourceKind: String?
    public var confidence: Double?
    public var sourceRef: String?
    public var revision: Int?
    public var effectiveFrom: String?
    public var effectiveTo: String?

    public init() {}
}

/// 载荷的编解码与字段级合并。
public enum SyncPayloadCodec {

    /// 规范化 JSON 字符串。DayCueJSON 已开启 sortedKeys，同一内容每次结果一致，
    /// 这样内容指纹才能被当作「有没有变」的判据。
    public static func json(_ payload: SyncEntityPayload) throws -> String {
        try DayCueJSON.encodeToString(payload)
    }

    public static func decode(_ json: String) throws -> SyncEntityPayload {
        try DayCueJSON.decode(SyncEntityPayload.self, from: json)
    }

    /// 载荷 -> 键值字典。用于按字段分组比较与合并。
    public static func dictionary(_ payload: SyncEntityPayload) throws -> [String: SyncJSONValue] {
        let data = try DayCueJSON.encoder.encode(payload)
        return try DayCueJSON.decoder.decode([String: SyncJSONValue].self, from: data)
    }

    public static func payload(from dictionary: [String: SyncJSONValue]) throws -> SyncEntityPayload {
        let data = try DayCueJSON.encoder.encode(dictionary)
        return try DayCueJSON.decoder.decode(SyncEntityPayload.self, from: data)
    }

    /// 把某一组键的取值序列化成可比较的字符串；整组都缺省时返回 nil。
    public static func groupValue(
        _ dictionary: [String: SyncJSONValue],
        keys: [String]
    ) -> String? {
        var subset: [String: SyncJSONValue] = [:]
        for key in keys {
            if let value = dictionary[key], value != .null {
                subset[key] = value
            }
        }
        guard !subset.isEmpty else { return nil }
        guard let data = try? DayCueJSON.encoder.encode(subset) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 把 other 的某一组键覆盖到 base 上；other 缺的键要从 base 里删掉，
    /// 否则「服务端把备注清空了」会被 local 的旧值悄悄盖回去。
    public static func merging(
        _ base: [String: SyncJSONValue],
        with other: [String: SyncJSONValue],
        keys: [String]
    ) -> [String: SyncJSONValue] {
        var merged = base
        for key in keys {
            if let value = other[key] {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        return merged
    }

    /// 队列条目的内容指纹。删除与覆盖刻意用不同前缀，避免「删除一条内容恰好
    /// 与某条 upsert 相同」被误判成没变化。
    public static func changeHash(operation: SyncChangeOperation, payloadJSON: String?) -> String {
        let material = operation.rawValue + "|" + (payloadJSON ?? "")
        return SHA256Hex.digest(material)
    }

    /// 一条本地实体当前的内容指纹（不含删除标记，删除标记由操作类型承担）。
    public static func contentHash(_ payload: SyncEntityPayload) throws -> String {
        SHA256Hex.digest(try json(payload))
    }
}
