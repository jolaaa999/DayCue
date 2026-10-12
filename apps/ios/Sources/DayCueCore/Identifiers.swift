import Foundation

/// 业务标识全部用 UUID 字符串。做成小包装而不是直接传 String，
/// 是为了让「哪里要 id、哪里要普通文本」在类型层面就分得清楚，避免参数传反。
public enum DayCueID {
    /// 生成一个新的 UUID 字符串（大写形式，便于肉眼比对，SQLite 里按 TEXT 存）。
    public static func new() -> String {
        UUID().uuidString
    }
}

/// 当前时间的统一出口。
///
/// 单独抽出来是为了让测试可以注入固定时间；时间格式只在此处定义一次，
/// 避免各处各写一份 formatter 导致解析口径不一致。
public enum DayCueClock {
    /// 当前 UTC 时刻，输出 RFC3339（秒精度，带 Z）。
    public static func nowUTCString(date: Date = Date()) -> String {
        ISO8601DateFormatter.dayCueUTC.string(from: date)
    }

    /// 当前 UTC 日期，输出 YYYY-MM-DD。用于「今天」这类不关心时刻的场景。
    public static func todayLocalDate(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else {
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

public extension ISO8601DateFormatter {
    /// 解析入口统一用这个：带时区偏移或 Z 的绝对时刻。
    static let dayCueUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// 设备当前时区对应的 IANA 名称，例如 Asia/Shanghai。
    /// 契约要求 timezone 是 IANA 名；TimeZone.identifier 正好返回这个。
    static var currentTimeZoneIdentifier: String {
        TimeZone.current.identifier
    }
}
