import Foundation

// 课后追问的持久化：follow_up / follow_up_reply 两张表，外加「回复归档成笔记」。
//
// 关于 note 表：本文件只写入**由追问归档产生**的笔记，方法名都带 FollowUpArchive 前缀，
// 避免与笔记领域自己的仓储方法重名。归档是追问流程闭环的最后一步，
// 所以它必须和追问状态写在同一个事务里——不能出现「笔记写了但追问还挂着」。

public enum FollowUpStoreError: Error, Equatable {
    case followUpNotFound(String)
    case illegalStateTransition(from: FollowUpState, to: FollowUpState)
}

/// 稍后操作的结果。三种情况必须分开，否则界面无法区分「找不到」和「已达上限」。
public enum FollowUpSnoozeOutcome: Equatable {
    case applied(FollowUpRecord)
    case limitReached
    case notFound
}

public struct FollowUpArchiveOutcome: Equatable, Sendable {
    public var followUp: FollowUpRecord
    public var reply: FollowUpReplyRecord
    public var note: NoteRecord
    public var task: TaskRecord?

    public init(followUp: FollowUpRecord, reply: FollowUpReplyRecord, note: NoteRecord, task: TaskRecord?) {
        self.followUp = followUp
        self.reply = reply
        self.note = note
        self.task = task
    }
}

public extension DayCueStore {

    // MARK: - 追问

    @discardableResult
    func insertFollowUp(_ followUp: FollowUpRecord) throws -> FollowUpRecord {
        var record = followUp
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO follow_up
              (id, course_instance_id, course_id, state, scheduled_at_utc, delivered_at_utc,
               snooze_until_utc, attempt, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(followUpValues(record))
        try statement.run()
        return record
    }

    func followUp(id: String) throws -> FollowUpRecord? {
        let statement = try database.prepare("SELECT \(followUpColumns) FROM follow_up WHERE id = ? LIMIT 1;")
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeFollowUp(statement)
    }

    /// 一条课程实例最多一条追问（表上有 UNIQUE(course_instance_id)）。
    func followUp(courseInstanceId: String) throws -> FollowUpRecord? {
        let statement = try database.prepare(
            "SELECT \(followUpColumns) FROM follow_up WHERE course_instance_id = ? LIMIT 1;"
        )
        try statement.bind([.text(courseInstanceId)])
        guard try statement.step() else { return nil }
        return Self.makeFollowUp(statement)
    }

    func followUps(state: FollowUpState? = nil, limit: Int = 200) throws -> [FollowUpRecord] {
        var sql = "SELECT \(followUpColumns) FROM follow_up WHERE 1 = 1"
        var values: [SQLiteValue] = []
        if let state {
            sql += " AND state = ?"
            values.append(.text(state.rawValue))
        }
        sql += " ORDER BY COALESCE(snooze_until_utc, scheduled_at_utc) ASC, id ASC LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [FollowUpRecord] = []
        while try statement.step() {
            result.append(Self.makeFollowUp(statement))
        }
        return result
    }

    func followUps(courseId: String, limit: Int = 200) throws -> [FollowUpRecord] {
        let statement = try database.prepare(
            """
            SELECT \(followUpColumns) FROM follow_up
            WHERE course_id = ?
            ORDER BY scheduled_at_utc DESC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(courseId), .integer(Int64(limit))])
        var result: [FollowUpRecord] = []
        while try statement.step() {
            result.append(Self.makeFollowUp(statement))
        }
        return result
    }

    /// 还没落终态的追问（已安排 / 已发出 / 已稍后），列表页的默认数据源。
    func activeFollowUps(limit: Int = 200) throws -> [FollowUpRecord] {
        let statement = try database.prepare(
            """
            SELECT \(followUpColumns) FROM follow_up
            WHERE state IN ('scheduled', 'delivered', 'snoozed')
            ORDER BY COALESCE(snooze_until_utc, scheduled_at_utc) ASC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([.integer(Int64(limit))])
        var result: [FollowUpRecord] = []
        while try statement.step() {
            result.append(Self.makeFollowUp(statement))
        }
        return result
    }

    /// 到点该被拾取的追问。
    ///
    /// 判定条件里含「稍后时间」与「宽限期过期」，SQL 很难表达清楚，
    /// 所以这里取回非终态的行再用 FollowUpScheduler 的纯逻辑过滤——
    /// 判定规则只有一份，界面、通知与测试看到的结论必然一致。
    func dueFollowUps(
        at now: Date,
        graceMinutes: Int = FollowUpScheduler.defaultGraceMinutes,
        limit: Int = 50
    ) throws -> [FollowUpRecord] {
        let candidates = try activeFollowUps(limit: 500)
        return Array(FollowUpScheduler.pickupable(candidates, at: now, graceMinutes: graceMinutes).prefix(limit))
    }

    /// 整行写回。状态迁移的合法性由 FollowUpStateMachine 判定，
    /// 这里再兜一道「终态不可被改回非终态」，防止绕过调度器直接调用。
    ///
    /// 返回 nil 表示目标行不存在；迁移非法则抛 FollowUpStoreError.illegalStateTransition。
    @discardableResult
    func applyFollowUpState(_ followUp: FollowUpRecord) throws -> FollowUpRecord? {
        guard let existing = try self.followUp(id: followUp.id) else { return nil }
        if existing.state.isTerminal, existing.state != followUp.state {
            throw FollowUpStoreError.illegalStateTransition(from: existing.state, to: followUp.state)
        }
        var record = followUp
        record.updatedAt = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            """
            UPDATE follow_up SET
              course_instance_id = ?, course_id = ?, state = ?, scheduled_at_utc = ?,
              delivered_at_utc = ?, snooze_until_utc = ?, attempt = ?, created_at = ?, updated_at = ?
            WHERE id = ?;
            """
        )
        try statement.bind([
            .text(record.courseInstanceId),
            .text(record.courseId),
            .text(record.state.rawValue),
            .text(record.scheduledAtUTC),
            .optionalText(record.deliveredAtUTC),
            .optionalText(record.snoozeUntilUTC),
            .integer(Int64(record.attempt)),
            .text(record.createdAt),
            .text(record.updatedAt),
            .text(record.id)
        ])
        try statement.run()
        return record
    }

    /// 稍后。次数上限与状态判定都在 FollowUpScheduler 里，这里只负责持久化。
    @discardableResult
    func snoozeFollowUp(id: String, until: Date, at now: Date) throws -> FollowUpSnoozeOutcome {
        guard let existing = try followUp(id: id) else { return .notFound }
        guard let updated = FollowUpScheduler.snoozed(existing, until: until, at: now) else {
            // 到上限说明用户一直在推迟：这时候应该引导「跳过」，而不是继续追问。
            return .limitReached
        }
        guard let applied = try applyFollowUpState(updated) else { return .notFound }
        return .applied(applied)
    }

    /// 停课之后取消这些实例名下未落终态的追问，返回实际取消的条数。
    @discardableResult
    func cancelFollowUps(courseInstanceIds: [String], at now: Date) throws -> Int {
        guard !courseInstanceIds.isEmpty else { return 0 }
        var cancelled = 0
        try database.transaction {
            for instanceId in courseInstanceIds {
                guard let existing = try followUp(courseInstanceId: instanceId) else { continue }
                let updates = FollowUpScheduler.cancelPending(
                    courseInstanceIds: [instanceId],
                    in: [existing],
                    at: now
                )
                for update in updates {
                    _ = try applyFollowUpState(update)
                    cancelled += 1
                }
            }
        }
        return cancelled
    }

    // MARK: - 追问回复

    @discardableResult
    func insertFollowUpReply(_ reply: FollowUpReplyRecord) throws -> FollowUpReplyRecord {
        var record = reply
        if record.createdAt.isEmpty { record.createdAt = DayCueClock.nowUTCString() }
        let statement = try database.prepare(
            """
            INSERT INTO follow_up_reply
              (id, follow_up_id, course_id, kind, text, transcript, media_path, note_id, task_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.followUpId),
            .text(record.courseId),
            .text(record.kind.rawValue),
            .optionalText(record.text),
            .optionalText(record.transcript),
            .optionalText(record.mediaPath),
            .optionalText(record.noteId),
            .optionalText(record.taskId),
            .text(record.createdAt)
        ])
        try statement.run()
        return record
    }

    func followUpReplies(followUpId: String) throws -> [FollowUpReplyRecord] {
        let statement = try database.prepare(
            """
            SELECT \(followUpReplyColumns) FROM follow_up_reply
            WHERE follow_up_id = ?
            ORDER BY created_at ASC, id ASC;
            """
        )
        try statement.bind([.text(followUpId)])
        var result: [FollowUpReplyRecord] = []
        while try statement.step() {
            result.append(Self.makeFollowUpReply(statement))
        }
        return result
    }

    /// 按课程回看历史回复（"这门课我上次说了什么"）。
    func followUpReplies(courseId: String, limit: Int = 200) throws -> [FollowUpReplyRecord] {
        let statement = try database.prepare(
            """
            SELECT \(followUpReplyColumns) FROM follow_up_reply
            WHERE course_id = ?
            ORDER BY created_at DESC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(courseId), .integer(Int64(limit))])
        var result: [FollowUpReplyRecord] = []
        while try statement.step() {
            result.append(Self.makeFollowUpReply(statement))
        }
        return result
    }

    // MARK: - 归档（笔记）

    /// 写入归档笔记。
    ///
    /// tags 按 JSON 数组存进 TEXT 列：Schema 只声明了 TEXT，没有独立标签表，
    /// 所以这里用 JSON 而不是自己发明分隔符。
    @discardableResult
    func insertFollowUpArchiveNote(_ note: NoteRecord) throws -> NoteRecord {
        var record = note
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }
        let statement = try database.prepare(
            """
            INSERT INTO note
              (id, title, body, tags, course_hint, origin_capture_id, origin_item_id, origin_kind,
               user_edited, occurred_at, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.title),
            .text(record.body),
            .optionalText(Self.encodeNoteTags(record.tags)),
            .optionalText(record.courseHint),
            .optionalText(record.originCaptureId),
            .optionalText(record.originItemId),
            .text(record.originKind.rawValue),
            .bool(record.userEdited),
            .optionalText(record.occurredAt),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt)
        ])
        try statement.run()
        return record
    }

    func followUpArchiveNote(id: String) throws -> NoteRecord? {
        let statement = try database.prepare(
            "SELECT \(followUpArchiveNoteColumns) FROM note WHERE id = ? LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeFollowUpArchiveNote(statement)
    }

    /// 追问回复的归档：笔记、可选任务、回复、追问状态，四件事一个事务。
    ///
    /// 只有用户接受的复习建议才带 task，未接受时 task 为 nil——
    /// 「不自动创建任务」这条规则因此落实在数据结构里，而不是靠界面自觉。
    @discardableResult
    func applyFollowUpArchive(_ plan: FollowUpArchivePlan) throws -> FollowUpArchiveOutcome {
        try database.transaction {
            let note = try insertFollowUpArchiveNote(plan.note)
            var task: TaskRecord?
            if let plannedTask = plan.task {
                task = try insertTask(plannedTask)
            }
            let reply = try insertFollowUpReply(plan.reply)
            guard let applied = try applyFollowUpState(plan.followUp) else {
                throw FollowUpStoreError.followUpNotFound(plan.followUp.id)
            }
            return FollowUpArchiveOutcome(followUp: applied, reply: reply, note: note, task: task)
        }
    }

    // MARK: - 行映射

    static func makeFollowUp(_ statement: SQLiteStatement) -> FollowUpRecord {
        FollowUpRecord(
            id: statement.string(0) ?? "",
            courseInstanceId: statement.string(1) ?? "",
            courseId: statement.string(2) ?? "",
            state: FollowUpState(rawValue: statement.string(3) ?? "scheduled") ?? .scheduled,
            scheduledAtUTC: statement.string(4) ?? "",
            deliveredAtUTC: statement.string(5),
            snoozeUntilUTC: statement.string(6),
            attempt: statement.int(7),
            createdAt: statement.string(8) ?? "",
            updatedAt: statement.string(9) ?? ""
        )
    }

    static func makeFollowUpReply(_ statement: SQLiteStatement) -> FollowUpReplyRecord {
        FollowUpReplyRecord(
            id: statement.string(0) ?? "",
            followUpId: statement.string(1) ?? "",
            courseId: statement.string(2) ?? "",
            kind: FollowUpReplyKind(rawValue: statement.string(3) ?? "text") ?? .text,
            text: statement.string(4),
            transcript: statement.string(5),
            mediaPath: statement.string(6),
            noteId: statement.string(7),
            taskId: statement.string(8),
            createdAt: statement.string(9) ?? ""
        )
    }

    static func makeFollowUpArchiveNote(_ statement: SQLiteStatement) -> NoteRecord {
        NoteRecord(
            id: statement.string(0) ?? "",
            title: statement.string(1) ?? "",
            body: statement.string(2) ?? "",
            tags: Self.decodeNoteTags(statement.string(3)),
            courseHint: statement.string(4),
            originCaptureId: statement.string(5),
            originItemId: statement.string(6),
            originKind: NoteOriginKind(rawValue: statement.string(7) ?? "manual") ?? .manual,
            userEdited: statement.bool(8),
            occurredAt: statement.string(9),
            createdAt: statement.string(10) ?? "",
            updatedAt: statement.string(11) ?? "",
            deletedAt: statement.string(12)
        )
    }

    // MARK: - 内部

    /// INSERT 用。UPDATE 的参数顺序与它不同，所以不复用。
    private func followUpValues(_ record: FollowUpRecord) -> [SQLiteValue] {
        [
            .text(record.id),
            .text(record.courseInstanceId),
            .text(record.courseId),
            .text(record.state.rawValue),
            .text(record.scheduledAtUTC),
            .optionalText(record.deliveredAtUTC),
            .optionalText(record.snoozeUntilUTC),
            .integer(Int64(record.attempt)),
            .text(record.createdAt),
            .text(record.updatedAt)
        ]
    }

    /// 必须是 static：行映射 makeFollowUpArchiveNote 是 static 方法，
    /// 实例方法在静态上下文里根本叫不到，会直接编译失败。
    private static func encodeNoteTags(_ tags: [String]) -> String? {
        guard !tags.isEmpty else { return nil }
        return try? DayCueJSON.encodeToString(tags)
    }

    /// 标签解析失败不抛错：一条标签坏掉不应该让整条笔记读不出来。
    private static func decodeNoteTags(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return (try? DayCueJSON.decode([String].self, from: raw)) ?? []
    }
}

private let followUpColumns = "id, course_instance_id, course_id, state, scheduled_at_utc, delivered_at_utc, snooze_until_utc, attempt, created_at, updated_at"

private let followUpReplyColumns = "id, follow_up_id, course_id, kind, text, transcript, media_path, note_id, task_id, created_at"

private let followUpArchiveNoteColumns = "id, title, body, tags, course_hint, origin_capture_id, origin_item_id, origin_kind, user_edited, occurred_at, created_at, updated_at, deleted_at"
