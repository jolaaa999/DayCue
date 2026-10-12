import Foundation

// 课表的写入通道。
//
// 为什么单独一个文件，而不是塞进 DayCueStore+Course.swift：
// 那个文件只做「单表 CRUD」，而这里要做的是「一批经用户确认的内容，在一次事务里落地」。
// 两者的失败语义完全不同——这里任何一步失败都必须整体回滚，
// 否则用户会看到「课程建了但规则没建」这种半截状态。
//
// 另一条硬约束：已有实例永远只读。展开器只负责补出缺的课，
// 用户标过的停课 / 调课 / 换教室不会被重新展开覆盖。

public enum ScheduleStoreError: Error, Equatable {
    case courseNotFound(String)
}

/// 一次课表写入的结果。数量分开报，界面才能如实显示「新增了什么、保留了什么」。
public struct ScheduleWriteOutcome: Equatable, Sendable {

    public var insertedCourses: Int
    public var insertedRules: Int
    public var deletedRuleIds: [String]
    public var createdInstances: [CourseInstanceRecord]
    public var preservedInstanceIds: [String]

    public init(
        insertedCourses: Int = 0,
        insertedRules: Int = 0,
        deletedRuleIds: [String] = [],
        createdInstances: [CourseInstanceRecord] = [],
        preservedInstanceIds: [String] = []
    ) {
        self.insertedCourses = insertedCourses
        self.insertedRules = insertedRules
        self.deletedRuleIds = deletedRuleIds
        self.createdInstances = createdInstances
        self.preservedInstanceIds = preservedInstanceIds
    }
}

/// 一次展开落库的结果。
public struct ScheduleExpansionOutcome: Equatable, Sendable {

    /// 区间内的全量实例（已存在的 + 本次新建的）。
    public var instances: [CourseInstanceRecord]
    public var created: [CourseInstanceRecord]
    /// 已存在、被原样保留的实例。
    public var preserved: [CourseInstanceRecord]
    /// 已存在但与当前规则对不上（停课 / 调课 / 改时间），且**没有被覆盖**的实例。
    public var conflicting: [CourseInstanceRecord]
    public var warnings: [String]

    public init(
        instances: [CourseInstanceRecord] = [],
        created: [CourseInstanceRecord] = [],
        preserved: [CourseInstanceRecord] = [],
        conflicting: [CourseInstanceRecord] = [],
        warnings: [String] = []
    ) {
        self.instances = instances
        self.created = created
        self.preserved = preserved
        self.conflicting = conflicting
        self.warnings = warnings
    }
}

/// 「确认导入」这一条完整链路的汇总：先写课程与规则，再按学期锚点展开实例。
public struct ScheduleImportOutcome: Equatable, Sendable {

    public var write: ScheduleWriteOutcome
    public var expansions: [ScheduleExpansionOutcome]
    public var warnings: [String]

    public init(
        write: ScheduleWriteOutcome = ScheduleWriteOutcome(),
        expansions: [ScheduleExpansionOutcome] = [],
        warnings: [String] = []
    ) {
        self.write = write
        self.expansions = expansions
        self.warnings = warnings
    }
}

public extension DayCueStore {

    // MARK: - 每周规则

    /// 单条规则查询。+Course.swift 里只有按课程查，这里补一条按 ID 查，
    /// upsert 需要靠它区分「新建」与「更新」。
    func rule(id: String) throws -> CourseScheduleRule? {
        let statement = try database.prepare(
            "SELECT \(scheduleRuleColumns) FROM course_schedule_rule WHERE id = ? LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeCourseRule(statement)
    }

    /// 规则的行级 upsert，返回 true 表示确实是新建。
    ///
    /// 为什么要 upsert 而不是先删后插：规则被删再重建会换 created_at，
    /// 而「这条规则是什么时候加的」对排查用户疑问有用。
    @discardableResult
    func upsertRule(_ rule: CourseScheduleRule) throws -> Bool {
        let existed = try self.rule(id: rule.id) != nil
        var record = rule
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = now }

        let statement = try database.prepare(
            """
            INSERT INTO course_schedule_rule
              (id, course_id, weekday, section_start, section_end, start_time_local, end_time_local,
               week_parity, week_start, week_end, effective_from, effective_to, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              course_id = excluded.course_id,
              weekday = excluded.weekday,
              section_start = excluded.section_start,
              section_end = excluded.section_end,
              start_time_local = excluded.start_time_local,
              end_time_local = excluded.end_time_local,
              week_parity = excluded.week_parity,
              week_start = excluded.week_start,
              week_end = excluded.week_end,
              effective_from = excluded.effective_from,
              effective_to = excluded.effective_to,
              updated_at = excluded.updated_at;
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
        return !existed
    }

    // MARK: - 课程 + 规则一起保存

    /// 保存课程与它这次的每周规则。规则以「本次提交的集合」为准，未出现的旧规则被删除。
    ///
    /// 注意：删除规则**不会**删除已经展开的课程实例。那些实例里可能有用户标的停课 / 调课，
    /// 它们是历史记录，不能因为改一次课表就消失。
    @discardableResult
    func saveCourseWithRules(_ course: CourseRecord, rules: [CourseScheduleRule]) throws -> ScheduleWriteOutcome {
        try database.transaction {
            var insertedCourses = 0

            if let existing = try self.course(id: course.id) {
                var merged = course
                merged.createdAt = existing.createdAt
                // 追问开关与延迟是用户在别处设的偏好，编辑课表时不能顺手覆盖掉。
                merged.followUpEnabled = existing.followUpEnabled
                merged.followUpDelayMinutes = existing.followUpDelayMinutes
                try self.updateCourse(merged)
            } else {
                _ = try self.insertCourse(course)
                insertedCourses = 1
            }

            let existingRules = try self.rules(courseId: course.id)
            let wantedIds = Set(rules.map { $0.id })
            var deletedRuleIds: [String] = []
            for old in existingRules where !wantedIds.contains(old.id) {
                try self.deleteRule(id: old.id)
                deletedRuleIds.append(old.id)
            }

            var insertedRules = 0
            for rule in rules {
                if try self.upsertRule(rule) { insertedRules += 1 }
            }

            return ScheduleWriteOutcome(
                insertedCourses: insertedCourses,
                insertedRules: insertedRules,
                deletedRuleIds: deletedRuleIds
            )
        }
    }

    // MARK: - 应用「已确认」的写入计划

    /// 应用一份「已确认」的课表写入计划。整个计划是一个事务。
    ///
    /// 计划里只会有用户勾选过的内容（见 ScheduleWritePlanner），
    /// 所以这个方法本身不需要再问「有没有确认」。
    @discardableResult
    func applyScheduleWritePlan(_ plan: ScheduleWritePlan) throws -> ScheduleWriteOutcome {
        try database.transaction {
            var insertedCourses = 0
            for course in plan.courses {
                if let existing = try self.course(id: course.id) {
                    var merged = course
                    merged.createdAt = existing.createdAt
                    merged.followUpEnabled = existing.followUpEnabled
                    merged.followUpDelayMinutes = existing.followUpDelayMinutes
                    try self.updateCourse(merged)
                } else {
                    _ = try self.insertCourse(course)
                    insertedCourses += 1
                }
            }

            var insertedRules = 0
            for rule in plan.rules {
                if try self.upsertRule(rule) { insertedRules += 1 }
            }

            var createdInstances: [CourseInstanceRecord] = []
            var preservedInstanceIds: [String] = []
            for instance in plan.instances {
                // 只插入缺失的实例：已存在的行一个字段都不动。
                if try self.insertInstanceIfAbsent(instance) {
                    createdInstances.append(instance)
                } else {
                    preservedInstanceIds.append(instance.id)
                }
            }

            return ScheduleWriteOutcome(
                insertedCourses: insertedCourses,
                insertedRules: insertedRules,
                deletedRuleIds: [],
                createdInstances: createdInstances,
                preservedInstanceIds: preservedInstanceIds
            )
        }
    }

    // MARK: - 展开课程实例

    /// 应用一次纯函数展开的结果：只插入缺失的实例。
    @discardableResult
    func applyInstanceExpansion(_ expansion: CourseInstanceExpansionResult) throws -> ScheduleExpansionOutcome {
        var created: [CourseInstanceRecord] = []
        try database.transaction {
            for instance in expansion.created {
                if try self.insertInstanceIfAbsent(instance) {
                    created.append(instance)
                }
            }
        }
        return ScheduleExpansionOutcome(
            instances: expansion.instances,
            created: created,
            preserved: expansion.preserved,
            conflicting: expansion.conflicting,
            warnings: expansion.warnings
        )
    }

    /// 按当前规则展开并落库。
    ///
    /// 已存在的实例只读不写：停课 / 调课因此不会被重新展开覆盖。
    /// 课程被软删除时展开器不会产出新实例，但历史实例仍然读得到。
    @discardableResult
    func expandAndPersistCourse(
        courseId: String,
        rules: [CourseScheduleRule],
        anchor: CourseTermAnchor,
        rangeStart: Date,
        rangeEnd: Date,
        timeZone: TimeZone,
        excludedLocalDates: Set<String> = [],
        now: Date
    ) throws -> ScheduleExpansionOutcome {
        guard let course = try course(id: courseId) else {
            throw ScheduleStoreError.courseNotFound(courseId)
        }
        let existing = try instances(courseId: courseId, limit: 2000)
        let request = CourseInstanceExpansionRequest(
            course: course,
            rules: rules,
            anchor: anchor,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            timeZone: timeZone,
            existingInstances: existing,
            excludedLocalDates: excludedLocalDates,
            now: now
        )
        return try applyInstanceExpansion(CourseInstanceExpander.expand(request))
    }

    /// 「确认导入」的完整落地：先写课程与规则，再按学期锚点展开实例。
    ///
    /// 三步各自一个事务而不是一个大事务：SQLite 不支持嵌套事务（BEGIN 里再 BEGIN 会直接报错），
    /// 而这里每一步都是**幂等**的（ID 确定性推导 + 只插缺失行），
    /// 所以中途失败后用户再点一次确认即可，不会产生重复数据。
    ///
    /// anchor 为 nil 时**不展开**：没有学期第 1 周周一就算单双周，会把整学期的课排错，
    /// 宁可不生成实例，只把规则存下来。
    @discardableResult
    func applyScheduleWritePlanAndExpand(
        _ plan: ScheduleWritePlan,
        anchor: CourseTermAnchor?,
        rangeStart: Date,
        rangeEnd: Date,
        timeZone: TimeZone,
        excludedLocalDates: Set<String> = [],
        now: Date
    ) throws -> ScheduleImportOutcome {
        let write = try applyScheduleWritePlan(plan)

        var expansions: [ScheduleExpansionOutcome] = []
        var warnings = plan.warnings

        if let anchor {
            for course in plan.courses {
                let courseRules = plan.rules.filter { $0.courseId == course.id }
                if courseRules.isEmpty { continue }
                do {
                    let expansion = try expandAndPersistCourse(
                        courseId: course.id,
                        rules: courseRules,
                        anchor: anchor,
                        rangeStart: rangeStart,
                        rangeEnd: rangeEnd,
                        timeZone: timeZone,
                        excludedLocalDates: excludedLocalDates,
                        now: now
                    )
                    expansions.append(expansion)
                    warnings.append(contentsOf: expansion.warnings)
                } catch {
                    warnings.append("课程「\(course.name)」的课程实例展开失败：\(error)")
                }
            }
        } else if !plan.rules.isEmpty {
            warnings.append("还没有设置学期第 1 周周一，规则已经保存，但暂时不会生成课程实例。设置后可以回来重新展开。")
        }

        return ScheduleImportOutcome(write: write, expansions: expansions, warnings: warnings)
    }
}

// 列顺序集中一处，取值下标才不会随查询改动而错位。
// 用 private 是为了避免与其它领域的同名常量在模块里冲突。
private let scheduleRuleColumns = "id, course_id, weekday, section_start, section_end, start_time_local, end_time_local, week_parity, week_start, week_end, effective_from, effective_to, created_at, updated_at"
