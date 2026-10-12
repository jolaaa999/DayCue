import Foundation

// OCR 文本行 -> 课表候选（ScheduleCandidate）。
//
// 为什么单独一个文件：OCR 出来的是噪声很大的**文本**，不是数据。
// 把「高等数学 周一 第1-2节」这种行直接变成 CourseRecord，是这类功能里最坑用户的错误：
// 识别错一次，整学期的课表就是错的。所以这里只做两件事：
//   1. 把行映射成**候选**，并如实标出「缺什么、置信度多少」；
//   2. 提供「只有已确认 ID 才进计划」的写入接口（ScheduleWritePlanner）。
// 任何候选都不会被自动写成课程。
//
// 产品限制（对整个课表领域都成立，写在这里避免被后面的人忘掉）：
// 课表的预计结束时间只用于课表排版和**提前排好的本地通知**，
// 它不等于实际下课，也不代表用户出席了这节课。

public enum ScheduleCandidateConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low

    public var displayName: String {
        switch self {
        case .high: return "识别完整"
        case .medium: return "部分识别"
        case .low: return "需手工补全"
        }
    }
}

public struct ScheduleCandidate: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var courseName: String
    public var teacher: String?
    public var location: String?
    /// 1 = 周一 … 7 = 周日。nil 表示没识别出来，必须由用户确认。
    public var weekday: Int?
    public var sectionStart: Int?
    public var sectionEnd: Int?
    public var weekParity: WeekParity
    public var weekStart: Int
    public var weekEnd: Int
    /// "HH:mm"。nil 表示由节次作息表推导。
    public var startTimeLocal: String?
    public var endTimeLocal: String?
    public var confidence: ScheduleCandidateConfidence
    /// **恒为 true**。即使 confidence == .high 也不允许自动写库：
    /// 写课表是用户确认过的动作，不是识别结果的下游。
    public var requiresConfirmation: Bool
    /// 缺哪些字段、哪里可疑。空数组表示识别完整。
    public var issues: [String]
    /// 原始 OCR 行，界面显示出来让用户能对照原文。
    public var sourceLine: String

    public init(
        id: String,
        courseName: String,
        teacher: String? = nil,
        location: String? = nil,
        weekday: Int? = nil,
        sectionStart: Int? = nil,
        sectionEnd: Int? = nil,
        weekParity: WeekParity = .all,
        weekStart: Int = 1,
        weekEnd: Int = 16,
        startTimeLocal: String? = nil,
        endTimeLocal: String? = nil,
        confidence: ScheduleCandidateConfidence = .low,
        issues: [String] = [],
        sourceLine: String
    ) {
        self.id = id
        self.courseName = courseName
        self.teacher = teacher
        self.location = location
        self.weekday = weekday
        self.sectionStart = sectionStart
        self.sectionEnd = sectionEnd
        self.weekParity = weekParity
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.startTimeLocal = startTimeLocal
        self.endTimeLocal = endTimeLocal
        self.confidence = confidence
        // 不提供参数：这条产品规则不允许被绕过。
        self.requiresConfirmation = true
        self.issues = issues
        self.sourceLine = sourceLine
    }

    /// 字段是否齐全到可以直接变成一条每周规则。
    public var isCompleteForRule: Bool {
        guard !courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return weekday != nil && sectionStart != nil
    }
}

public struct ScheduleOCRMappingResult: Equatable, Sendable {

    public var candidates: [ScheduleCandidate]
    /// 没能当成课表的行。要原样显示给用户，否则用户不知道哪些内容被忽略了。
    public var unmatchedLines: [String]
    public var warnings: [String]

    public init(
        candidates: [ScheduleCandidate] = [],
        unmatchedLines: [String] = [],
        warnings: [String] = []
    ) {
        self.candidates = candidates
        self.unmatchedLines = unmatchedLines
        self.warnings = warnings
    }
}

public enum ScheduleOCRMapping {

    /// 默认周次。教务课表绝大多数是 1-16 周，但它只是预填值，必须由用户确认。
    public static let defaultWeekEnd = 16

    public static func map(text: String, defaultWeekday: Int? = nil) -> ScheduleOCRMappingResult {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        return map(lines: lines, defaultWeekday: defaultWeekday)
    }

    /// 逐行映射。竖向排版的课表（课程名一行、星期节次一行）靠 pendingName 合并。
    public static func map(lines: [String], defaultWeekday: Int? = nil) -> ScheduleOCRMappingResult {
        var candidates: [ScheduleCandidate] = []
        var unmatched: [String] = []
        var warnings: [String] = []
        var pendingName: String?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let scan = scanStructure(line)
            if scan.hasScheduleToken {
                let name = scan.remainingName.isEmpty ? (pendingName ?? "") : scan.remainingName
                candidates.append(makeCandidate(name: name, scan: scan, sourceLine: line, defaultWeekday: defaultWeekday))
                pendingName = nil
                continue
            }

            // 没有星期/节次/周次的一行：只可能是课程名，先记下来等下一行合并。
            if looksLikeCourseName(line) {
                pendingName = line
            } else {
                unmatched.append(line)
            }
        }

        if let leftover = pendingName {
            warnings.append("最后一行「\(leftover)」只识别出课程名，没有星期与节次，已作为待补全的候选列出。")
            candidates.append(makeCandidate(
                name: leftover,
                scan: StructureScan(),
                sourceLine: leftover,
                defaultWeekday: defaultWeekday
            ))
        }

        // 完全相同的行合并成一条，避免预览里出现两行一模一样的内容。
        var seen = Set<String>()
        let deduped = candidates.filter { seen.insert($0.id).inserted }
        if deduped.count != candidates.count {
            warnings.append("有 \(candidates.count - deduped.count) 条候选内容重复，已合并。")
        }
        if deduped.isEmpty {
            warnings.append("没有从这些文字里识别出任何课程。可以手动添加，或换一张更清晰的图片再试。")
        }

        return ScheduleOCRMappingResult(candidates: deduped, unmatchedLines: unmatched, warnings: warnings)
    }

    /// 候选 ID：由整行文本确定性推导，同一行重复识别命中同一条。
    public static func candidateId(forLine line: String) -> String {
        "cand_" + String(SHA256Hex.digest("schedule_candidate:" + normalized(line)).prefix(16))
    }

    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        guard (1...7).contains(weekday) else { return "星期 \(weekday)" }
        return names[weekday - 1]
    }

    // MARK: - 结构扫描

    /// 从一行里扫出来的结构化字段。remainingName 是去掉所有已知 token 后剩下的文本，当作课程名。
    private struct StructureScan {
        var weekday: Int?
        var sectionStart: Int?
        var sectionEnd: Int?
        var weekParity: WeekParity = .all
        var weekStart: Int?
        var weekEnd: Int?
        var startTime: String?
        var endTime: String?
        var teacher: String?
        var location: String?
        var remainingName: String = ""

        /// 只有出现「星期 / 节次 / 周次 / 时间 / 单双周」才算课表信息。
        /// 只有老师名或地点名的行不算，否则会把无关文本也变成候选。
        var hasScheduleToken: Bool {
            weekday != nil || sectionStart != nil || weekStart != nil
                || startTime != nil || weekParity != .all
        }
    }

    private static func scanStructure(_ line: String) -> StructureScan {
        var scan = StructureScan()

        if let groups = firstMatch(weekdayChinesePattern, in: line), groups.count >= 2 {
            scan.weekday = weekdayValue(groups[1])
        }
        if scan.weekday == nil, let groups = firstMatch(weekdayEnglishPattern, in: line), groups.count >= 2 {
            scan.weekday = weekdayValue(groups[1])
        }

        if let groups = firstMatch(sectionRangePattern, in: line), groups.count >= 3 {
            scan.sectionStart = Int(groups[1])
            scan.sectionEnd = Int(groups[2])
        } else if let groups = firstMatch(sectionListPattern, in: line), groups.count >= 3 {
            scan.sectionStart = Int(groups[1])
            scan.sectionEnd = Int(groups[2])
        } else if let groups = firstMatch(sectionSinglePattern, in: line), groups.count >= 2 {
            scan.sectionStart = Int(groups[1])
            scan.sectionEnd = scan.sectionStart
        }

        if line.contains("单周") { scan.weekParity = .odd }
        if line.contains("双周") { scan.weekParity = .even }

        if let groups = firstMatch(weekRangePattern, in: line), groups.count >= 3 {
            scan.weekStart = Int(groups[1])
            scan.weekEnd = Int(groups[2])
        } else if let groups = firstMatch(weekSinglePattern, in: line), groups.count >= 2 {
            scan.weekStart = Int(groups[1])
            scan.weekEnd = scan.weekStart
        }

        let times = allMatches(timePattern, in: line)
        if times.count >= 1 { scan.startTime = times[0] }
        if times.count >= 2 { scan.endTime = times[1] }

        if let groups = firstMatch(teacherLabelPattern, in: line), groups.count >= 2, !groups[1].isEmpty {
            scan.teacher = groups[1]
        } else if let groups = firstMatch(teacherSuffixPattern, in: line), groups.count >= 2, !groups[1].isEmpty {
            scan.teacher = groups[1]
        }

        if let groups = firstMatch(locationLabelPattern, in: line), groups.count >= 2, !groups[1].isEmpty {
            scan.location = groups[1]
        } else if let groups = firstMatch(locationSuffixPattern, in: line), groups.count >= 2, !groups[1].isEmpty {
            scan.location = groups[1]
        }

        scan.remainingName = strippedName(line)
        return scan
    }

    private static func makeCandidate(
        name: String,
        scan: StructureScan,
        sourceLine: String,
        defaultWeekday: Int?
    ) -> ScheduleCandidate {
        var issues: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var weekday = scan.weekday
        if weekday == nil, let defaultWeekday, (1...7).contains(defaultWeekday) {
            weekday = defaultWeekday
            issues.append("这一行没有识别出星期，已按 \(weekdayName(defaultWeekday)) 预填，需要确认。")
        }

        let rawStart = scan.weekStart ?? 1
        let rawEnd = scan.weekEnd ?? defaultWeekEnd
        if scan.weekStart == nil || scan.weekEnd == nil {
            issues.append("没有识别出周次范围，已按 \(rawStart)-\(rawEnd) 周预填，需要确认。")
        }
        let lower = min(rawStart, rawEnd)
        let upper = max(rawStart, rawEnd)
        let weekStart = max(1, min(lower, 30))
        let weekEnd = max(weekStart, min(upper, 30))

        var sectionStart = scan.sectionStart
        var sectionEnd = scan.sectionEnd
        // 节次范围写反了就按小的在前处理，与课表展开器的口径保持一致。
        if let start = sectionStart, let end = sectionEnd, start > end {
            sectionStart = end
            sectionEnd = start
        }
        // 超出 1-20 的节次基本是 OCR 噪声，宁可当作没识别出来。
        if let start = sectionStart, !(1...20).contains(start) {
            sectionStart = nil
            sectionEnd = nil
        }
        if let end = sectionEnd, !(1...20).contains(end) {
            sectionStart = nil
            sectionEnd = nil
        }

        if trimmedName.isEmpty { issues.append("没有识别出课程名，需要手动填写。") }
        if weekday == nil { issues.append("没有识别出星期，需要确认是周几。") }
        if sectionStart == nil { issues.append("没有识别出节次，需要确认是第几节。") }

        let confidence: ScheduleCandidateConfidence
        if trimmedName.isEmpty || weekday == nil || sectionStart == nil {
            confidence = .low
        } else if issues.isEmpty {
            confidence = .high
        } else {
            confidence = .medium
        }

        return ScheduleCandidate(
            id: candidateId(forLine: sourceLine),
            courseName: trimmedName,
            teacher: scan.teacher,
            location: scan.location,
            weekday: weekday,
            sectionStart: sectionStart,
            sectionEnd: sectionEnd ?? sectionStart,
            weekParity: scan.weekParity,
            weekStart: weekStart,
            weekEnd: weekEnd,
            startTimeLocal: scan.startTime,
            endTimeLocal: scan.endTime,
            confidence: confidence,
            issues: issues,
            sourceLine: sourceLine
        )
    }

    // MARK: - 正则与文本

    private static let weekdayChinesePattern = "(?:周|星期|礼拜)\\s*([一二三四五六日天1-7])"
    private static let weekdayEnglishPattern = "\\b(MON|TUE|WED|THU|FRI|SAT|SUN)(?:DAY)?\\b"
    private static let sectionRangePattern = "第?\\s*(\\d{1,2})\\s*[-~－—至]\\s*(\\d{1,2})\\s*节"
    private static let sectionListPattern = "第?\\s*(\\d{1,2})\\s*[、,]\\s*(\\d{1,2})\\s*节"
    private static let sectionSinglePattern = "第?\\s*(\\d{1,2})\\s*节"
    private static let weekRangePattern = "第?\\s*(\\d{1,2})\\s*[-~－—至]\\s*(\\d{1,2})\\s*周"
    private static let weekSinglePattern = "第?\\s*(\\d{1,2})\\s*周"
    private static let parityPattern = "[单双]\\s*周"
    private static let timePattern = "(\\d{1,2}:\\d{2})"
    private static let teacherLabelPattern = "(?:老师|教师|讲师)\\s*[:：]\\s*([^\\s,，、;；:：]{1,10})"
    private static let teacherSuffixPattern = "([^\\s0-9,，、;；:：]{1,3})\\s*(?:老师|教师)"
    private static let locationLabelPattern = "(?:教室|地点|上课地点)\\s*[:：]?\\s*([^\\s,，、;；:：]{1,16})"
    private static let locationSuffixPattern = "([A-Za-z]?\\d{2,4})\\s*(?:教室|室)"

    /// 去掉所有结构 token 后剩下的文本就是课程名。分多次替换而不是写一个大正则，
    /// 是因为每个 token 的写法差异很大，分开更容易单独修。
    private static func strippedName(_ line: String) -> String {
        var result = line
        for pattern in [
            sectionRangePattern, sectionListPattern, sectionSinglePattern,
            weekRangePattern, weekSinglePattern, parityPattern,
            weekdayChinesePattern, weekdayEnglishPattern,
            teacherLabelPattern, teacherSuffixPattern,
            locationLabelPattern, locationSuffixPattern,
            timePattern
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(
            of: "[·•|/\\\\()（）\\[\\]【】,，、;；:：]+",
            with: " ",
            options: .regularExpression
        )
        let collapsed = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -_·•"))
    }

    private static func looksLikeCourseName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 24 else { return false }
        // 纯数字或纯符号的行不是课程名。
        return trimmed.contains(where: { $0.isLetter })
    }

    private static func weekdayValue(_ token: String) -> Int? {
        switch token.uppercased() {
        case "一", "1", "MON", "MONDAY": return 1
        case "二", "2", "TUE", "TUESDAY": return 2
        case "三", "3", "WED", "WEDNESDAY": return 3
        case "四", "4", "THU", "THURSDAY": return 4
        case "五", "5", "FRI", "FRIDAY": return 5
        case "六", "6", "SAT", "SATURDAY": return 6
        case "日", "天", "7", "SUN", "SUNDAY": return 7
        default: return nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return captureGroups(of: match, in: text)
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 2, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private static func captureGroups(of match: NSTextCheckingResult, in text: String) -> [String] {
        var result: [String] = []
        for index in 0..<match.numberOfRanges {
            let nsRange = match.range(at: index)
            if nsRange.location == NSNotFound {
                result.append("")
                continue
            }
            if let captured = Range(nsRange, in: text) {
                result.append(String(text[captured]))
            } else {
                result.append("")
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - 确认后才写入

/// 一次「用户确认后」要写入的全部内容。
///
/// 这个类型本身就是「未确认不写入」这条规则的落点：计划里只会出现用户勾选过的候选。
public struct ScheduleWritePlan: Equatable, Sendable {

    public var courses: [CourseRecord]
    public var rules: [CourseScheduleRule]
    public var instances: [CourseInstanceRecord]
    /// 被取消勾选、因此没有写进去的候选/课程 ID。界面要如实回显。
    public var skippedIds: [String]
    public var warnings: [String]

    public init(
        courses: [CourseRecord] = [],
        rules: [CourseScheduleRule] = [],
        instances: [CourseInstanceRecord] = [],
        skippedIds: [String] = [],
        warnings: [String] = []
    ) {
        self.courses = courses
        self.rules = rules
        self.instances = instances
        self.skippedIds = skippedIds
        self.warnings = warnings
    }

    public var isEmpty: Bool { courses.isEmpty && rules.isEmpty && instances.isEmpty }
}

public enum ScheduleWritePlanner {

    /// 课程色板。只用于区分课程块，不代表任何优先级。
    public static let colorPalette = [
        "#4C8DFF", "#FF8A3D", "#34C759", "#AF52DE",
        "#FF375F", "#5AC8FA", "#FFD60A", "#00C7BE"
    ]

    /// 课程 ID：由归一化课程名确定性推导，重复导入命中同一门课，不会长出重复课程。
    public static func courseId(forName name: String) -> String {
        "crs_" + String(SHA256Hex.digest("schedule_course:" + normalizedName(name)).prefix(20))
    }

    public static func normalizedName(_ name: String) -> String {
        name
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func color(forCourseId id: String) -> String {
        let prefix = String(SHA256Hex.digest(id).prefix(2))
        let value = Int(prefix, radix: 16) ?? 0
        return colorPalette[value % colorPalette.count]
    }

    /// 规则 ID：由「课程 + 星期 + 节次 + 单双周 + 周次」推导。
    /// 重新确认同一份识别结果会命中同一行规则，而不是每次新建一条。
    public static func ruleId(
        courseId: String,
        weekday: Int,
        sectionStart: Int,
        sectionEnd: Int,
        weekParity: WeekParity,
        weekStart: Int,
        weekEnd: Int
    ) -> String {
        let material = "schedule_rule:\(courseId):\(weekday):\(sectionStart)-\(sectionEnd):\(weekParity.rawValue):\(weekStart)-\(weekEnd)"
        return "rule_" + String(SHA256Hex.digest(material).prefix(24))
    }

    /// OCR 候选 -> 写入计划。
    ///
    /// **只有 confirmedIds 里的候选会进入计划**，这是「绝不自动建课程」的执行点。
    public static func plan(
        candidates: [ScheduleCandidate],
        confirmedIds: Set<String>,
        term: String?,
        followUpEnabled: Bool,
        followUpDelayMinutes: Int,
        now: Date
    ) -> ScheduleWritePlan {
        let nowString = RFC3339.utcString(from: now)
        let delay = FollowUpScheduler.clampDelay(followUpDelayMinutes)

        var courses: [CourseRecord] = []
        var courseIds = Set<String>()
        var rules: [CourseScheduleRule] = []
        var ruleIds = Set<String>()
        var skipped: [String] = []
        var warnings: [String] = []

        for candidate in candidates {
            guard confirmedIds.contains(candidate.id) else {
                skipped.append(candidate.id)
                continue
            }

            let name = normalizedName(candidate.courseName)
            guard !name.isEmpty else {
                warnings.append("有一条候选没有课程名，已跳过。请先补上名字再确认。")
                skipped.append(candidate.id)
                continue
            }
            guard let weekday = candidate.weekday, (1...7).contains(weekday) else {
                warnings.append("「\(name)」没有星期，已跳过。课表必须知道是周几。")
                skipped.append(candidate.id)
                continue
            }
            guard let startSection = candidate.sectionStart, (1...20).contains(startSection) else {
                warnings.append("「\(name)」没有可用的节次，已跳过。")
                skipped.append(candidate.id)
                continue
            }
            let endSection = max(startSection, min(candidate.sectionEnd ?? startSection, 20))
            guard let startTime = candidate.startTimeLocal
                    ?? CourseSectionTimetable.time(forSection: startSection)?.startTime,
                  let endTime = candidate.endTimeLocal
                    ?? CourseSectionTimetable.time(forSection: endSection)?.endTime else {
                warnings.append("「\(name)」第 \(startSection)-\(endSection) 节在默认作息表里没有对应时间，已跳过。请到课程编辑器里手动设置节次时间。")
                skipped.append(candidate.id)
                continue
            }

            let courseId = courseId(forName: name)
            if courseIds.insert(courseId).inserted {
                courses.append(CourseRecord(
                    id: courseId,
                    name: name,
                    teacher: candidate.teacher,
                    location: candidate.location,
                    term: term,
                    color: color(forCourseId: courseId),
                    followUpEnabled: followUpEnabled,
                    followUpDelayMinutes: delay,
                    createdAt: nowString,
                    updatedAt: nowString
                ))
            }

            let lower = min(candidate.weekStart, candidate.weekEnd)
            let upper = max(candidate.weekStart, candidate.weekEnd)
            let weekStart = max(1, min(lower, 30))
            let weekEnd = max(weekStart, min(upper, 30))

            let ruleId = ruleId(
                courseId: courseId,
                weekday: weekday,
                sectionStart: startSection,
                sectionEnd: endSection,
                weekParity: candidate.weekParity,
                weekStart: weekStart,
                weekEnd: weekEnd
            )
            if ruleIds.insert(ruleId).inserted {
                rules.append(CourseScheduleRule(
                    id: ruleId,
                    courseId: courseId,
                    weekday: weekday,
                    sectionStart: startSection,
                    sectionEnd: endSection,
                    startTimeLocal: startTime,
                    endTimeLocal: endTime,
                    weekParity: candidate.weekParity,
                    weekStart: weekStart,
                    weekEnd: weekEnd,
                    effectiveFrom: nil,
                    effectiveTo: nil,
                    createdAt: nowString,
                    updatedAt: nowString
                ))
            }
        }

        if courses.isEmpty {
            warnings.append("没有勾选任何可写入的候选，本次不会改动课程表。")
        }

        return ScheduleWritePlan(
            courses: courses,
            rules: rules,
            instances: [],
            skippedIds: skipped,
            warnings: warnings
        )
    }

    /// ICS 计划 -> 写入计划。**只有 confirmedCourseIds 里的课程及其实例会进入计划。**
    ///
    /// ICS 里的事件本身是具体的某几次课，不是每周规则，所以这里不生成 CourseScheduleRule。
    public static func plan(
        icsImportPlan: ICSImportPlan,
        confirmedCourseIds: Set<String>,
        term: String?,
        followUpEnabled: Bool,
        followUpDelayMinutes: Int,
        now: Date
    ) -> ScheduleWritePlan {
        let nowString = RFC3339.utcString(from: now)
        let delay = FollowUpScheduler.clampDelay(followUpDelayMinutes)

        var courses: [CourseRecord] = []
        for candidate in icsImportPlan.courses where confirmedCourseIds.contains(candidate.id) {
            courses.append(CourseRecord(
                id: candidate.id,
                name: candidate.name,
                location: candidate.location,
                term: term,
                color: color(forCourseId: candidate.id),
                followUpEnabled: followUpEnabled,
                followUpDelayMinutes: delay,
                createdAt: nowString,
                updatedAt: nowString
            ))
        }

        let confirmed = Set(courses.map { $0.id })
        let instances = icsImportPlan.instances.filter { confirmed.contains($0.courseId) }
        let skipped = icsImportPlan.courses
            .filter { !confirmedCourseIds.contains($0.id) }
            .map { $0.id }

        var warnings = icsImportPlan.warnings
        if courses.isEmpty {
            warnings.append("没有勾选任何课程，本次不会改动课程表。")
        }

        return ScheduleWritePlan(
            courses: courses,
            rules: [],
            instances: instances,
            skippedIds: skipped,
            warnings: warnings
        )
    }
}
