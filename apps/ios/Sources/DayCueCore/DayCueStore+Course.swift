import Foundation

// 课表三张表的仓储：course / course_schedule_rule / course_instance。
// 写入方法集中在显式事务里，行映射只写一次，列顺序改动时只改常量。

public extension DayCueStore {

    /// 课表相关的设置键。放在 extension 里而不是改动 DayCueStore.swift，
    /// 是为了让「课表领域」的键与设置页的键在代码里仍然分得清。
    enum CourseSettingKey {
        /// 当前学期标识，只用于归档分组，不参与时间计算。
        public static let term = "course.term"
        /// 学期第 1 周周一的本地日期（YYYY-MM-DD）。缺省时不得猜一个开学日期。
        public static let termFirstWeekMonday = "course.term_first_week_monday"
        /// 新建课程时预填的追问延迟（分钟）。
        public static let defaultFollowUpDelayMinutes = "course.follow_up_default_delay_minutes"
    }

    // MARK: - 课程

    @discardableResult
    func insertCourse(_ course: CourseRecord) throws -> CourseRecord {
        var record = course
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO course
              (id, name, teacher, location, term, color, follow_up_enabled, follow_up_delay_minutes,
               created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(courseValues(record))
        try statement.run()
        return record
    }

    func course(id: String) throws -> CourseRecord? {
        let statement = try database.prepare("SELECT \(courseColumns) FROM course WHERE id = ? LIMIT 1;")
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeCourse(statement)
    }

    /// 课程列表。term 为 nil 表示「全部学期」。
    ///
    /// 默认不返回软删除的课程：删除是用户的决定，界面不该再把它当成可选课程。
    func courses(term: String? = nil, includeDeleted: Bool = false, limit: Int = 200) throws -> [CourseRecord] {
        var sql = "SELECT \(courseColumns) FROM course WHERE 1 = 1"
        var values: [SQLiteValue] = []
        if let term {
            sql += " AND term = ?"
            values.append(.text(term))
        }
        if !includeDeleted {
            sql += " AND deleted_at IS NULL"
        }
        sql += " ORDER BY name COLLATE NOCASE ASC LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [CourseRecord] = []
        while try statement.step() {
            result.append(Self.makeCourse(statement))
        }
        return result
    }

    /// 整行更新。不做动态拼 SQL，让「哪些字段会被写」在调用点完全可见。
    func updateCourse(_ course: CourseRecord) throws {
        var record = course
        record.updatedAt = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            """
            UPDATE course SET
              name = ?, teacher = ?, location = ?, term = ?, color = ?,
              follow_up_enabled = ?, follow_up_delay_minutes = ?,
              created_at = ?, updated_at = ?, deleted_at = ?
            WHERE id = ?;
            """
        )
        try statement.bind([
            .text(record.name),
            .optionalText(record.teacher),
            .optionalText(record.location),
            .optionalText(record.term),
            .optionalText(record.color),
            .bool(record.followUpEnabled),
            .integer(Int64(record.followUpDelayMinutes)),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt),
            .text(record.id)
        ])
        try statement.run()
    }

    /// 软删除课程。历史实例与追问必须保留：它们是已经发生过的学习记录，
    /// 删除课程不应该连带抹掉用户当时的回复与笔记。
    func softDeleteCourse(id: String) throws {
        let now = DayCueClock.nowUTCString()
        let statement = try database.prepare("UPDATE course SET deleted_at = ?, updated_at = ? WHERE id = ?;")
        try statement.bind([.text(now), .text(now), .text(id)])
        try statement.run()
    }

    /// 追问开关。delayMinutes 传 nil 表示沿用原值，只改开关。
    ///
    /// 返回更新后的记录；课程不存在时返回 nil，调用方不得把 nil 当作成功。
    @discardableResult
    func setFollowUp(enabled: Bool, delayMinutes: Int? = nil, forCourseId courseId: String) throws -> CourseRecord? {
        guard let existing = try course(id: courseId) else { return nil }
        var record = existing
        record.followUpEnabled = enabled
        if let delayMinutes {
            record.followUpDelayMinutes = min(max(delayMinutes, 0), 240)
        }
        try updateCourse(record)
        return try course(id: courseId)
    }

    // MARK: - 每周重复规则

    @discardableResult
    func insertRule(_ rule: CourseScheduleRule) throws -> CourseScheduleRule {
        var record = rule
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO course_schedule_rule
              (id, course_id, weekday, section_start, section_end, start_time_local, end_time_local,
               week_parity, week_start, week_end, effective_from, effective_to, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.courseId),
            .integer(Int64(record.weekday)),
            .integer(Int64(record.sectionStart)),
            .integer(Int64(record.sectionEnd)),
            .text(record.startTimeLocal),
            .text(record.endTimeLocal),
            .text(record.weekParity.rawValue),
            .integer(Int64(record.weekStart)),
            .integer(Int64(record.weekEnd)),
            .optionalText(record.effectiveFrom),
            .optionalText(record.effectiveTo),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()
        return record
    }

    func rules(courseId: String) throws -> [CourseScheduleRule] {
        let statement = try database.prepare(
            """
            SELECT \(courseRuleColumns) FROM course_schedule_rule
            WHERE course_id = ?
            ORDER BY weekday ASC, section_start ASC, id ASC;
            """
        )
        try statement.bind([.text(courseId)])
        var result: [CourseScheduleRule] = []
        while try statement.step() {
            result.append(Self.makeCourseRule(statement))
        }
        return result
    }

    /// 全部规则，按课程分组使用。展开整周课表时需要一次性取出来，避免 N+1 查询。
    func allRules(limit: Int = 1000) throws -> [CourseScheduleRule] {
        let statement = try database.prepare(
            """
            SELECT \(courseRuleColumns) FROM course_schedule_rule
            ORDER BY course_id ASC, weekday ASC, section_start ASC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([.integer(Int64(limit))])
        var result: [CourseScheduleRule] = []
        while try statement.step() {
            result.append(Self.makeCourseRule(statement))
        }
        return result
    }

    func deleteRule(id: String) throws {
        let statement = try database.prepare("DELETE FROM course_schedule_rule WHERE id = ?;")
        try statement.bind([.text(id)])
        try statement.run()
    }

    // MARK: - 课程实例

    /// 整行覆盖写入。
    ///
    /// 注意：课表展开**不要**用这个方法写新实例，用 insertInstanceIfAbsent，
    /// 否则会把用户标成「停课 / 调课」的行覆盖回「正常」。
    @discardableResult
    func upsertInstance(_ instance: CourseInstanceRecord) throws -> CourseInstanceRecord {
        var record = instance
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        record.updatedAt = now

        let statement = try database.prepare(
            """
            INSERT INTO course_instance
              (id, course_id, rule_id, starts_at_utc, ends_at_utc, timezone, status,
               location, note, origin, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              course_id = excluded.course_id,
              rule_id = excluded.rule_id,
              starts_at_utc = excluded.starts_at_utc,
              ends_at_utc = excluded.ends_at_utc,
              timezone = excluded.timezone,
              status = excluded.status,
              location = excluded.location,
              note = excluded.note,
              origin = excluded.origin,
              updated_at = excluded.updated_at;
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.courseId),
            .optionalText(record.ruleId),
            .text(record.startsAtUTC),
            .text(record.endsAtUTC),
            .text(record.timezone),
            .text(record.status.rawValue),
            .optionalText(record.location),
            .optionalText(record.note),
            .text(record.origin.rawValue),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()
        return record
    }

    /// 只在实例不存在时写入，返回是否真的新建了。
    ///
    /// 课表展开的唯一安全写法：实例 ID 由「课程 + 规则 + 日期」确定性推导，
    /// 所以重新展开会命中同一行；已经存在的行**一个字段都不动**，
    /// 用户的停课、调课、换教室因此不会被覆盖。
    @discardableResult
    func insertInstanceIfAbsent(_ instance: CourseInstanceRecord) throws -> Bool {
        if try self.instance(id: instance.id) != nil { return false }
        _ = try upsertInstance(instance)
        return true
    }

    func instance(id: String) throws -> CourseInstanceRecord? {
        let statement = try database.prepare("SELECT \(courseInstanceColumns) FROM course_instance WHERE id = ? LIMIT 1;")
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeCourseInstance(statement)
    }

    /// 区间内的实例（两端都含，按开始时刻升序）。
    ///
    /// 依赖 starts_at_utc 的统一 RFC3339（秒精度、带 Z）格式：
    /// 同一格式下字符串比较等价于时刻比较，因此可以直接下推到 SQLite。
    func instances(from start: Date, to end: Date, limit: Int = 1000) throws -> [CourseInstanceRecord] {
        let statement = try database.prepare(
            """
            SELECT \(courseInstanceColumns) FROM course_instance
            WHERE starts_at_utc >= ? AND starts_at_utc <= ?
            ORDER BY starts_at_utc ASC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([
            .text(RFC3339.utcString(from: start)),
            .text(RFC3339.utcString(from: end)),
            .integer(Int64(limit))
        ])
        var result: [CourseInstanceRecord] = []
        while try statement.step() {
            result.append(Self.makeCourseInstance(statement))
        }
        return result
    }

    func instances(courseId: String, limit: Int = 500) throws -> [CourseInstanceRecord] {
        let statement = try database.prepare(
            """
            SELECT \(courseInstanceColumns) FROM course_instance
            WHERE course_id = ?
            ORDER BY starts_at_utc ASC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(courseId), .integer(Int64(limit))])
        var result: [CourseInstanceRecord] = []
        while try statement.step() {
            result.append(Self.makeCourseInstance(statement))
        }
        return result
    }

    /// 改实例状态（停课 / 调课 / 恢复正常）。note 传 nil 表示保留原有备注。
    func setInstanceStatus(id: String, status: CourseInstanceStatus, note: String? = nil) throws {
        let statement = try database.prepare(
            "UPDATE course_instance SET status = ?, note = COALESCE(?, note), updated_at = ? WHERE id = ?;"
        )
        try statement.bind([
            .text(status.rawValue),
            .optionalText(note),
            .text(DayCueClock.nowUTCString()),
            .text(id)
        ])
        try statement.run()
    }

    func instanceCount() throws -> Int {
        let statement = try database.prepare("SELECT COUNT(*) FROM course_instance;")
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    func instanceCount(courseId: String) throws -> Int {
        let statement = try database.prepare("SELECT COUNT(*) FROM course_instance WHERE course_id = ?;")
        try statement.bind([.text(courseId)])
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    // MARK: - 学期锚点

    /// 读取学期锚点。缺失时返回 nil —— 不替用户猜一个开学日期，
    /// 因为猜错的后果是整学期的单双周反转。
    func courseTermAnchor() -> CourseTermAnchor? {
        guard let monday = setting(CourseSettingKey.termFirstWeekMonday), !monday.isEmpty else { return nil }
        let identifier = setting(DayCueStore.SettingKey.preferredTimezone)
            ?? TimeZone.current.identifier
        return CourseTermAnchor(
            firstWeekMondayLocalDate: monday,
            timeZoneIdentifier: identifier,
            term: setting(CourseSettingKey.term)
        )
    }

    func setCourseTermAnchor(_ anchor: CourseTermAnchor) throws {
        try setSetting(CourseSettingKey.termFirstWeekMonday, value: anchor.firstWeekMondayLocalDate)
        try setSetting(DayCueStore.SettingKey.preferredTimezone, value: anchor.timeZoneIdentifier)
        try setSetting(CourseSettingKey.term, value: anchor.term)
    }

    // MARK: - 行映射

    static func makeCourse(_ statement: SQLiteStatement) -> CourseRecord {
        CourseRecord(
            id: statement.string(0) ?? "",
            name: statement.string(1) ?? "",
            teacher: statement.string(2),
            location: statement.string(3),
            term: statement.string(4),
            color: statement.string(5),
            followUpEnabled: statement.bool(6),
            followUpDelayMinutes: statement.int(7),
            createdAt: statement.string(8) ?? "",
            updatedAt: statement.string(9) ?? "",
            deletedAt: statement.string(10)
        )
    }

    static func makeCourseRule(_ statement: SQLiteStatement) -> CourseScheduleRule {
        CourseScheduleRule(
            id: statement.string(0) ?? "",
            courseId: statement.string(1) ?? "",
            weekday: statement.int(2),
            sectionStart: statement.int(3),
            sectionEnd: statement.int(4),
            startTimeLocal: statement.string(5) ?? "",
            endTimeLocal: statement.string(6) ?? "",
            weekParity: WeekParity(rawValue: statement.string(7) ?? "all") ?? .all,
            weekStart: statement.int(8),
            weekEnd: statement.int(9),
            effectiveFrom: statement.string(10),
            effectiveTo: statement.string(11),
            createdAt: statement.string(12) ?? "",
            updatedAt: statement.string(13) ?? ""
        )
    }

    static func makeCourseInstance(_ statement: SQLiteStatement) -> CourseInstanceRecord {
        CourseInstanceRecord(
            id: statement.string(0) ?? "",
            courseId: statement.string(1) ?? "",
            ruleId: statement.string(2),
            startsAtUTC: statement.string(3) ?? "",
            endsAtUTC: statement.string(4) ?? "",
            timezone: statement.string(5) ?? TimeZone.current.identifier,
            status: CourseInstanceStatus(rawValue: statement.string(6) ?? "scheduled") ?? .scheduled,
            location: statement.string(7),
            note: statement.string(8),
            origin: CourseInstanceOrigin(rawValue: statement.string(9) ?? "rule") ?? .rule,
            createdAt: statement.string(10) ?? "",
            updatedAt: statement.string(11) ?? ""
        )
    }

    // MARK: - 内部

    /// INSERT 与 UPDATE 的参数顺序不同，所以只给 INSERT 用。
    private func courseValues(_ record: CourseRecord) -> [SQLiteValue] {
        [
            .text(record.id),
            .text(record.name),
            .optionalText(record.teacher),
            .optionalText(record.location),
            .optionalText(record.term),
            .optionalText(record.color),
            .bool(record.followUpEnabled),
            .integer(Int64(record.followUpDelayMinutes)),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt)
        ]
    }
}

// 列顺序集中一处，取值下标才不会随查询改动而错位。
// 用 private 是为了避免与其它领域的同名常量在模块里冲突。
private let courseColumns = "id, name, teacher, location, term, color, follow_up_enabled, follow_up_delay_minutes, created_at, updated_at, deleted_at"

private let courseRuleColumns = "id, course_id, weekday, section_start, section_end, start_time_local, end_time_local, week_parity, week_start, week_end, effective_from, effective_to, created_at, updated_at"

private let courseInstanceColumns = "id, course_id, rule_id, starts_at_utc, ends_at_utc, timezone, status, location, note, origin, created_at, updated_at"
