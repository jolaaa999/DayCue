import Foundation

/// 记录与笔记的展示文案。
///
/// 为什么放在 Core 而不是各个 View 里：同一个时间、同一个「来源」标签会在
/// 笔记列表、笔记详情、记录列表、记录详情四处出现；各写一份的话，
/// 迟早会出现「列表用 UTC、详情用本地时间」这种只有对照才发现的口径不一致。
/// 这里只产出展示字符串，不碰数据库。
public enum RecordDisplay {

    /// 库里存的是 UTC RFC3339，展示时必须换到设备时区，口径与 TaskTimeDisplay 保持一致。
    /// 解析失败时原样返回：宁可显示一个原始字符串，也不猜一个看起来正常的时间。
    public static func utcText(_ utc: String, timeZone: TimeZone = .current) -> String {
        let trimmed = utc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let date = RFC3339.date(fromUTC: trimmed) else { return trimmed }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 把多行正文压成一行摘要。按字符数截断而不是字节，
    /// 中文与 emoji 都不会被切坏；空行直接丢掉，避免摘要开头是一串空白。
    public static func summary(_ text: String, maxLength: Int = 80) -> String {
        let collapsed = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    /// 详情页里「有没有内容可显示」的统一判断。空字符串与纯空白都算没有。
    public static func hasContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 笔记的展示文案。
public enum NoteDisplay {

    /// 来源文案：来源类型 +（可选）课程提示。
    /// 课程提示存在时必须露出来，否则用户无法判断这条笔记属于哪门课。
    public static func sourceText(_ note: NoteRecord) -> String {
        var text = note.originKind.displayName
        if let course = note.courseHint, !course.isEmpty {
            text += " · " + course
        }
        return text
    }

    /// 时间文案。有发生时间就同时给出「发生」与「记录」两个时刻：
    /// 只显示一个会让用户误以为这条笔记就是那一刻写下的。
    public static func timeText(_ note: NoteRecord, timeZone: TimeZone = .current) -> String {
        let created = RecordDisplay.utcText(note.createdAt, timeZone: timeZone)
        guard let occurred = note.occurredAt, !occurred.isEmpty else { return created }
        let occurredText = RecordDisplay.utcText(occurred, timeZone: timeZone)
        guard !occurredText.isEmpty, occurredText != created else { return created }
        return "发生 " + occurredText + " · 记录 " + created
    }

    public static func summaryText(_ note: NoteRecord, maxLength: Int = 80) -> String {
        guard !note.body.isEmpty else { return "（没有正文）" }
        return RecordDisplay.summary(note.body, maxLength: maxLength)
    }

    /// 规范化后的标签。空数组表示视图应当整段隐藏标签行。
    public static func tagTexts(_ note: NoteRecord) -> [String] {
        NoteTagCodec.normalize(note.tags)
    }
}

/// 原始记录的展示文案。
public enum CaptureDisplay {

    /// 类型图标名。集中一处，保证列表与详情页用的是同一套符号。
    public static func systemImageName(for kind: CaptureKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }

    public static func summaryText(_ capture: CaptureRecord, maxLength: Int = 80) -> String {
        let text = capture.effectiveText
        guard !text.isEmpty else { return "（这条记录没有文本内容）" }
        return RecordDisplay.summary(text, maxLength: maxLength)
    }

    /// 录入时刻。用 recordedAt 而不是 createdAt：
    /// 用户关心的是「什么时候记的」，createdAt 只是本机入库时间。
    public static func timeText(_ capture: CaptureRecord, timeZone: TimeZone = .current) -> String {
        RecordDisplay.utcText(capture.recordedAt, timeZone: timeZone)
    }
}
