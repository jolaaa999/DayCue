import Foundation

// 课后追问的调度落库。
//
// 为什么单独一个文件：DayCueStore+FollowUp.swift 管的是「一张追问行的读写」，
// 而这里管的是「跑一次调度器，把它的纯计算结果落进库」。
// 调度判断全部在 FollowUpScheduler 里（纯函数），这里只做持久化，不再自己判一遍，
// 否则界面、通知与测试会各有一套口径。
//
// 产品限制：追问都是**提前排好的本地通知**，不存在「到点运行后台 AI」。
// 预计结束时间 + 延迟 只是通知时刻，不代表实际下课，也不代表出席。

public struct FollowUpScheduleApplyOutcome: Equatable, Sendable {

    public var createdCount: Int
    public var updatedCount: Int
    public var expiredCount: Int
    public var skipped: [FollowUpSchedulingSkip]
    public var warnings: [String]

    public init(
        createdCount: Int = 0,
        updatedCount: Int = 0,
        expiredCount: Int = 0,
        skipped: [FollowUpSchedulingSkip] = [],
        warnings: [String] = []
    ) {
        self.createdCount = createdCount
        self.updatedCount = updatedCount
        self.expiredCount = expiredCount
        self.skipped = skipped
        self.warnings = warnings
    }
}

public struct FollowUpSchedulingRunOutcome: Equatable, Sendable {

    public var applied: FollowUpScheduleApplyOutcome
    public var instancesConsidered: Int
    public var coursesConsidered: Int

    public init(
        applied: FollowUpScheduleApplyOutcome = FollowUpScheduleApplyOutcome(),
        instancesConsidered: Int = 0,
        coursesConsidered: Int = 0
    ) {
        self.applied = applied
        self.instancesConsidered = instancesConsidered
        self.coursesConsidered = coursesConsidered
    }
}

public extension DayCueStore {

    /// 把调度器的计算结果落库：新建 / 重排 / 过期，三件事一个事务。
    ///
    /// 终态（已回复 / 已跳过 / 已过期 / 已取消）不会被这里改回去：
    /// created 只处理没有追问行的实例，updated 只由调度器给出（且只含 scheduled），
    /// expired 也只对非终态的行生效。
    @discardableResult
    func applyFollowUpSchedulingResult(
        _ result: FollowUpSchedulingResult,
        at now: Date
    ) throws -> FollowUpScheduleApplyOutcome {
        try database.transaction {
            var createdCount = 0
            var updatedCount = 0
            var expiredCount = 0

            for record in result.created {
                // 表上有 UNIQUE(course_instance_id)：先查一次，重复调度不会撞唯一约束报错。
                if try self.followUp(courseInstanceId: record.courseInstanceId) == nil {
                    _ = try self.insertFollowUp(record)
                    createdCount += 1
                }
            }

            for record in result.updated {
                if try self.applyFollowUpState(record) != nil { updatedCount += 1 }
            }

            for id in result.expiredIds {
                guard let existing = try self.followUp(id: id) else { continue }
                guard !existing.state.isTerminal else { continue }
                guard let expired = FollowUpScheduler.applying(existing, state: .expired, at: now) else { continue }
                if try self.applyFollowUpState(expired) != nil { expiredCount += 1 }
            }

            return FollowUpScheduleApplyOutcome(
                createdCount: createdCount,
                updatedCount: updatedCount,
                expiredCount: expiredCount,
                skipped: result.skipped,
                warnings: result.warnings
            )
        }
    }

    /// 从库里取出课程与区间内的实例，跑一次调度并落库。
    ///
    /// 这是界面「重新安排课后追问」的唯一入口：它同时负责
    /// 「课程开关关闭不排」「停课实例不排」「终态不再拾取」「过期落成 expired」。
    @discardableResult
    func rescheduleFollowUps(
        from start: Date,
        to end: Date,
        at now: Date,
        graceMinutes: Int = FollowUpScheduler.defaultGraceMinutes
    ) throws -> FollowUpSchedulingRunOutcome {
        let instances = try self.instances(from: start, to: end, limit: 2000)
        // 课程要连软删除的一起取：已软删的课程视为关闭追问，调度器会据此跳过，
        // 但历史追问行仍然要能被读到，不能被当成「找不到课程」。
        let courses = try self.courses(includeDeleted: true, limit: 500)
        var coursesById: [String: CourseRecord] = [:]
        for course in courses {
            coursesById[course.id] = course
        }
        // 所有状态的追问都要传进去：终态在里面，调度器才不会再拾取。
        let followUps = try self.followUps(limit: 2000)

        let request = FollowUpSchedulingRequest(
            instances: instances,
            coursesById: coursesById,
            existingFollowUps: followUps,
            now: now,
            graceMinutes: graceMinutes
        )
        let result = FollowUpScheduler.schedule(request)
        let applied = try applyFollowUpSchedulingResult(result, at: now)

        return FollowUpSchedulingRunOutcome(
            applied: applied,
            instancesConsidered: instances.count,
            coursesConsidered: courses.count
        )
    }
}
