import Foundation

// 课表领域的时间基准全部显式化：学期锚点、区间、时区都由调用方传入。
// 展开算法是纯函数——不读系统时钟、不访问数据库。这样测试能给出确定结果，
// 也让「重新展开不得覆盖用户改过的实例」这条约束可以被单测盯住。

/// 学期锚点：第 1 周的周一（本地日期）。
///
/// 锚在「第 1 周的周一」而不是「开学第一天」：单双周依赖完整自然周，
/// 锚点错一天，整学期的单双周判断会整体反转。
public struct CourseTermAnchor: Codable, Equatable, Sendable {

    /// 第 1 周周一的本地日期，格式 YYYY-MM-DD。
    public var firstWeekMondayLocalDate: String
    /// IANA 时区名，例如 Asia/Shanghai。
    public var timeZoneIdentifier: String
    public var term: String?

    public init(firstWeekMondayLocalDate: String, timeZoneIdentifier: String, term: String? = nil) {
        self.firstWeekMondayLocalDate = firstWeekMondayLocalDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.term = term
    }

    /// 时区名可能是用户手填的脏数据；解析失败退回 GMT 而不是让展开抛错，
    /// 同时由 expand 产出一条 warning 让界面如实显示。
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "GMT") ?? .current
    }
}

/// 节次对应的默认起止时间。
///
/// 这是**纸面上的**作息表，只用来给课表排版和给用户预填时间；
/// 它与「这节课实际几点下课」没有任何关系。
public struct CourseSectionTime: Codable, Equatable, Sendable, Identifiable {

    public var section: Int
    /// "HH:mm"，必须零填充，字符串比较才等价于时间比较。
    public var startTime: String
    public var endTime: String

    public var id: Int { section }

    public init(section: Int, startTime: String, endTime: String) {
        self.section = section
        self.startTime = startTime
        self.endTime = endTime
    }
}

public enum CourseSectionTimetable {

    /// 常见的 12 节作息。学校之间差异很大，所以它只作为预填默认值，
    /// 用户可以在课程编辑器里逐条改成自己的时间。
    public static let standard: [CourseSectionTime] = [
        CourseSectionTime(section: 1, startTime: "08:00", endTime: "08:45"),
        CourseSectionTime(section: 2, startTime: "08:55", endTime: "09:40"),
        CourseSectionTime(section: 3, startTime: "10:00", endTime: "10:45"),
        CourseSectionTime(section: 4, startTime: "10:55", endTime: "11:40"),
        CourseSectionTime(section: 5, startTime: "14:00", endTime: "14:45"),
        CourseSectionTime(section: 6, startTime: "14:55", endTime: "15:40"),
        CourseSectionTime(section: 7, startTime: "16:00", endTime: "16:45"),
        CourseSectionTime(section: 8, startTime: "16:55", endTime: "17:40"),
        CourseSectionTime(section: 9, startTime: "19:00", endTime: "19:45"),
        CourseSectionTime(section: 10, startTime: "19:55", endTime: "20:40"),
        CourseSectionTime(section: 11, startTime: "20:50", endTime: "21:35"),
        CourseSectionTime(section: 12, startTime: "21:45", endTime: "22:30")
    ]

    public static func time(forSection section: Int) -> CourseSectionTime? {
        standard.first { $0.section == section }
    }
}

/// 一次展开的输入。所有时间相关字段都是显式参数，函数内部不取「现在」。
public struct CourseInstanceExpansionRequest: Equatable, Sendable {

    public var course: CourseRecord
    public var rules: [CourseScheduleRule]
    public var anchor: CourseTermAnchor
    /// 区间起点（含）。
    public var rangeStart: Date
    /// 区间终点（含）。
    public var rangeEnd: Date
    public var timeZone: TimeZone
    /// 已存在的实例。它们只参与「补缺」，永远不会被覆盖。
    public var existingInstances: [CourseInstanceRecord]
    /// 要跳过的本地日期（节假日、考试周）。第一阶段可以为空，
    /// 扩展点先放在这里，避免以后为了加它而改动函数签名。
    public var excludedLocalDates: Set<String>
    /// 生成 created_at / updated_at 的显式基准。
    public var now: Date

    public init(
        course: CourseRecord,
        rules: [CourseScheduleRule],
        anchor: CourseTermAnchor,
        rangeStart: Date,
        rangeEnd: Date,
        timeZone: TimeZone,
        existingInstances: [CourseInstanceRecord] = [],
        excludedLocalDates: Set<String> = [],
        now: Date
    ) {
        self.course = course
        self.rules = rules
        self.anchor = anchor
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.timeZone = timeZone
        self.existingInstances = existingInstances
        self.excludedLocalDates = excludedLocalDates
        self.now = now
    }
}

public struct CourseInstanceExpansionResult: Equatable, Sendable {

    /// 区间内的全量实例：已存在的一律原样保留 + 本次新生成的。
    public var instances: [CourseInstanceRecord]
    /// 本次需要写入的新实例。
    public var created: [CourseInstanceRecord]
    /// 已存在、被原样保留的实例。
    public var preserved: [CourseInstanceRecord]
    /// 已存在但与当前规则对不上的实例（停课、调课、改时间）。
    /// 它们**没有**被覆盖，列出来只是为了让界面能提示用户「规则改过了」。
    public var conflicting: [CourseInstanceRecord]
    public var excludedLocalDates: [String]
    public var warnings: [String]

    public init(
        instances: [CourseInstanceRecord] = [],
        created: [CourseInstanceRecord] = [],
        preserved: [CourseInstanceRecord] = [],
        conflicting: [CourseInstanceRecord] = [],
        excludedLocalDates: [String] = [],
        warnings: [String] = []
    ) {
        self.instances = instances
        self.created = created
        self.preserved = preserved
        self.conflicting = conflicting
        self.excludedLocalDates = excludedLocalDates
        self.warnings = warnings
    }
}

public enum CourseInstanceExpander {

    // MARK: - 实例 ID

    /// 由「课程 + 规则 + 本地日期」推导的确定性实例 ID。
    ///
    /// 必须是纯函数且跨次运行保持不变：重新展开命中同一行，
    /// 用户标过的「停课 / 调课」才不会被新 ID 顶掉、也就不会长出重复实例。
    public static func stableInstanceId(courseId: String, ruleId: String, localDate: String) -> String {
        "inst_" + String(SHA256Hex.digest("course_instance:\(courseId):\(ruleId):\(localDate)").prefix(24))
    }

    // MARK: - 周次与时间

    /// 学期第 1 周周一 -> 某本地日期属于第几周（从 1 起算）。
    public static func weekIndex(localDate: String, anchor: CourseTermAnchor, timeZone: TimeZone) -> Int? {
        guard let monday = startOfLocalDay(localDate: anchor.firstWeekMondayLocalDate, timeZone: timeZone),
              let day = startOfLocalDay(localDate: localDate, timeZone: timeZone) else { return nil }
        let days = makeCalendar(timeZone: timeZone).dateComponents([.day], from: monday, to: day).day ?? 0
        // 负数周次（锚点之前的日期）也要落在正确的周，所以用向下取整而不是整除截断。
        return Int(floor(Double(days) / 7.0)) + 1
    }

    /// 包含某个时刻的那一周：周一 00:00（含）到 下周一 00:00（不含）。
    public static func weekRange(containing date: Date, timeZone: TimeZone) -> (start: Date, end: Date)? {
        let calendar = makeCalendar(timeZone: timeZone)
        guard let monday = mondayStart(containing: date, calendar: calendar),
              let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday) else { return nil }
        return (monday, nextMonday)
    }

    public static func localDateString(_ date: Date, timeZone: TimeZone) -> String {
        RFC3339.localDateString(from: date, timeZone: timeZone)
    }

    public static func startOfLocalDay(localDate: String, timeZone: TimeZone) -> Date? {
        instant(localDate: localDate, clock: "00:00:00", timeZone: timeZone)
    }

    /// 把「本地日期 + 墙上时间」钉成绝对时刻。
    ///
    /// 走 Calendar + DateComponents，而不是「拼字符串再解析」：
    /// 前者在夏令时切换日会自动做正确的调整，后者会构造出一个当天不存在的时刻。
    public static func instant(localDate: String, clock: String, timeZone: TimeZone) -> Date? {
        guard let parts = parseClock(clock) else { return nil }
        let dateParts = localDate.split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = parts.hour
        components.minute = parts.minute
        components.second = parts.second
        return makeCalendar(timeZone: timeZone).date(from: components)
    }

    /// 只接受 "HH:mm" / "H:mm" / "HH:mm:ss"。解析不了就返回 nil，绝不猜一个时间。
    public static func parseClock(_ clock: String) -> (hour: Int, minute: Int, second: Int)? {
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        guard (0...59).contains(second) else { return nil }
        return (hour, minute, second)
    }

    // MARK: - 展开

    public static func expand(_ request: CourseInstanceExpansionRequest) -> CourseInstanceExpansionResult {
        var warnings: [String] = []
        let timeZone = request.timeZone

        // 已有实例先按区间筛出来，并建 ID 索引。它们全程只读，只作为「已存在」的依据。
        var existingById: [String: CourseInstanceRecord] = [:]
        var preserved: [CourseInstanceRecord] = []
        for instance in request.existingInstances {
            existingById[instance.id] = instance
            if isWithin(instance, from: request.rangeStart, to: request.rangeEnd) {
                preserved.append(instance)
            }
        }

        // 参数刻意不叫 created：外层稍后也会声明同名的 var created，
        // 嵌套函数参数与外层变量同名虽然能靠作用域解析，但读起来极易误判，直接换名。
        func result(newInstances: [CourseInstanceRecord], conflicting: [CourseInstanceRecord], excluded: [String]) -> CourseInstanceExpansionResult {
            var merged = preserved
            merged.append(contentsOf: newInstances)
            merged.sort { lhs, rhs in
                if lhs.startsAtUTC != rhs.startsAtUTC { return lhs.startsAtUTC < rhs.startsAtUTC }
                return lhs.id < rhs.id
            }
            var seen = Set<String>()
            let dedupedConflicts = conflicting.filter { seen.insert($0.id).inserted }
            if !dedupedConflicts.isEmpty {
                warnings.append("有 \(dedupedConflicts.count) 个已存在的课程实例与当前规则不一致（停课 / 调课 / 改时间），已保留原样，未被覆盖。")
            }
            return CourseInstanceExpansionResult(
                instances: merged,
                created: newInstances,
                preserved: preserved,
                conflicting: dedupedConflicts,
                excludedLocalDates: Array(Set(excluded)).sorted(),
                warnings: warnings
            )
        }

        // 课程被软删除后不再补新实例，但已经存在于库里的历史实例仍要能被读出来。
        if request.course.deletedAt != nil {
            warnings.append("课程已删除，未展开新的课程实例。")
            return result(newInstances: [], conflicting: [], excluded: [])
        }

        if request.anchor.timeZoneIdentifier != timeZone.identifier {
            warnings.append("学期锚点时区（\(request.anchor.timeZoneIdentifier)）与课表时区（\(timeZone.identifier)）不一致，已按课表时区展开。")
        }

        guard let anchorMonday = startOfLocalDay(localDate: request.anchor.firstWeekMondayLocalDate, timeZone: timeZone) else {
            warnings.append("学期第 1 周周一无法解析：\(request.anchor.firstWeekMondayLocalDate)")
            return result(newInstances: [], conflicting: [], excluded: [])
        }

        let calendar = makeCalendar(timeZone: timeZone)
        let nowString = RFC3339.utcString(from: request.now)
        var created: [CourseInstanceRecord] = []
        var conflicting: [CourseInstanceRecord] = []
        var excluded: [String] = []

        for rule in request.rules where rule.courseId == request.course.id {
            guard (1...7).contains(rule.weekday) else {
                warnings.append("规则 \(rule.id) 的星期值（\(rule.weekday)）不在 1...7，已跳过。")
                continue
            }
            guard let startClock = parseClock(rule.startTimeLocal), let endClock = parseClock(rule.endTimeLocal) else {
                warnings.append("规则 \(rule.id) 的节次时间无法解析（\(rule.startTimeLocal) - \(rule.endTimeLocal)），已跳过。")
                continue
            }

            // 周次范围写反时按「小的在前」处理并如实告知，而不是静默什么都不出。
            let firstWeek = max(1, min(rule.weekStart, rule.weekEnd))
            let lastWeek = min(60, max(rule.weekStart, rule.weekEnd))
            if rule.weekStart > rule.weekEnd {
                warnings.append("规则 \(rule.id) 的周次范围是反的（\(rule.weekStart)-\(rule.weekEnd)），已按 \(firstWeek)-\(lastWeek) 处理。")
            }

            for week in firstWeek...lastWeek {
                switch rule.weekParity {
                case .odd where week % 2 == 0: continue
                case .even where week % 2 == 1: continue
                default: break
                }

                // 天数累加交给 Calendar：跨月、跨年、夏令时都由日历负责，手算天数一定会错。
                let offsetDays = (week - 1) * 7 + (rule.weekday - 1)
                guard let dayDate = calendar.date(byAdding: .day, value: offsetDays, to: anchorMonday) else { continue }
                let localDate = localDateString(dayDate, timeZone: timeZone)

                if let from = rule.effectiveFrom, !from.isEmpty, localDate < from { continue }
                if let to = rule.effectiveTo, !to.isEmpty, localDate > to { continue }

                if request.excludedLocalDates.contains(localDate) {
                    excluded.append(localDate)
                    continue
                }

                guard let startDate = instant(localDate: localDate, clock: rule.startTimeLocal, timeZone: timeZone) else { continue }

                // 结束时刻不晚于开始时刻，说明这门课跨了午夜（例如晚自习）；
                // 结束日顺延一天，否则会造出一个结束早于开始的实例。
                let endLocalDate: String
                if (endClock.hour, endClock.minute) <= (startClock.hour, startClock.minute) {
                    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayDate) else { continue }
                    endLocalDate = localDateString(nextDay, timeZone: timeZone)
                } else {
                    endLocalDate = localDate
                }
                guard let endDate = instant(localDate: endLocalDate, clock: rule.endTimeLocal, timeZone: timeZone) else { continue }

                // 区间判定用「开始时刻落在区间内」，两端都包含。
                // 按开始时刻归日，周视图里 23:00 开始的课才不会被算进前一周。
                guard startDate >= request.rangeStart, startDate <= request.rangeEnd else { continue }

                let id = stableInstanceId(courseId: rule.courseId, ruleId: rule.id, localDate: localDate)
                let candidate = CourseInstanceRecord(
                    id: id,
                    courseId: rule.courseId,
                    ruleId: rule.id,
                    startsAtUTC: RFC3339.utcString(from: startDate),
                    endsAtUTC: RFC3339.utcString(from: endDate),
                    timezone: timeZone.identifier,
                    status: .scheduled,
                    location: request.course.location,
                    note: nil,
                    origin: .rule,
                    createdAt: nowString,
                    updatedAt: nowString
                )

                if let existing = existingById[id] {
                    // 已存在的实例一律原样保留：停课、调课、换教室都是用户的决定，
                    // 重新展开只负责补出缺的课，无权把它们改回「正常」。
                    if existing.status != .scheduled
                        || existing.startsAtUTC != candidate.startsAtUTC
                        || existing.endsAtUTC != candidate.endsAtUTC {
                        conflicting.append(existing)
                    }
                    continue
                }
                created.append(candidate)
            }
        }

        return result(newInstances: created, conflicting: conflicting, excluded: excluded)
    }

    // MARK: - 内部

    /// 实例是否落在区间内。只看开始时刻，与 expand 的判断保持一致。
    private static func isWithin(_ instance: CourseInstanceRecord, from start: Date, to end: Date) -> Bool {
        guard let starts = RFC3339.date(fromUTC: instance.startsAtUTC) else {
            // 时间串坏掉的实例不丢弃：宁可多显示一条，也不能悄悄吃掉用户的数据。
            return true
        }
        return starts >= start && starts <= end
    }

    private static func makeCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Calendar 的 weekday 是 1=周日…7=周六；课表约定 1=周一…7=周日，这里做唯一换算。
    private static func mondayStart(containing date: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: date)
        let mondayBased = ((weekday + 5) % 7) + 1
        let dayStart = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -(mondayBased - 1), to: dayStart)
    }
}

/// 课表排版：把实例映射成「星期 x 节次」的格子。
///
/// 单独抽出来是为了让周视图不做任何时间计算——视图层算错时区是这类界面最常见的 bug。
public enum CourseGridPlacement {

    /// 课表约定的星期序号：1=周一 … 7=周日。
    public static func mondayBasedWeekday(of date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }

    public static func weekday(of instance: CourseInstanceRecord, timeZone: TimeZone) -> Int? {
        guard let start = RFC3339.date(fromUTC: instance.startsAtUTC) else { return nil }
        return mondayBasedWeekday(of: start, timeZone: timeZone)
    }

    /// 实例开始时刻的本地墙上时间 "HH:mm"。
    public static func startClock(of instance: CourseInstanceRecord, timeZone: TimeZone) -> String? {
        clock(ofUTC: instance.startsAtUTC, timeZone: timeZone)
    }

    public static func endClock(of instance: CourseInstanceRecord, timeZone: TimeZone) -> String? {
        clock(ofUTC: instance.endsAtUTC, timeZone: timeZone)
    }

    public static func clock(ofUTC utcString: String, timeZone: TimeZone) -> String? {
        guard let date = RFC3339.date(fromUTC: utcString) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// 起止墙上时间落到哪几节。落不进任何节次时返回 nil，由界面显示为「作息外」。
    public static func sectionRange(
        startClock: String,
        endClock: String,
        timetable: [CourseSectionTime] = CourseSectionTimetable.standard
    ) -> ClosedRange<Int>? {
        guard let startSection = section(containing: startClock, timetable: timetable, allowNearestBefore: true) else {
            return nil
        }
        let endSection = section(containing: endClock, timetable: timetable, allowNearestBefore: false) ?? startSection
        return startSection...max(startSection, endSection)
    }

    private static func section(
        containing clock: String,
        timetable: [CourseSectionTime],
        allowNearestBefore: Bool
    ) -> Int? {
        if let inside = timetable
            .filter({ $0.startTime <= clock && clock < $0.endTime })
            .map(\.section)
            .max() {
            return inside
        }
        // 课间或作息表对不上时的兜底：取开始时间不晚于它的最后一节，避免整块课消失。
        guard allowNearestBefore else {
            return timetable.filter { $0.startTime < clock }.map(\.section).max()
        }
        return timetable.filter { $0.startTime <= clock }.map(\.section).max()
    }
}
