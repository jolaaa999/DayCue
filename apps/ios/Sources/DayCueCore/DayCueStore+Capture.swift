import Foundation

public extension DayCueStore {

    // MARK: - 捕获项

    @discardableResult
    func insertCapture(_ capture: CaptureRecord) throws -> CaptureRecord {
        var record = capture
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO capture_item
              (id, kind, raw_text, transcript, ocr_text, user_edited, media_path,
               recorded_at, recorded_timezone, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.kind.rawValue),
            .optionalText(record.rawText),
            .optionalText(record.transcript),
            .optionalText(record.ocrText),
            .bool(record.userEdited),
            .optionalText(record.mediaPath),
            .text(record.recordedAt),
            .text(record.recordedTimezone),
            .text(record.status.rawValue),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()
        return record
    }

    @discardableResult
    func upsertCapture(_ capture: CaptureRecord) throws -> CaptureRecord {
        let statement = try database.prepare(
            """
            INSERT INTO capture_item
              (id, kind, raw_text, transcript, ocr_text, user_edited, media_path,
               recorded_at, recorded_timezone, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              kind = excluded.kind,
              raw_text = excluded.raw_text,
              transcript = excluded.transcript,
              ocr_text = excluded.ocr_text,
              user_edited = excluded.user_edited,
              media_path = excluded.media_path,
              recorded_at = excluded.recorded_at,
              recorded_timezone = excluded.recorded_timezone,
              status = excluded.status,
              updated_at = excluded.updated_at;
            """
        )
        var record = capture
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        record.updatedAt = now
        try statement.bind([
            .text(record.id),
            .text(record.kind.rawValue),
            .optionalText(record.rawText),
            .optionalText(record.transcript),
            .optionalText(record.ocrText),
            .bool(record.userEdited),
            .optionalText(record.mediaPath),
            .text(record.recordedAt),
            .text(record.recordedTimezone),
            .text(record.status.rawValue),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()
        return record
    }

    func capture(id: String) throws -> CaptureRecord? {
        let statement = try database.prepare(
            "SELECT \(captureColumns) FROM capture_item WHERE id = ? LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeCapture(statement)
    }

    func captures(limit: Int = 100) throws -> [CaptureRecord] {
        let statement = try database.prepare(
            "SELECT \(captureColumns) FROM capture_item ORDER BY recorded_at DESC, id DESC LIMIT ?;"
        )
        try statement.bind([.integer(Int64(limit))])
        var result: [CaptureRecord] = []
        while try statement.step() {
            result.append(Self.makeCapture(statement))
        }
        return result
    }

    /// 待整理记录：还没进到「解析完成」的捕获，都会出现在今天页的待处理分区。
    func unfinishedCaptures(limit: Int = 50) throws -> [CaptureRecord] {
        let statement = try database.prepare(
            """
            SELECT \(captureColumns) FROM capture_item
            WHERE status IN ('local', 'extracting', 'failed', 'needs_clarification')
            ORDER BY recorded_at DESC, id DESC
            LIMIT ?;
            """
        )
        try statement.bind([.integer(Int64(limit))])
        var result: [CaptureRecord] = []
        while try statement.step() {
            result.append(Self.makeCapture(statement))
        }
        return result
    }

    func updateCaptureStatus(id: String, status: CaptureStatus) throws {
        let statement = try database.prepare(
            "UPDATE capture_item SET status = ?, updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(status.rawValue), .text(DayCueClock.nowUTCString()), .text(id)])
        try statement.run()
    }

    /// 用户手工修改正文。user_edited 一旦置 1 就不再回退，
    /// 这样「晚到的 AI 结果不能覆盖用户编辑」只需要看这一个标志位。
    func updateCaptureUserText(
        id: String,
        rawText: String?,
        transcript: String? = nil,
        ocrText: String? = nil
    ) throws {
        guard try capture(id: id) != nil else { throw DayCueStoreError.captureNotFound(id) }
        let statement = try database.prepare(
            """
            UPDATE capture_item
            SET raw_text = ?, transcript = COALESCE(?, transcript), ocr_text = COALESCE(?, ocr_text),
                user_edited = 1, updated_at = ?
            WHERE id = ?;
            """
        )
        try statement.bind([
            .optionalText(rawText),
            .optionalText(transcript),
            .optionalText(ocrText),
            .text(DayCueClock.nowUTCString()),
            .text(id)
        ])
        try statement.run()
    }

    /// 写入识别（转写 / OCR）得到的文本。
    ///
    /// 返回 false 表示用户已经改过文本，本次写入被拒绝。调用方必须把 false 当作正常结果处理，
    /// 不要重试、更不要直接把文本强行写回。
    @discardableResult
    func applyExtractedText(
        id: String,
        transcript: String? = nil,
        ocrText: String? = nil
    ) throws -> Bool {
        guard let existing = try capture(id: id) else {
            throw DayCueStoreError.captureNotFound(id)
        }
        guard !existing.userEdited else { return false }

        let statement = try database.prepare(
            """
            UPDATE capture_item
            SET transcript = COALESCE(?, transcript), ocr_text = COALESCE(?, ocr_text), updated_at = ?
            WHERE id = ? AND user_edited = 0;
            """
        )
        try statement.bind([
            .optionalText(transcript),
            .optionalText(ocrText),
            .text(DayCueClock.nowUTCString()),
            .text(id)
        ])
        try statement.run()
        // 用 WHERE user_edited = 0 兜住「查询与更新之间被用户编辑」的竞态。
        return try capture(id: id)?.userEdited == false
    }

    func deleteCapture(id: String) throws {
        try database.transaction {
            // 先清掉属于这条捕获的解析队列，否则外键级联后 outbox 会留下悬空的 entity_id。
            let outbox = try database.prepare(
                "DELETE FROM outbox_operation WHERE entity_type = 'capture' AND entity_id = ?;"
            )
            try outbox.bind([.text(id)])
            try outbox.run()

            let statement = try database.prepare("DELETE FROM capture_item WHERE id = ?;")
            try statement.bind([.text(id)])
            try statement.run()
        }
    }

    // MARK: - 附件

    @discardableResult
    func insertAttachment(_ attachment: AttachmentRecord) throws -> AttachmentRecord {
        let statement = try database.prepare(
            """
            INSERT INTO attachment (id, capture_id, media_type, local_path, byte_size, sha256, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(attachment.id),
            .text(attachment.captureId),
            .text(attachment.mediaType),
            .text(attachment.localPath),
            .integer(Int64(attachment.byteSize)),
            .text(attachment.sha256),
            .text(attachment.createdAt)
        ])
        try statement.run()
        return attachment
    }

    func attachments(captureId: String) throws -> [AttachmentRecord] {
        let statement = try database.prepare(
            """
            SELECT id, capture_id, media_type, local_path, byte_size, sha256, created_at
            FROM attachment WHERE capture_id = ? ORDER BY created_at ASC;
            """
        )
        try statement.bind([.text(captureId)])
        var result: [AttachmentRecord] = []
        while try statement.step() {
            result.append(AttachmentRecord(
                id: statement.string(0) ?? "",
                captureId: statement.string(1) ?? "",
                mediaType: statement.string(2) ?? "",
                localPath: statement.string(3) ?? "",
                byteSize: statement.int(4),
                sha256: statement.string(5) ?? "",
                createdAt: statement.string(6) ?? ""
            ))
        }
        return result
    }

    // MARK: - 解析候选

    @discardableResult
    func insertProposal(_ proposal: ProposalRecord) throws -> ProposalRecord {
        let statement = try database.prepare(
            """
            INSERT INTO extraction_proposal
              (id, capture_id, schema_version, payload_json, mode, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        )
        var record = proposal
        if record.createdAt.isEmpty { record.createdAt = DayCueClock.nowUTCString() }
        try statement.bind([
            .text(record.id),
            .text(record.captureId),
            .text(record.schemaVersion),
            .text(record.payloadJSON),
            .text(record.mode.rawValue),
            .text(record.status.rawValue),
            .text(record.createdAt)
        ])
        try statement.run()
        return record
    }

    func proposals(captureId: String) throws -> [ProposalRecord] {
        let statement = try database.prepare(
            """
            SELECT id, capture_id, schema_version, payload_json, mode, status, created_at
            FROM extraction_proposal WHERE capture_id = ? ORDER BY created_at DESC;
            """
        )
        try statement.bind([.text(captureId)])
        var result: [ProposalRecord] = []
        while try statement.step() {
            result.append(ProposalRecord(
                id: statement.string(0) ?? "",
                captureId: statement.string(1) ?? "",
                schemaVersion: statement.string(2) ?? "",
                payloadJSON: statement.string(3) ?? "",
                mode: ExtractionMode(rawValue: statement.string(4) ?? "live") ?? .live,
                status: ProposalStatus(rawValue: statement.string(5) ?? "pending") ?? .pending,
                createdAt: statement.string(6) ?? ""
            ))
        }
        return result
    }

    func latestProposal(captureId: String) throws -> ProposalRecord? {
        try proposals(captureId: captureId).first
    }

    func updateProposalStatus(id: String, status: ProposalStatus) throws {
        let statement = try database.prepare("UPDATE extraction_proposal SET status = ? WHERE id = ?;")
        try statement.bind([.text(status.rawValue), .text(id)])
        try statement.run()
    }

    func updateProposalStatus(captureId: String, status: ProposalStatus) throws {
        let statement = try database.prepare("UPDATE extraction_proposal SET status = ? WHERE capture_id = ?;")
        try statement.bind([.text(status.rawValue), .text(captureId)])
        try statement.run()
    }
}

public extension DayCueStore {
    /// 行映射只写一次。所有查询都从 captureColumns 取值，列顺序改动时只需要改这里。
    static func makeCapture(_ statement: SQLiteStatement) -> CaptureRecord {
        CaptureRecord(
            id: statement.string(0) ?? "",
            kind: CaptureKind(rawValue: statement.string(1) ?? "text") ?? .text,
            rawText: statement.string(2),
            transcript: statement.string(3),
            ocrText: statement.string(4),
            userEdited: statement.bool(5),
            mediaPath: statement.string(6),
            recordedAt: statement.string(7) ?? "",
            recordedTimezone: statement.string(8) ?? TimeZone.current.identifier,
            status: CaptureStatus(rawValue: statement.string(9) ?? "local") ?? .local,
            createdAt: statement.string(10) ?? "",
            updatedAt: statement.string(11) ?? ""
        )
    }
}

/// 列顺序集中一处，取值下标才不会随查询改动而错位。
/// 这类位置耦合是 SQLite 手写映射最容易出错的地方，所以宁可多一个常量。
let captureColumns = "id, kind, raw_text, transcript, ocr_text, user_edited, media_path, recorded_at, recorded_timezone, status, created_at, updated_at"
