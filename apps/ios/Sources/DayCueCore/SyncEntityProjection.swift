import Foundation

// 本地实体与云同步载荷之间的投影。
//
// 只做两件事：把本地行读成规范化载荷（采集器用），把服务端载荷写回本地（拉取用）。
// 刻意直接写 SELECT/INSERT，而不是调用各仓储的公开方法：
//   - 采集需要「含软删除行」的批量读取，而多数仓储只有 includeDeleted = false 的变体；
//   - 服务端载荷包含的字段与界面写入路径不同，硬套仓储方法会带来无谓的字段丢失。
//
// 唯一的例外是删除：软删除一律走各仓储既有的 softDelete* 方法，
// 因为「重复删除不推迟删除时间」这类不变量已经写在那里了。

/// 采集器读到的一条本地实体。
public struct SyncLocalEntity: Equatable, Sendable {
    public let entityType: SyncEntityType
    public let entityId: String
    public let payload: SyncEntityPayload
    /// 本地已删除（软删除行，或 capture 这种靠行消失推断的删除）。
    public let isDeleted: Bool
    /// 最近修改时刻，UTC RFC3339。用于推送时的 updated_at。
    public let updatedAt: String

    public init(
        entityType: SyncEntityType,
        entityId: String,
        payload: SyncEntityPayload,
        isDeleted: Bool,
        updatedAt: String
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.payload = payload
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }
}

public extension DayCueStore {

    // MARK: - 读取

    /// 读出某类型下的全部实体（含软删除行），供采集器逐条与基线比较。
    func cloudLocalEntities(entityType: SyncEntityType, limit: Int = 1000) throws -> [SyncLocalEntity] {
        let statement = try database.prepare(entitySelectSQL(entityType, single: false))
        try statement.bind([.integer(Int64(limit))])
        var result: [SyncLocalEntity] = []
        while try statement.step() {
            result.append(Self.makeLocalEntity(entityType, statement))
        }
        return result
    }

    func cloudLocalEntity(entityType: SyncEntityType, entityId: String) throws -> SyncLocalEntity? {
        let statement = try database.prepare(entitySelectSQL(entityType, single: true))
        try statement.bind([.text(entityId)])
        guard try statement.step() else { return nil }
        return Self.makeLocalEntity(entityType, statement)
    }

    /// 本地是否「已经删除」。true 表示同步绝不能把它复活。
    ///
    /// nil 表示无法判断：软删除表里行不存在既可能是从未存在过（别的设备新建的，
    /// 应当拉下来），也可能是被硬删掉了。这里不猜，交给拉取逻辑按「行不存在 = 可新增」处理。
    func cloudLocalDeletionState(entityType: SyncEntityType, entityId: String) throws -> Bool? {
        if entityType.usesSoftDelete {
            guard let local = try cloudLocalEntity(entityType: entityType, entityId: entityId) else {
                return nil
            }
            return local.isDeleted
        }
        // capture 是硬删除：行不存在 + 队列里记着要删 = 本地确实删过。
        if try cloudLocalEntity(entityType: entityType, entityId: entityId) != nil { return false }
        if let change = try syncChange(entityType: entityType, entityId: entityId), change.operation == .delete {
            return true
        }
        return nil
    }

    // MARK: - 写入（应用服务端变更）

    /// 用服务端载荷覆盖（或新建）本地实体。
    ///
    /// 只写参与同步的字段：created_at、任务的 external_write_state / last_receipt_at
    /// 这类纯本地状态必须原样保留，否则一次拉取就会把「外部写入进行中」的证据抹掉。
    func applyCloudPayload(
        entityType: SyncEntityType,
        entityId: String,
        payload: SyncEntityPayload,
        updatedAt: String
    ) throws {
        switch entityType {
        case .task:
            try applyTaskPayload(entityId: entityId, payload: payload, updatedAt: updatedAt)
        case .note:
            try applyNotePayload(entityId: entityId, payload: payload, updatedAt: updatedAt)
        case .capture:
            try applyCapturePayload(entityId: entityId, payload: payload, updatedAt: updatedAt)
        case .course:
            try applyCoursePayload(entityId: entityId, payload: payload, updatedAt: updatedAt)
        case .memory:
            try applyMemoryPayload(entityId: entityId, payload: payload)
        }
    }

    /// 应用服务端删除。软删除表走既有 softDelete*，capture 直接删行。
    /// 行不存在时什么也不做：没有的东西不需要删。
    func applyCloudDeletion(entityType: SyncEntityType, entityId: String, at: Date) throws {
        switch entityType {
        case .task:
            try softDeleteTask(id: entityId)
        case .note:
            try softDeleteNote(id: entityId)
        case .course:
            try softDeleteCourse(id: entityId)
        case .memory:
            try softDeleteMemory(id: entityId, at: at)
        case .capture:
            if try capture(id: entityId) != nil {
                try deleteCapture(id: entityId)
            }
        }
    }

    // MARK: - 各类型的 SELECT / 应用

    private func entitySelectSQL(_ type: SyncEntityType, single: Bool) -> String {
        let filter = single ? " WHERE id = ? LIMIT 1" : " ORDER BY id ASC LIMIT ?"
        switch type {
        case .task:
            return """
            SELECT id, title, detail, status, due_kind, due_local, due_utc, timezone,
                   remind_local, remind_utc, course_hint, origin_capture_id, origin_item_id,
                   updated_at, deleted_at
            FROM task\(filter);
            """
        case .note:
            return """
            SELECT id, title, body, tags, course_hint, origin_capture_id, origin_item_id,
                   origin_kind, user_edited, occurred_at, updated_at, deleted_at
            FROM note\(filter);
            """
        case .capture:
            return """
            SELECT id, kind, raw_text, transcript, ocr_text, user_edited, media_path,
                   recorded_at, recorded_timezone, status, updated_at
            FROM capture_item\(filter);
            """
        case .course:
            return """
            SELECT id, name, teacher, location, term, color, follow_up_enabled,
                   follow_up_delay_minutes, updated_at, deleted_at
            FROM course\(filter);
            """
        case .memory:
            return """
            SELECT id, kind, statement, status, source_capture_id, review_at, created_at, deleted_at
            FROM memory_item\(filter);
            """
        }
    }

    static func makeLocalEntity(_ type: SyncEntityType, _ statement: SQLiteStatement) -> SyncLocalEntity {
        var payload = SyncEntityPayload()
        let entityId: String
        let isDeleted: Bool
        let updatedAt: String

        switch type {
        case .task:
            entityId = statement.string(0) ?? ""
            payload.title = statement.string(1)
            payload.detail = statement.string(2)
            payload.status = statement.string(3)
            payload.dueKind = statement.string(4)
            payload.dueLocal = statement.string(5)
            payload.dueUTC = statement.string(6)
            payload.timezone = statement.string(7)
            payload.remindLocal = statement.string(8)
            payload.remindUTC = statement.string(9)
            payload.courseHint = statement.string(10)
            payload.originCaptureId = statement.string(11)
            payload.originItemId = statement.string(12)
            updatedAt = statement.string(13) ?? ""
            isDeleted = statement.string(14) != nil

        case .note:
            entityId = statement.string(0) ?? ""
            payload.title = statement.string(1)
            payload.body = statement.string(2)
            payload.tags = NoteTagCodec.decode(statement.string(3))
            payload.courseHint = statement.string(4)
            payload.originCaptureId = statement.string(5)
            payload.originItemId = statement.string(6)
            payload.originKind = statement.string(7)
            payload.userEdited = statement.bool(8)
            payload.occurredAt = statement.string(9)
            updatedAt = statement.string(10) ?? ""
            isDeleted = statement.string(11) != nil

        case .capture:
            entityId = statement.string(0) ?? ""
            payload.kind = statement.string(1)
            payload.rawText = statement.string(2)
            payload.transcript = statement.string(3)
            payload.ocrText = statement.string(4)
            payload.userEdited = statement.bool(5)
            payload.mediaPath = statement.string(6)
            payload.recordedAt = statement.string(7)
            payload.recordedTimezone = statement.string(8)
            payload.status = statement.string(9)
            updatedAt = statement.string(10) ?? ""
            // capture 没有 deleted_at：行还在就是没删。
            isDeleted = false

        case .course:
            entityId = statement.string(0) ?? ""
            payload.name = statement.string(1)
            payload.teacher = statement.string(2)
            payload.location = statement.string(3)
            payload.term = statement.string(4)
            payload.color = statement.string(5)
            payload.followUpEnabled = statement.bool(6)
            payload.followUpDelayMinutes = statement.int(7)
            updatedAt = statement.string(8) ?? ""
            isDeleted = statement.string(9) != nil

        case .memory:
            entityId = statement.string(0) ?? ""
            payload.category = statement.string(1)
            payload.statement = statement.string(2)
            payload.status = statement.string(3)
            payload.sourceRef = statement.string(4)
            payload.occurredAt = statement.string(5)
            // memory_item 没有 updated_at 列，created_at 是唯一可用的时间基准。
            updatedAt = statement.string(6) ?? ""
            isDeleted = statement.string(7) != nil
        }

        return SyncLocalEntity(
            entityType: type,
            entityId: entityId,
            payload: payload,
            isDeleted: isDeleted,
            updatedAt: updatedAt
        )
    }

    private func applyTaskPayload(
        entityId: String,
        payload: SyncEntityPayload,
        updatedAt: String
    ) throws {
        if var existing = try task(id: entityId) {
            existing.title = payload.title ?? existing.title
            existing.detail = payload.detail
            existing.status = payload.status.flatMap(TaskStatus.init(rawValue:)) ?? existing.status
            existing.dueKind = payload.dueKind.flatMap(DueKind.init(rawValue:)) ?? existing.dueKind
            existing.dueLocal = payload.dueLocal
            existing.dueUTC = payload.dueUTC
            existing.timezone = payload.timezone ?? existing.timezone
            existing.remindLocal = payload.remindLocal
            existing.remindUTC = payload.remindUTC
            existing.courseHint = payload.courseHint
            existing.originCaptureId = payload.originCaptureId
            existing.originItemId = payload.originItemId
            existing.updatedAt = updatedAt.isEmpty ? existing.updatedAt : updatedAt
            try updateTask(existing)
        } else {
            var record = TaskRecord(
                id: entityId,
                title: payload.title ?? "",
                detail: payload.detail,
                status: payload.status.flatMap(TaskStatus.init(rawValue:)) ?? .open,
                dueKind: payload.dueKind.flatMap(DueKind.init(rawValue:)) ?? .none,
                dueLocal: payload.dueLocal,
                dueUTC: payload.dueUTC,
                timezone: payload.timezone ?? TimeZone.current.identifier,
                remindLocal: payload.remindLocal,
                remindUTC: payload.remindUTC,
                courseHint: payload.courseHint,
                originCaptureId: payload.originCaptureId,
                originItemId: payload.originItemId
            )
            record.createdAt = updatedAt
            record.updatedAt = updatedAt
            try insertTask(record)
        }
    }

    private func applyNotePayload(
        entityId: String,
        payload: SyncEntityPayload,
        updatedAt: String
    ) throws {
        let existing = try note(id: entityId)
        let note = NoteRecord(
            id: entityId,
            title: payload.title ?? existing?.title ?? "",
            body: payload.body ?? existing?.body ?? "",
            tags: NoteTagCodec.normalize(payload.tags ?? existing?.tags ?? []),
            courseHint: payload.courseHint,
            originCaptureId: payload.originCaptureId,
            originItemId: payload.originItemId,
            originKind: payload.originKind.flatMap(NoteOriginKind.init(rawValue:)) ?? existing?.originKind ?? .manual,
            userEdited: payload.userEdited ?? existing?.userEdited ?? false,
            occurredAt: payload.occurredAt,
            createdAt: existing?.createdAt ?? updatedAt,
            updatedAt: updatedAt.isEmpty ? (existing?.updatedAt ?? "") : updatedAt,
            deletedAt: existing?.deletedAt
        )
        _ = try upsertNote(note)
    }

    private func applyCapturePayload(
        entityId: String,
        payload: SyncEntityPayload,
        updatedAt: String
    ) throws {
        let existing = try capture(id: entityId)
        let capture = CaptureRecord(
            id: entityId,
            kind: payload.kind.flatMap(CaptureKind.init(rawValue:)) ?? existing?.kind ?? .text,
            rawText: payload.rawText,
            transcript: payload.transcript,
            ocrText: payload.ocrText,
            userEdited: payload.userEdited ?? existing?.userEdited ?? false,
            mediaPath: payload.mediaPath,
            recordedAt: payload.recordedAt ?? existing?.recordedAt ?? updatedAt,
            recordedTimezone: payload.recordedTimezone ?? existing?.recordedTimezone ?? TimeZone.current.identifier,
            status: payload.status.flatMap(CaptureStatus.init(rawValue:)) ?? existing?.status ?? .local,
            createdAt: existing?.createdAt ?? updatedAt,
            updatedAt: updatedAt
        )
        _ = try upsertCapture(capture)
    }

    private func applyCoursePayload(
        entityId: String,
        payload: SyncEntityPayload,
        updatedAt: String
    ) throws {
        if let existing = try course(id: entityId) {
            let course = CourseRecord(
                id: existing.id,
                name: payload.name ?? existing.name,
                teacher: payload.teacher,
                location: payload.location,
                term: payload.term,
                color: payload.color,
                followUpEnabled: payload.followUpEnabled ?? existing.followUpEnabled,
                followUpDelayMinutes: payload.followUpDelayMinutes ?? existing.followUpDelayMinutes,
                createdAt: existing.createdAt,
                updatedAt: updatedAt.isEmpty ? existing.updatedAt : updatedAt,
                deletedAt: existing.deletedAt
            )
            try updateCourse(course)
        } else {
            let course = CourseRecord(
                id: entityId,
                name: payload.name ?? "",
                teacher: payload.teacher,
                location: payload.location,
                term: payload.term,
                color: payload.color,
                followUpEnabled: payload.followUpEnabled ?? false,
                followUpDelayMinutes: payload.followUpDelayMinutes ?? 5,
                createdAt: updatedAt,
                updatedAt: updatedAt
            )
            try insertCourse(course)
        }
    }

    private func applyMemoryPayload(entityId: String, payload: SyncEntityPayload) throws {
        // memory_item 只有这些列；revision / source_kind 在 memory_revision 里，
        // 由本地记忆流程维护，云同步不去改它，避免拆散「主记录 + 修订」的一致性。
        let statement = try database.prepare(
            """
            INSERT INTO memory_item (id, kind, statement, status, source_capture_id, review_at, created_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
              kind = excluded.kind,
              statement = excluded.statement,
              status = excluded.status;
            """
        )
        let existing = try memoryItemRow(entityId: entityId)
        try statement.bind([
            .text(entityId),
            .text(payload.category ?? existing?.kind ?? "preference"),
            .text(payload.statement ?? existing?.statement ?? ""),
            .text(payload.status ?? existing?.status ?? "candidate"),
            .optionalText(existing?.sourceCaptureId ?? payload.sourceRef),
            .optionalText(existing?.reviewAt ?? payload.effectiveFrom),
            .text(existing?.createdAt ?? DayCueClock.nowUTCString())
        ])
        try statement.run()
        // 记忆检索索引必须跟着正文一起更新，否则搜到的是旧说法。
        try? reindexMemory(id: entityId)
    }

    /// 读 memory_item 的若干现有列，用于「更新时保留本地字段」。
    private func memoryItemRow(entityId: String) throws -> (kind: String, statement: String, status: String, sourceCaptureId: String?, reviewAt: String?, createdAt: String)? {
        let statement = try database.prepare(
            "SELECT kind, statement, status, source_capture_id, review_at, created_at FROM memory_item WHERE id = ? LIMIT 1;"
        )
        try statement.bind([.text(entityId)])
        guard try statement.step() else { return nil }
        return (
            kind: statement.string(0) ?? "preference",
            statement: statement.string(1) ?? "",
            status: statement.string(2) ?? "candidate",
            sourceCaptureId: statement.string(3),
            reviewAt: statement.string(4),
            createdAt: statement.string(5) ?? DayCueClock.nowUTCString()
        )
    }
}
