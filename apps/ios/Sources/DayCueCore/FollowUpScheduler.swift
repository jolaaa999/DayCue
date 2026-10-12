import Foundation

// 课后追问的全部判断都在这里，且全部是纯函数。
//
// 产品底线（写进代码而不是只写在文档里）：
// 1. 追问时间 = 实例的**预计**结束时间 + 课程的 delayMinutes；
//    预计结束不等于实际下课，更不代表出席。
// 2. 所有追问都是**提前排好的本地通知**，不存在「到点运行后台 AI」。
// 3. 停课实例不排追问；课程开关关闭不排；终态追问永不被再次拾取。

/// 追问状态迁移。终态（已回复 / 已跳过 / 已过期 / 已取消）一旦进入就不再改变，
/// 否则会出现「跳过之后又被追问」这种最招人烦的行为。
public enum FollowUpStateMachine {

    public static func canTransition(from: FollowUpState, to: FollowUpState) -> Bool {
        transition(from: from, to: to) != nil
    }

    /// 返回实际生效的目标状态；返回 nil 表示迁移非法，调用方必须显式处理 nil。
    public static func transition(from: FollowUpState, to: FollowUpState) -> FollowUpState? {
        if from == to { return from }
        if from.isTerminal { return nil }
        // 非终态之间允许任意迁移：用户可能先稍后、再跳过，也可能直接回复。
        return to
    }
}

public struct FollowUpSchedulingSkip: Equatable, Sendable {

    public var courseInstanceId: String
    /// 为什么不排。界面要能原样把这句展示给用户，而不是只说「未安排」。
    public var reason: String

    public init(courseInstanceId: String, reason: String) {
        self.courseInstanceId = courseInstanceId
        self.reason = reason
    }
}

public struct FollowUpSchedulingRequest: Equatable, Sendable {

    public var instances: [CourseInstanceRecord]
    public var coursesById: [String: CourseRecord]
    public var existingFollowUps: [FollowUpRecord]
    /// 显式的「现在」。调度器不读系统时钟，测试才能给出确定结果。
    public var now: Date
    /// 超过 scheduledAt + graceMinutes 仍未回复即视为过期。
    public var graceMinutes: Int

    public init(
        instances: [CourseInstanceRecord],
        coursesById: [String: CourseRecord],
        existingFollowUps: [FollowUpRecord],
        now: Date,
        graceMinutes: Int = FollowUpScheduler.defaultGraceMinutes
    ) {
        self.instances = instances
        self.coursesById = coursesById
        self.existingFollowUps = existingFollowUps
        self.now = now
        self.graceMinutes = graceMinutes
    }
}

public struct FollowUpSchedulingResult: Equatable, Sendable {

    /// 需要新建的追问（状态为 scheduled）。
    public var created: [FollowUpRecord]
    /// 已存在但时间需要跟着调课走的重排（只动尚未发出的 scheduled）。
    public var updated: [FollowUpRecord]
    /// 已超过宽限期、应当落成 expired 的追问 ID。
    public var expiredIds: [String]
    public var skipped: [FollowUpSchedulingSkip]
    public var warnings: [String]

    public init(
        created: [FollowUpRecord] = [],
        updated: [FollowUpRecord] = [],
        expiredIds: [String] = [],
        skipped: [FollowUpSchedulingSkip] = [],
        warnings: [String] = []
    ) {
        self.created = created
        self.updated = updated
        self.expiredIds = expiredIds
        self.skipped = skipped
        self.warnings = warnings
    }
}

public enum FollowUpScheduler {

    /// 默认宽限 12 小时：早上到校才看到昨晚的追问，仍然算有效；隔天就不再打扰。
    public static let defaultGraceMinutes = 12 * 60
    public static let minimumDelayMinutes = 0
    /// 上限 4 小时：追问的意义在于「刚下课还记得」，拖太久就没有价值。
    public static let maximumDelayMinutes = 240
    /// 连续稍后超过这个次数就应转为跳过，避免变成无限打扰。
    public static let defaultMaximumSnoozeCount = 5

    // MARK: - 基本判定

    public static func clampDelay(_ minutes: Int) -> Int {
        min(max(minutes, minimumDelayMinutes), maximumDelayMinutes)
    }

    /// 追问 ID 由实例 ID 确定性推导：一条实例最多一条追问（表上也有 UNIQUE），
    /// 重复调度不会产生第二行。
    public static func stableFollowUpId(courseInstanceId: String) -> String {
        "fu_" + String(SHA256Hex.digest("follow_up:\(courseInstanceId)").prefix(24))
    }

    /// 课程级开关：课程不存在或已删除一律视为关闭，不排追问。
    public static func isEnabled(_ course: CourseRecord?) -> Bool {
        guard let course else { return false }
        guard course.deletedAt == nil else { return false }
        return course.followUpEnabled
    }

    /// 追问时刻 = 预计结束时刻 + 延迟。
    ///
    /// 这里用的是 endsAtUTC（**预计**结束），它只用来排本地通知；
    /// 不表示实际下课，也不表示用户出席了这节课。
    public static func scheduledAt(for instance: CourseInstanceRecord, delayMinutes: Int) -> Date? {
        guard let endsAt = RFC3339.date(fromUTC: instance.endsAtUTC) else { return nil }
        return endsAt.addingTimeInterval(TimeInterval(clampDelay(delayMinutes)) * 60)
    }

    /// 追问的生效时刻：稍后过就用 snoozeUntil，否则用 scheduledAt。
    public static func effectiveDate(of followUp: FollowUpRecord) -> Date? {
        if followUp.state == .snoozed, let snoozeUntil = followUp.snoozeUntilUTC {
            return RFC3339.date(fromUTC: snoozeUntil)
        }
        if let snoozeUntil = followUp.snoozeUntilUTC, followUp.state == .scheduled || followUp.state == .delivered {
            // 稍后过又被重新拾取的中间态：以更晚的那个为准，不能让稍后失效。
            let scheduled = RFC3339.date(fromUTC: followUp.scheduledAtUTC)
            let snoozed = RFC3339.date(fromUTC: snoozeUntil)
            switch (scheduled, snoozed) {
            case let (s?, n?): return max(s, n)
            case let (s?, nil): return s
            case let (nil, n?): return n
            case (nil, nil): return nil
            }
        }
        return RFC3339.date(fromUTC: followUp.scheduledAtUTC)
    }

    public static func expiryDeadline(of followUp: FollowUpRecord, graceMinutes: Int) -> Date? {
        guard let effective = effectiveDate(of: followUp) else { return nil }
        return effective.addingTimeInterval(TimeInterval(max(graceMinutes, 0)) * 60)
    }

    public static func isExpired(_ followUp: FollowUpRecord, at now: Date, graceMinutes: Int = FollowUpScheduler.defaultGraceMinutes) -> Bool {
        guard !followUp.state.isTerminal else { return false }
        guard let deadline = expiryDeadline(of: followUp, graceMinutes: graceMinutes) else { return false }
        return now > deadline
    }

    /// 能不能被「拾取」（用于展示待回复列表，或转成 delivered）。
    public static func isPickupable(_ followUp: FollowUpRecord, at now: Date, graceMinutes: Int = FollowUpScheduler.defaultGraceMinutes) -> Bool {
        guard !followUp.state.isTerminal else { return false }
        guard let effective = effectiveDate(of: followUp) else { return false }
        guard effective <= now else { return false }
        return !isExpired(followUp, at: now, graceMinutes: graceMinutes)
    }

    public static func pickupable(
        _ followUps: [FollowUpRecord],
        at now: Date,
        graceMinutes: Int = defaultGraceMinutes
    ) -> [FollowUpRecord] {
        followUps
            // 闭包里显式写 Self.：静态方法的闭包内不加限定虽然多半能推导出来，
            // 但一旦编译器换了推导顺序就会报错，这里不做赌注。
            .filter { Self.isPickupable($0, at: now, graceMinutes: graceMinutes) }
            .sorted { lhs, rhs in
                let left = Self.effectiveDate(of: lhs) ?? .distantFuture
                let right = Self.effectiveDate(of: rhs) ?? .distantFuture
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
    }

    // MARK: - 调度

    public static func schedule(_ request: FollowUpSchedulingRequest) -> FollowUpSchedulingResult {
        var created: [FollowUpRecord] = []
        var updated: [FollowUpRecord] = []
        var expiredIds: [String] = []
        var skipped: [FollowUpSchedulingSkip] = []
        var warnings: [String] = []

        var existingByInstance: [String: FollowUpRecord] = [:]
        for followUp in request.existingFollowUps {
            existingByInstance[followUp.courseInstanceId] = followUp
        }

        // 先判过期：跨越宽限期的非终态追问要落成 expired，
        // 否则界面会一直挂着一周前的追问，用户只会把整个功能关掉。
        for followUp in request.existingFollowUps where !followUp.state.isTerminal {
            if isExpired(followUp, at: request.now, graceMinutes: request.graceMinutes) {
                expiredIds.append(followUp.id)
            }
        }

        let nowString = RFC3339.utcString(from: request.now)
        let instances = request.instances.sorted { lhs, rhs in
            if lhs.startsAtUTC != rhs.startsAtUTC { return lhs.startsAtUTC < rhs.startsAtUTC }
            return lhs.id < rhs.id
        }

        for instance in instances {
            // 停课的实例不排追问：那节课没有发生，问了只会让用户觉得 App 在乱猜。
            guard instance.status != .cancelled else {
                skipped.append(FollowUpSchedulingSkip(courseInstanceId: instance.id, reason: "这节课已标记为停课，不安排课后追问。"))
                continue
            }

            guard let course = request.coursesById[instance.courseId] else {
                warnings.append("实例 \(instance.id) 找不到对应课程，未安排课后追问。")
                continue
            }

            guard isEnabled(course) else {
                skipped.append(FollowUpSchedulingSkip(courseInstanceId: instance.id, reason: "这门课的课后追问开关是关闭的。"))
                continue
            }

            // 必须写 Self.：局部常量 scheduledAt 会遮蔽同名的静态方法，
            // 不加限定会变成「在自己的初始化式里引用自己」。
            guard let scheduledAt = Self.scheduledAt(for: instance, delayMinutes: course.followUpDelayMinutes) else {
                warnings.append("实例 \(instance.id) 的预计结束时间无法解析，未安排课后追问。")
                continue
            }
            let scheduledString = RFC3339.utcString(from: scheduledAt)

            if let existing = existingByInstance[instance.id] {
                // 终态永不重复拾取：用户跳过或回复过就不再打扰。
                if existing.state.isTerminal { continue }
                // 已发出、已稍后的都不重排时间：那是用户明确表达过的节奏。
                guard existing.state == .scheduled else { continue }
                if existing.scheduledAtUTC != scheduledString {
                    var record = existing
                    record.scheduledAtUTC = scheduledString
                    record.updatedAt = nowString
                    updated.append(record)
                }
                continue
            }

            created.append(FollowUpRecord(
                id: stableFollowUpId(courseInstanceId: instance.id),
                courseInstanceId: instance.id,
                courseId: instance.courseId,
                state: .scheduled,
                scheduledAtUTC: scheduledString,
                deliveredAtUTC: nil,
                snoozeUntilUTC: nil,
                attempt: 0,
                createdAt: nowString,
                updatedAt: nowString
            ))
        }

        return FollowUpSchedulingResult(
            created: created,
            updated: updated,
            expiredIds: expiredIds,
            skipped: skipped,
            warnings: warnings
        )
    }

    // MARK: - 状态变更

    /// 通用状态变更。返回 nil 表示迁移非法（例如想改一条已回复的追问）。
    public static func applying(
        _ followUp: FollowUpRecord,
        state: FollowUpState,
        at now: Date,
        snoozeUntil: Date? = nil,
        deliveredAt: Date? = nil
    ) -> FollowUpRecord? {
        guard FollowUpStateMachine.transition(from: followUp.state, to: state) != nil else { return nil }
        var record = followUp
        record.state = state
        record.updatedAt = RFC3339.utcString(from: now)
        if let snoozeUntil {
            record.snoozeUntilUTC = RFC3339.utcString(from: snoozeUntil)
        }
        if state == .delivered {
            record.deliveredAtUTC = RFC3339.utcString(from: deliveredAt ?? now)
        }
        if state == .answered {
            // 回复之后不该再保留稍后时间，否则列表会出现「已回复但还排着提醒」。
            record.snoozeUntilUTC = nil
        }
        return record
    }

    /// 稍后。超过最大次数的返回 nil，调用方应改为「跳过」，
    /// 避免用户一直点稍后、App 一直打扰。
    public static func snoozed(
        _ followUp: FollowUpRecord,
        until: Date,
        at now: Date,
        maximumSnoozeCount: Int = FollowUpScheduler.defaultMaximumSnoozeCount
    ) -> FollowUpRecord? {
        guard !followUp.state.isTerminal else { return nil }
        guard followUp.attempt < maximumSnoozeCount else { return nil }
        var record = followUp
        record.state = .snoozed
        record.snoozeUntilUTC = RFC3339.utcString(from: until)
        record.attempt = followUp.attempt + 1
        record.updatedAt = RFC3339.utcString(from: now)
        return record
    }

    /// 实例被改成停课时，把它名下还没终态的追问一并取消。
    /// 传 Set 是刻意的：调用方通常一次改一批实例。
    public static func cancelPending(
        courseInstanceIds: Set<String>,
        in followUps: [FollowUpRecord],
        at now: Date
    ) -> [FollowUpRecord] {
        followUps.compactMap { followUp in
            guard courseInstanceIds.contains(followUp.courseInstanceId) else { return nil }
            guard !followUp.state.isTerminal else { return nil }
            // 同上的闭包 Self. 规则。
            return Self.applying(followUp, state: .cancelled, at: now)
        }
    }
}

// MARK: - 回复归档

/// 复习建议。
///
/// 这里的建议**不是模型推断**，只是按关键词给出的可选项：
/// 用户不接受就绝不会创建任务，这是产品硬要求。
public struct FollowUpReviewSuggestion: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var title: String
    public var reason: String
    public var keyword: String

    public init(id: String, title: String, reason: String, keyword: String) {
        self.id = id
        self.title = title
        self.reason = reason
        self.keyword = keyword
    }
}

public struct FollowUpArchiveRequest: Equatable, Sendable {

    public var followUp: FollowUpRecord
    public var course: CourseRecord?
    public var replyKind: FollowUpReplyKind
    public var text: String?
    public var transcript: String?
    public var mediaPath: String?
    /// 实例开始时刻，仅用于让笔记记住「这是哪次课的回复」。
    public var instanceStartsAtUTC: String?
    /// 用户点了「接受」的复习建议。nil 表示没有接受任何建议，就不建任务。
    public var acceptedSuggestion: FollowUpReviewSuggestion?
    /// 用户选的复习日期（YYYY-MM-DD），只有接受了建议才用得上。
    public var taskDueLocalDate: String?
    public var timeZone: TimeZone
    public var now: Date

    public init(
        followUp: FollowUpRecord,
        course: CourseRecord? = nil,
        replyKind: FollowUpReplyKind,
        text: String? = nil,
        transcript: String? = nil,
        mediaPath: String? = nil,
        instanceStartsAtUTC: String? = nil,
        acceptedSuggestion: FollowUpReviewSuggestion? = nil,
        taskDueLocalDate: String? = nil,
        timeZone: TimeZone,
        now: Date
    ) {
        self.followUp = followUp
        self.course = course
        self.replyKind = replyKind
        self.text = text
        self.transcript = transcript
        self.mediaPath = mediaPath
        self.instanceStartsAtUTC = instanceStartsAtUTC
        self.acceptedSuggestion = acceptedSuggestion
        self.taskDueLocalDate = taskDueLocalDate
        self.timeZone = timeZone
        self.now = now
    }
}

public struct FollowUpArchivePlan: Equatable, Sendable {

    /// 归档后应写回的追问（状态 answered，并清掉稍后时间）。
    public var followUp: FollowUpRecord
    public var reply: FollowUpReplyRecord
    /// 回复一定归档成一条笔记，所以不是可选的。
    public var note: NoteRecord
    /// 只有用户接受了复习建议才有任务。
    public var task: TaskRecord?
    /// 本地关键词给出的候选建议，供界面展示给用户挑选。
    public var suggestions: [FollowUpReviewSuggestion]

    public init(
        followUp: FollowUpRecord,
        reply: FollowUpReplyRecord,
        note: NoteRecord,
        task: TaskRecord? = nil,
        suggestions: [FollowUpReviewSuggestion] = []
    ) {
        self.followUp = followUp
        self.reply = reply
        self.note = note
        self.task = task
        self.suggestions = suggestions
    }
}

public enum FollowUpArchivePlanner {

    /// 关键词只做「提示」，不做判断。刻意保持极短且可预测。
    public static let reviewKeywords = ["考试", "期中", "期末", "小测", "测验", "复习", "作业", "实验", "报告", "答辩", "预习"]

    public static func suggestions(for text: String?) -> [FollowUpReviewSuggestion] {
        guard let text, !text.isEmpty else { return [] }
        var result: [FollowUpReviewSuggestion] = []
        for keyword in reviewKeywords where text.contains(keyword) {
            result.append(FollowUpReviewSuggestion(
                id: "sugg_" + String(SHA256Hex.digest("suggestion:\(keyword)").prefix(16)),
                title: "复习：" + keyword,
                reason: "回复里提到了「\(keyword)」，可以顺手加一条复习任务。",
                keyword: keyword
            ))
        }
        return result
    }

    /// 生成归档计划。返回 nil 表示不能归档（追问已是终态，或回复内容为空）。
    ///
    /// ID 由回复内容确定性推导，所以重复归档会命中主键冲突而不是悄悄写两份。
    public static func plan(_ request: FollowUpArchiveRequest) -> FollowUpArchivePlan? {
        guard !request.followUp.state.isTerminal else { return nil }
        let body = (request.text ?? request.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAudio = !(request.mediaPath ?? "").isEmpty
        guard !body.isEmpty || hasAudio else { return nil }

        let nowString = RFC3339.utcString(from: request.now)
        let courseName = request.course?.name ?? "未命名课程"

        let replyId = "reply_" + String(SHA256Hex.digest("follow_up_reply:\(request.followUp.id)").prefix(24))
        let noteId = "note_" + String(SHA256Hex.digest("follow_up_note:\(request.followUp.id)").prefix(24))

        // 同样要加 Self.：名为 suggestions 的局部常量会遮蔽同名静态方法。
        let suggestions = Self.suggestions(for: body)
        let accepted = request.acceptedSuggestion

        var task: TaskRecord?
        if let accepted {
            task = TaskRecord(
                id: "task_" + String(SHA256Hex.digest("follow_up_task:\(request.followUp.id)").prefix(24)),
                title: accepted.title,
                detail: "来自「\(courseName)」的课后回复。回复原文已归档为笔记。",
                status: .open,
                dueKind: request.taskDueLocalDate == nil ? .none : .date,
                dueLocal: request.taskDueLocalDate,
                dueUTC: nil,
                timezone: request.timeZone.identifier,
                remindLocal: nil,
                remindUTC: nil,
                courseHint: request.course?.name,
                originCaptureId: nil,
                originItemId: request.followUp.id,
                externalWriteState: .notRequested,
                lastReceiptAt: nil,
                createdAt: nowString,
                updatedAt: nowString,
                deletedAt: nil
            )
        }

        let note = NoteRecord(
            id: noteId,
            title: courseName + " · 课后回复",
            body: body.isEmpty ? "（语音回复，转写未成功）" : body,
            tags: [],
            courseHint: request.course?.name,
            originCaptureId: nil,
            originItemId: request.followUp.id,
            originKind: .followUp,
            userEdited: false,
            occurredAt: request.instanceStartsAtUTC,
            createdAt: nowString,
            updatedAt: nowString,
            deletedAt: nil
        )

        let reply = FollowUpReplyRecord(
            id: replyId,
            followUpId: request.followUp.id,
            courseId: request.followUp.courseId,
            kind: request.replyKind,
            text: request.text,
            transcript: request.transcript,
            mediaPath: request.mediaPath,
            noteId: noteId,
            taskId: task?.id,
            createdAt: nowString
        )

        guard let archived = FollowUpScheduler.applying(request.followUp, state: .answered, at: request.now) else {
            return nil
        }

        return FollowUpArchivePlan(
            followUp: archived,
            reply: reply,
            note: note,
            task: task,
            suggestions: suggestions
        )
    }
}
