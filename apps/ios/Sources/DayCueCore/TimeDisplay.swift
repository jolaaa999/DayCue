import Foundation

/// 时间展示的唯一实现处。
///
/// 之所以集中在这里：日期型截止日（due_kind=date）本质上没有时刻，
/// 曾经很容易被某些代码路径转换成当地午夜再格式化，结果用户看到 08:00 这种假时间。
/// 这里按 due_kind 分流，任何调用方都拿不到「日期型 + 时刻」的组合。
public enum TaskTimeDisplay {

    /// 把契约里的 local 字符串规范化成用户可读的完整日期。
    ///
    /// - date 型："2026-10-16" -> "2026-10-16"（即使后端多给了 T00:00:00 也砍掉时刻）
    /// - datetime 型："2026-10-12T20:00:00" -> "2026-10-12 20:00"
    public static func dateText(_ local: String?) -> String? {
        guard let local, !local.isEmpty else { return nil }
        let datePart = String(local.prefix(10))
        guard isWellFormedDate(datePart) else { return local }
        return datePart
    }

    /// 精确到分钟：把 ISO 的 T 换成空格并截到分钟。
    public static func dateTimeText(_ local: String?) -> String? {
        guard let local, !local.isEmpty else { return nil }
        let datePart = String(local.prefix(10))
        guard isWellFormedDate(datePart) else { return local }
        guard local.count >= 16 else {
            // 只有日期没有时刻，说明后端给的是日期型内容；此时显示日期本身，
            // 不补 "00:00"，否则等于编造一个时刻。
            return datePart
        }
        let timeStart = local.index(local.startIndex, offsetBy: 11)
        let hhmm = String(local[timeStart...].prefix(5))
        return datePart + " " + hhmm
    }

    /// 按 due_kind 选择展示方式。kind=none 或没有 local 时返回 nil。
    public static func dueText(kind: DueKind, local: String?) -> String? {
        switch kind {
        case .none:
            return nil
        case .date:
            return dateText(local)
        case .datetime:
            return dateTimeText(local)
        }
    }

    /// 任务截止时间文案。
    public static func dueText(for task: TaskRecord) -> String? {
        dueText(kind: task.dueKind, local: task.dueLocal)
    }

    /// 任务提醒时间文案。没有提醒时刻就是 nil —— 调用方据此显示「尚未设置提醒时间」。
    public static func remindText(for task: TaskRecord) -> String? {
        guard task.remindLocal != nil || task.remindUTC != nil else { return nil }
        return dateTimeText(task.remindLocal)
    }

    /// 今天页行内展示：优先提醒时刻，其次截止时间。两者都有时用 " / " 连接完整日期。
    public static func scheduleSummary(for task: TaskRecord) -> String {
        let due = dueText(for: task)
        let remind = remindText(for: task)
        switch (due, remind) {
        case let (d?, r?):
            if d == r { return d }
            return "提醒 " + r + " · 截止 " + d
        case let (d?, nil):
            return "截止 " + d
        case let (nil, r?):
            return "提醒 " + r
        case (nil, nil):
            return "未设置时间"
        }
    }

    /// 严格校验 YYYY-MM-DD，避免把 "2026-10-1" 这类不完整字符串当作日期展示。
    private static func isWellFormedDate(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let chars = Array(s)
        guard chars[4] == "-", chars[7] == "-" else { return false }
        for (index, ch) in chars.enumerated() where index != 4 && index != 7 {
            guard ch.isNumber else { return false }
        }
        return true
    }
}
