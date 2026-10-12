import Foundation

/// 契约里的时间有三种写法，必须分开解析，不能一把梭当 Date：
/// 1. 绝对时刻："2026-10-12T12:00:00Z"（UTC 字符串，直接当不透明字符串存库）
/// 2. 墙面时间："2026-10-12T20:00:00"（没有时区，属于用户所在时区）
/// 3. 纯日期："2026-10-16"
public enum RFC3339 {

    /// 解析墙面时间（无时区）为 Date，需要调用方给出时区。
    /// 解析失败返回 nil，绝不返回「猜一个」的时间。
    public static func date(fromLocal string: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: string) { return d }
        }
        return nil
    }

    /// 解析绝对时刻（带 Z 或偏移）。
    public static func date(fromUTC string: String) -> Date? {
        if let d = ISO8601DateFormatter.dayCueUTC.date(from: string) { return d }
        // 后端也可能返回带小数秒的形式，多试一种；仍然失败就返回 nil。
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
    }

    /// Date -> 墙面时间字符串（秒精度，无时区）。
    public static func localString(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Date -> UTC RFC3339 字符串。
    public static func utcString(from date: Date) -> String {
        ISO8601DateFormatter.dayCueUTC.string(from: date)
    }

    /// YYYY-MM-DD 形式的本地日期串。
    public static func localDateString(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 打包 payload 用的 JSON 编解码器。
///
/// 时间在契约里本来就是字符串，所以这里不需要 Date 策略。
/// 用计算属性而不是共享单例：JSONEncoder/JSONDecoder 不是设计给多线程共用的，
/// 而这里会被主线程与后台上传两条路径同时用到。构造开销可以忽略。
public enum DayCueJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // sortedKeys 让同一个 payload 每次序列化结果一致，便于比对与做快照。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder { JSONDecoder() }

    public static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw DayCueJSONError.notUTF8
        }
        return s
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw DayCueJSONError.notUTF8
        }
        return try decoder.decode(type, from: data)
    }
}

public enum DayCueJSONError: Error, Equatable {
    case notUTF8
}
