import Foundation

// ICS（RFC5545 子集）导入。
//
// 关键约束：
// 1. 三种时间写法必须分别落到正确的 UTC —— 带 Z 的绝对时刻、带 TZID 的命名时区、
//    以及既无 TZID 又无 Z 的**本地浮动时间**（按调用方给定的时区解释）。
//    浮动时间如果被当成 UTC，跨时区导入会整体错位 8 小时。
// 2. 坏行只跳过并记 warning，绝不让整份文件导入失败；
//    同样也不能把「一条都没解析出来」当成导入成功。
// 3. 解析是纯函数：时间基准与时区都由调用方传入。

public enum ICSDateTimeKind: String, Codable, Sendable {
    /// 值以 Z 结尾，是绝对时刻。
    case utc
    /// 带 TZID 参数，按其命名时区解释。
    case zoned
    /// 无 TZID 且无 Z 的本地浮动时间，按调用方给定的时区解释。
    case floating

    public var displayName: String {
        switch self {
        case .utc: return "UTC"
        case .zoned: return "指定时区"
        case .floating: return "本地浮动时间"
        }
    }
}

public struct ICSDateTimeValue: Equatable, Sendable {

    /// 已解析出的绝对时刻。
    public var date: Date
    /// 解释这个时刻所用的时区（UTC / TZID / 调用方给的回退时区）。
    public var timeZoneIdentifier: String
    public var kind: ICSDateTimeKind
    /// 只给了日期没给时间（VALUE=DATE 或 YYYYMMDD）。
    public var isDateOnly: Bool

    public init(date: Date, timeZoneIdentifier: String, kind: ICSDateTimeKind, isDateOnly: Bool) {
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.kind = kind
        self.isDateOnly = isDateOnly
    }
}

public struct ICSRecurrenceRule: Equatable, Sendable {

    /// 原样保留（例如 WEEKLY）。第一阶段只展开 WEEKLY，其它值会如实告知。
    public var frequency: String
    public var interval: Int
    /// 1=周一 … 7=周日。
    public var byDay: [Int]
    public var until: ICSDateTimeValue?
    public var count: Int?

    public init(
        frequency: String,
        interval: Int = 1,
        byDay: [Int] = [],
        until: ICSDateTimeValue? = nil,
        count: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.until = until
        self.count = count
    }
}

public struct ICSEvent: Equatable, Sendable {

    public var uid: String?
    public var summary: String?
    public var location: String?
    public var eventDescription: String?
    public var dtStart: ICSDateTimeValue
    public var dtEnd: ICSDateTimeValue?
    public var recurrence: ICSRecurrenceRule?
    public var exDates: [ICSDateTimeValue]

    public init(
        uid: String? = nil,
        summary: String? = nil,
        location: String? = nil,
        eventDescription: String? = nil,
        dtStart: ICSDateTimeValue,
        dtEnd: ICSDateTimeValue? = nil,
        recurrence: ICSRecurrenceRule? = nil,
        exDates: [ICSDateTimeValue] = []
    ) {
        self.uid = uid
        self.summary = summary
        self.location = location
        self.eventDescription = eventDescription
        self.dtStart = dtStart
        self.dtEnd = dtEnd
        self.recurrence = recurrence
        self.exDates = exDates
    }
}

public struct ICSParseResult: Equatable, Sendable {

    public var events: [ICSEvent]
    public var warnings: [String]
    /// 无法解析而被跳过的行数。>0 时界面必须显示出来。
    public var skippedLineCount: Int

    public init(events: [ICSEvent] = [], warnings: [String] = [], skippedLineCount: Int = 0) {
        self.events = events
        self.warnings = warnings
        self.skippedLineCount = skippedLineCount
    }
}

private struct ICSProperty {
    var name: String
    var parameters: [String: String]
    var value: String
}

public enum ICSParser {

    // MARK: - 入口

    public static func parse(text: String, fallbackTimeZone: TimeZone = .current) -> ICSParseResult {
        let lines = unfold(text)
        var events: [ICSEvent] = []
        var warnings: [String] = []
        var skippedLineCount = 0
        var fields: [String: ICSProperty] = [:]
        var inEvent = false

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            guard let property = parseProperty(line) else {
                // 坏行只跳过：一份课表里混进几行垃圾不应该让整份导入失败。
                warnings.append("第 \(lineNumber) 行无法解析，已跳过：\(line)")
                skippedLineCount += 1
                continue
            }

            switch property.name {
            case "BEGIN":
                if property.value.uppercased() == "VEVENT" {
                    fields = [:]
                    inEvent = true
                }
            case "END":
                if property.value.uppercased() == "VEVENT" {
                    inEvent = false
                    let built = makeEvent(fields: fields, fallbackTimeZone: fallbackTimeZone)
                    warnings.append(contentsOf: built.warnings)
                    if let event = built.event {
                        events.append(event)
                    } else {
                        skippedLineCount += 1
                    }
                    fields = [:]
                }
            default:
                // VEVENT 之外的属性（VCALENDAR 级、VALARM 等）不参与导入。
                guard inEvent else { continue }
                if let existing = fields[property.name] {
                    // EXDATE 允许多行；合并而不是覆盖，否则会漏排要排除的那几次课。
                    var merged = existing
                    merged.value = existing.value + "," + property.value
                    fields[property.name] = merged
                } else {
                    fields[property.name] = property
                }
            }
        }

        // 文件被截断（缺少 END:VEVENT）时，把已经读到的字段尽量用起来，
        // 而不是把用户已经能看到的内容整段丢掉。
        if inEvent {
            warnings.append("文件在 VEVENT 结束前就结束了，已尝试使用已读到的字段。")
            let built = makeEvent(fields: fields, fallbackTimeZone: fallbackTimeZone)
            warnings.append(contentsOf: built.warnings)
            if let event = built.event {
                events.append(event)
            }
        }

        return ICSParseResult(events: events, warnings: warnings, skippedLineCount: skippedLineCount)
    }

    /// 折行还原（RFC5545 的 line folding）。
    /// 大学教务系统导出的 SUMMARY 经常被折成多行，不还原会把课程名截断一半。
    public static func unfold(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(line)
            if string.hasPrefix(" ") || string.hasPrefix("\t") {
                let continued = String(string.dropFirst())
                if result.isEmpty {
                    result.append(continued)
                } else {
                    result[result.count - 1] += continued
                }
            } else {
                result.append(string)
            }
        }
        return result
    }

    // MARK: - 属性

    private static func parseProperty(_ line: String) -> ICSProperty? {
        // 只有第一个冒号是「名;参数」与「值」的分隔符：值里可能含冒号（例如 http://...）。
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let head = String(line[line.startIndex..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])
        guard !head.isEmpty else { return nil }

        let segments = head.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = segments.first else { return nil }
        let name = String(first).uppercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]).uppercased()
            // 参数值可能被双引号包起来（TZID="Asia/Shanghai"）。
            let rawValue = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parameters[key] = rawValue
        }
        return ICSProperty(name: name, parameters: parameters, value: value)
    }

    /// 反斜杠转义还原：\, \; \n \\ 。必须一次扫描完成，分多次替换会把 \\n 解成换行。
    private static func unescapeText(_ value: String) -> String {
        var result = ""
        var iterator = Array(value)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            if character == "\\", index + 1 < iterator.count {
                let next = iterator[index + 1]
                switch next {
                case "n", "N":
                    result.append("\n")
                case ",":
                    result.append(",")
                case ";":
                    result.append(";")
                case "\\":
                    result.append("\\")
                default:
                    result.append(next)
                }
                index += 2
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    // MARK: - 事件

    private static func makeEvent(
        fields: [String: ICSProperty],
        fallbackTimeZone: TimeZone
    ) -> (event: ICSEvent?, warnings: [String]) {
        var warnings: [String] = []

        guard let startField = fields["DTSTART"] else {
            return (nil, ["一个 VEVENT 没有 DTSTART，已跳过这条事件。"])
        }
        guard let dtStart = parseDateTime(startField, fallbackTimeZone: fallbackTimeZone, warnings: &warnings) else {
            return (nil, warnings + ["DTSTART 无法解析：\(startField.value)，已跳过这条事件。"])
        }

        var dtEnd: ICSDateTimeValue?
        if let endField = fields["DTEND"] {
            if let parsed = parseDateTime(endField, fallbackTimeZone: fallbackTimeZone, warnings: &warnings) {
                if parsed.date >= dtStart.date {
                    dtEnd = parsed
                } else {
                    warnings.append("DTEND 早于 DTSTART，已忽略该结束时间。")
                }
            } else {
                warnings.append("DTEND 无法解析：\(endField.value)，已忽略。")
            }
        }

        var recurrence: ICSRecurrenceRule?
        if let ruleField = fields["RRULE"] {
            if let parsed = parseRecurrence(ruleField.value, fallbackTimeZone: fallbackTimeZone, warnings: &warnings) {
                recurrence = parsed
            } else {
                warnings.append("RRULE 无法解析：\(ruleField.value)，已按单次课处理。")
            }
        }

        var exDates: [ICSDateTimeValue] = []
        if let exField = fields["EXDATE"] {
            exDates = parseDateList(
                value: exField.value,
                parameters: exField.parameters,
                fallbackTimeZone: fallbackTimeZone,
                warnings: &warnings
            )
        }

        let event = ICSEvent(
            uid: fields["UID"].map { Self.unescapeText($0.value) },
            summary: fields["SUMMARY"].map { Self.unescapeText($0.value) },
            location: fields["LOCATION"].map { Self.unescapeText($0.value) },
            eventDescription: fields["DESCRIPTION"].map { Self.unescapeText($0.value) },
            dtStart: dtStart,
            dtEnd: dtEnd,
            recurrence: recurrence,
            exDates: exDates
        )
        return (event, warnings)
    }

    // MARK: - 时间

    private static func resolve(
        _ components: DateComponents,
        in timeZone: TimeZone,
        kind: ICSDateTimeKind,
        isDateOnly: Bool
    ) -> ICSDateTimeValue? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return nil }
        return ICSDateTimeValue(
            date: date,
            timeZoneIdentifier: timeZone.identifier,
            kind: kind,
            isDateOnly: isDateOnly
        )
    }

    private static func parseDateTime(
        _ field: ICSProperty,
        fallbackTimeZone: TimeZone,
        warnings: inout [String]
    ) -> ICSDateTimeValue? {
        let raw = field.value.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        let isUTC = raw.hasSuffix("Z") || raw.hasSuffix("z")
        var body = isUTC ? String(raw.dropLast()) : raw
        // 兼容少数导出器写的 "2026-09-07T08:00:00" 这种扩展格式：去掉分隔符后再按紧凑格式解析。
        body = body.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")

        var components = DateComponents()
        var isDateOnly = false
        let parts = body.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let dateComponents = parseCompactDate(String(parts[0])),
                  let timeComponents = parseCompactTime(String(parts[1])) else { return nil }
            components = dateComponents
            components.hour = timeComponents.hour
            components.minute = timeComponents.minute
            components.second = timeComponents.second
        } else {
            guard let dateComponents = parseCompactDate(body) else { return nil }
            components = dateComponents
            isDateOnly = true
        }

        if isUTC {
            guard let utc = TimeZone(identifier: "UTC") else { return nil }
            return resolve(components, in: utc, kind: .utc, isDateOnly: isDateOnly)
        }

        if let tzid = field.parameters["TZID"], !tzid.isEmpty {
            guard let zone = TimeZone(identifier: tzid) else {
                // 未知 TZID 不能猜一个时区就往下走：如实记 warning 并退回调用方给的时区。
                warnings.append("无法识别的 TZID「\(tzid)」，已按 \(fallbackTimeZone.identifier) 解释。")
                return resolve(components, in: fallbackTimeZone, kind: .floating, isDateOnly: isDateOnly)
            }
            return resolve(components, in: zone, kind: .zoned, isDateOnly: isDateOnly)
        }

        // 无 TZID 且无 Z：本地浮动时间。它描述的是「在那个地方的墙上时钟」，
        // 所以必须用调用方给定的时区解释，不能当 UTC。
        return resolve(components, in: fallbackTimeZone, kind: .floating, isDateOnly: isDateOnly)
    }

    private static func parseCompactDate(_ text: String) -> DateComponents? {
        guard text.count == 8, text.allSatisfy({ $0.isNumber }) else { return nil }
        let characters = Array(text)
        guard let year = Int(String(characters[0..<4])),
              let month = Int(String(characters[4..<6])),
              let day = Int(String(characters[6..<8])) else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private static func parseCompactTime(_ text: String) -> (hour: Int, minute: Int, second: Int)? {
        guard text.count == 6 || text.count == 4, text.allSatisfy({ $0.isNumber }) else { return nil }
        let characters = Array(text)
        guard let hour = Int(String(characters[0..<2])),
              let minute = Int(String(characters[2..<4])) else { return nil }
        let second = text.count == 6 ? (Int(String(characters[4..<6])) ?? 0) : 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        return (hour, minute, second)
    }

    private static func parseDateList(
        value: String,
        parameters: [String: String],
        fallbackTimeZone: TimeZone,
        warnings: inout [String]
    ) -> [ICSDateTimeValue] {
        var result: [ICSDateTimeValue] = []
        for item in value.split(separator: ",") {
            let field = ICSProperty(name: "EXDATE", parameters: parameters, value: String(item))
            if let parsed = parseDateTime(field, fallbackTimeZone: fallbackTimeZone, warnings: &warnings) {
                result.append(parsed)
            } else {
                warnings.append("EXDATE 无法解析：\(item)，已忽略这一项。")
            }
        }
        return result
    }

    // MARK: - 重复规则

    private static func parseRecurrence(
        _ value: String,
        fallbackTimeZone: TimeZone,
        warnings: inout [String]
    ) -> ICSRecurrenceRule? {
        var rule = ICSRecurrenceRule(frequency: "")
        for pair in value.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).uppercased()
            let raw = String(parts[1])

            switch key {
            case "FREQ":
                rule.frequency = raw.uppercased()
            case "INTERVAL":
                if let number = Int(raw), number > 0 { rule.interval = number }
            case "COUNT":
                if let number = Int(raw), number > 0 { rule.count = number }
            case "BYDAY":
                var days: [Int] = []
                for token in raw.split(separator: ",") {
                    // "2MO" 这类带序号的写法第一阶段不支持序数，只取星期部分。
                    let cleaned = token.drop(while: { $0.isNumber || $0 == "+" || $0 == "-" })
                    if let day = weekdayNumber(String(cleaned).uppercased()) {
                        days.append(day)
                    } else {
                        warnings.append("BYDAY 无法识别：\(token)，已忽略。")
                    }
                }
                rule.byDay = Array(Set(days)).sorted()
            case "UNTIL":
                let field = ICSProperty(
                    name: "UNTIL",
                    parameters: ["TZID": fallbackTimeZone.identifier],
                    value: raw
                )
                if let parsed = parseDateTime(field, fallbackTimeZone: fallbackTimeZone, warnings: &warnings) {
                    rule.until = parsed
                } else {
                    warnings.append("RRULE 的 UNTIL 无法解析：\(raw)，已忽略该终止条件。")
                }
            default:
                // 其它规则（BYMONTHDAY / WKST 等）第一阶段不参与展开。
                break
            }
        }
        guard !rule.frequency.isEmpty else { return nil }
        return rule
    }

    private static func weekdayNumber(_ token: String) -> Int? {
        switch token {
        case "MO": return 1
        case "TU": return 2
        case "WE": return 3
        case "TH": return 4
        case "FR": return 5
        case "SA": return 6
        case "SU": return 7
        default: return nil
        }
    }

    // MARK: - 展开

    /// 把一条事件展开成区间内的若干次课。
    ///
    /// 每次都复现 DTSTART 的**墙上时间**：跨夏令时后仍然是同一个「几点上课」，
    /// 而不是把绝对时刻平移一小时。
    public static func occurrences(
        of event: ICSEvent,
        rangeStart: Date,
        rangeEnd: Date,
        fallbackTimeZone: TimeZone
    ) -> (dates: [ICSDateTimeValue], warnings: [String]) {
        var warnings: [String] = []
        let excluded = event.exDates

        func isExcluded(_ value: ICSDateTimeValue) -> Bool {
            // 用 1 秒容差比较：浮动时间与 UTC 表示可能差不到一秒。
            excluded.contains { abs($0.date.timeIntervalSince(value.date)) < 1 }
        }

        guard let rule = event.recurrence else {
            let single = event.dtStart
            guard single.date >= rangeStart, single.date <= rangeEnd else { return ([], []) }
            if isExcluded(single) { return ([], []) }
            return ([single], [])
        }

        guard rule.frequency == "WEEKLY" else {
            // 宁可只导入首次课并如实告知，也不要假装已经展开对了。
            warnings.append("暂不支持 FREQ=\(rule.frequency)，只导入了这次课的首次时间。")
            let single = event.dtStart
            guard single.date >= rangeStart, single.date <= rangeEnd, !isExcluded(single) else { return ([], warnings) }
            return ([single], warnings)
        }

        let eventZone = TimeZone(identifier: event.dtStart.timeZoneIdentifier) ?? fallbackTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eventZone

        let wall = calendar.dateComponents([.hour, .minute, .second], from: event.dtStart.date)
        let startWeekday = ((calendar.component(.weekday, from: event.dtStart.date) + 5) % 7) + 1
        guard let startOfDay = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: event.dtStart.date)) else {
            return ([], warnings)
        }
        guard let monday = calendar.date(byAdding: .day, value: -(startWeekday - 1), to: startOfDay) else {
            return ([], warnings)
        }

        let targetDays = rule.byDay.isEmpty ? [startWeekday] : rule.byDay.sorted()
        let interval = max(rule.interval, 1)
        // 520 周 ≈ 10 年，足够覆盖任何学期；同时兜住 UNTIL/COUNT 都缺失时的死循环。
        let maximumWeeks = 520
        var results: [ICSDateTimeValue] = []
        var emitted = 0

        outer: for step in 0..<maximumWeeks {
            guard let weekMonday = calendar.date(byAdding: .day, value: step * interval * 7, to: monday) else { break }
            for day in targetDays {
                guard let dayDate = calendar.date(byAdding: .day, value: day - 1, to: weekMonday) else { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: dayDate)
                components.hour = wall.hour
                components.minute = wall.minute
                components.second = wall.second
                guard let occurrence = calendar.date(from: components) else { continue }

                // DTSTART 之前的那几次「同周更早的星期」不属于本事件。
                guard occurrence >= event.dtStart.date else { continue }

                // 出现时刻递增，一旦越过区间终点就可以整体结束。
                if occurrence > rangeEnd { break outer }

                if let until = rule.until {
                    // UNTIL 是闭区间；只给日期时按当天结束算。
                    let limit = until.isDateOnly
                        ? until.date.addingTimeInterval(24 * 60 * 60 - 1)
                        : until.date
                    if occurrence > limit { break outer }
                }
                if let count = rule.count, emitted >= count { break outer }
                emitted += 1

                if occurrence < rangeStart { continue }

                let value = ICSDateTimeValue(
                    date: occurrence,
                    timeZoneIdentifier: eventZone.identifier,
                    kind: event.dtStart.kind,
                    isDateOnly: event.dtStart.isDateOnly
                )
                if isExcluded(value) { continue }
                results.append(value)
            }
        }

        return (results, warnings)
    }
}

// MARK: - 导入计划

public struct ICSCourseCandidate: Equatable, Sendable, Identifiable {

    /// 同时作为 CourseRecord.id：由课程名确定性推导，重复导入同一份文件会命中同一门课。
    public var id: String
    public var name: String
    public var location: String?
    public var eventCount: Int
    public var instanceCount: Int
    public var firstStartsAtUTC: String?
    /// 恒为 true。ICS 里的课程名只是文本，必须由用户确认后才允许写入课程表。
    public var requiresConfirmation: Bool

    public init(
        id: String,
        name: String,
        location: String? = nil,
        eventCount: Int,
        instanceCount: Int,
        firstStartsAtUTC: String? = nil,
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.eventCount = eventCount
        self.instanceCount = instanceCount
        self.firstStartsAtUTC = firstStartsAtUTC
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ICSImportPlan: Equatable, Sendable {

    public var courses: [ICSCourseCandidate]
    public var instances: [CourseInstanceRecord]
    public var warnings: [String]
    public var skippedLineCount: Int
    public var eventCount: Int
    public var expandedOccurrenceCount: Int

    public init(
        courses: [ICSCourseCandidate] = [],
        instances: [CourseInstanceRecord] = [],
        warnings: [String] = [],
        skippedLineCount: Int = 0,
        eventCount: Int = 0,
        expandedOccurrenceCount: Int = 0
    ) {
        self.courses = courses
        self.instances = instances
        self.warnings = warnings
        self.skippedLineCount = skippedLineCount
        self.eventCount = eventCount
        self.expandedOccurrenceCount = expandedOccurrenceCount
    }
}

public enum ICSImportPlanner {

    /// 课程名 -> 稳定课程 ID。归一化空白后再哈希，
    /// 这样「高等数学 」和「高等数学」不会变成两门课。
    public static func courseId(forSummary summary: String) -> String {
        "ics_" + String(SHA256Hex.digest("ics_course:" + Self.normalizedName(summary)).prefix(20))
    }

    public static func normalizedName(_ summary: String) -> String {
        summary
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func plan(
        parseResult: ICSParseResult,
        rangeStart: Date,
        rangeEnd: Date,
        fallbackTimeZone: TimeZone,
        now: Date
    ) -> ICSImportPlan {
        var warnings = parseResult.warnings
        var instances: [CourseInstanceRecord] = []
        var candidates: [ICSCourseCandidate] = []
        var occurrenceCount = 0
        var seenInstanceIds = Set<String>()
        let nowString = RFC3339.utcString(from: now)

        // 按 SUMMARY 分组：ICS 里没有「课程」这个概念，课程名是唯一能用的归属依据。
        var order: [String] = []
        var groups: [String: [ICSEvent]] = [:]
        for event in parseResult.events {
            let raw = Self.normalizedName(event.summary ?? "")
            let name = raw.isEmpty ? "未命名课程（ICS 导入）" : raw
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(event)
        }

        for name in order {
            let events = groups[name] ?? []
            let courseId = Self.courseId(forSummary: name)
            var location: String?
            var firstStartsAtUTC: String?
            var courseInstances: [CourseInstanceRecord] = []

            for event in events {
                if location == nil {
                    location = Self.normalizedName(event.location ?? "").isEmpty ? nil : Self.normalizedName(event.location ?? "")
                }

                let expanded = ICSParser.occurrences(
                    of: event,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd,
                    fallbackTimeZone: fallbackTimeZone
                )
                warnings.append(contentsOf: expanded.warnings)

                for occurrence in expanded.dates {
                    let startsAt = RFC3339.utcString(from: occurrence.date)
                    var endsAt = startsAt
                    var note = Self.normalizedName(event.eventDescription ?? "").isEmpty ? nil : event.eventDescription

                    if let dtEnd = event.dtEnd {
                        let duration = dtEnd.date.timeIntervalSince(event.dtStart.date)
                        if duration > 0 {
                            endsAt = RFC3339.utcString(from: occurrence.date.addingTimeInterval(duration))
                        }
                    } else if event.dtStart.isDateOnly {
                        // RFC5545：全天事件的 DTEND 默认是次日。
                        endsAt = RFC3339.utcString(from: occurrence.date.addingTimeInterval(24 * 60 * 60))
                    } else {
                        // 没有 DTEND 时**不编造**时长：结束时间等于开始时间，
                        // 并在备注里说清「预计结束时间未知」，由用户自己补。
                        note = (note.map { $0 + "\n" } ?? "") + "ICS 未提供结束时间，预计结束时间未知。"
                    }

                    let identity = event.uid ?? name
                    let id = "icsi_" + String(SHA256Hex.digest("ics_instance:\(identity):\(startsAt)").prefix(24))
                    guard !seenInstanceIds.contains(id) else { continue }
                    seenInstanceIds.insert(id)

                    courseInstances.append(CourseInstanceRecord(
                        id: id,
                        courseId: courseId,
                        ruleId: nil,
                        startsAtUTC: startsAt,
                        endsAtUTC: endsAt,
                        timezone: occurrence.timeZoneIdentifier,
                        status: .scheduled,
                        location: event.location.flatMap { Self.normalizedName($0).isEmpty ? nil : $0 } ?? location,
                        note: note,
                        origin: .ics,
                        createdAt: nowString,
                        updatedAt: nowString
                    ))

                    if firstStartsAtUTC == nil || startsAt < (firstStartsAtUTC ?? startsAt) {
                        firstStartsAtUTC = startsAt
                    }
                }
            }

            courseInstances.sort { lhs, rhs in
                if lhs.startsAtUTC != rhs.startsAtUTC { return lhs.startsAtUTC < rhs.startsAtUTC }
                return lhs.id < rhs.id
            }
            occurrenceCount += courseInstances.count
            instances.append(contentsOf: courseInstances)

            candidates.append(ICSCourseCandidate(
                id: courseId,
                name: name,
                location: location,
                eventCount: events.count,
                instanceCount: courseInstances.count,
                firstStartsAtUTC: firstStartsAtUTC
            ))
        }

        // 课程按首次上课时间排序，预览列表的顺序才和用户的直觉一致。
        candidates.sort { lhs, rhs in
            let left = lhs.firstStartsAtUTC ?? ""
            let right = rhs.firstStartsAtUTC ?? ""
            if left != right { return left < right }
            return lhs.name < rhs.name
        }
        instances.sort { lhs, rhs in
            if lhs.startsAtUTC != rhs.startsAtUTC { return lhs.startsAtUTC < rhs.startsAtUTC }
            return lhs.id < rhs.id
        }

        if parseResult.events.isEmpty {
            warnings.append("文件里没有解析出任何课程事件。如果这不是空文件，请检查导出格式。")
        }
        if parseResult.skippedLineCount > 0 {
            warnings.append("有 \(parseResult.skippedLineCount) 行无法解析，已跳过；其余内容照常导入。")
        }

        return ICSImportPlan(
            courses: candidates,
            instances: instances,
            warnings: warnings,
            skippedLineCount: parseResult.skippedLineCount,
            eventCount: parseResult.events.count,
            expandedOccurrenceCount: occurrenceCount
        )
    }
}
