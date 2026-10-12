import Foundation

/// 一次「候选 -> 笔记录入」的结果。
///
/// 为什么必须显式给出 skipped：重试解析时「跳过一条用户改过的笔记」是正常业务结果，不是错误。
/// 只返回成功条数的话，界面就无法区分「后端这次没给这一条」和「给了但按规则没有覆盖」，
/// 也就没法如实告诉用户发生了什么。
public struct NoteUpsertOutcome: Equatable, Sendable {

    /// 新建的笔记条数。
    public var inserted: Int
    /// 覆盖更新的笔记条数（仅限用户未编辑过的）。
    public var updated: Int
    /// 因为是用户编辑过的而跳过的条数。
    public var skippedUserEdited: Int
    /// 因为已被用户删除而跳过的条数（不复活）。
    public var skippedDeleted: Int
    /// 因为候选本身没有任何可用内容而忽略的条数。
    public var skippedInvalid: Int

    public init(
        inserted: Int = 0,
        updated: Int = 0,
        skippedUserEdited: Int = 0,
        skippedDeleted: Int = 0,
        skippedInvalid: Int = 0
    ) {
        self.inserted = inserted
        self.updated = updated
        self.skippedUserEdited = skippedUserEdited
        self.skippedDeleted = skippedDeleted
        self.skippedInvalid = skippedInvalid
    }

    /// 被跳过的总数。调用方据此如实告诉用户「有几条没有写入」。
    public var skipped: Int {
        skippedUserEdited + skippedDeleted + skippedInvalid
    }

    /// 这一批候选完全没有产生任何动作（例如后端只返回了任务候选）。
    public var isEmpty: Bool {
        inserted == 0 && updated == 0 && skipped == 0
    }

    public mutating func merge(_ other: NoteUpsertOutcome) {
        inserted += other.inserted
        updated += other.updated
        skippedUserEdited += other.skippedUserEdited
        skippedDeleted += other.skippedDeleted
        skippedInvalid += other.skippedInvalid
    }

    /// 给用户看的一句话。
    ///
    /// 刻意不写成「成功/失败」的二选一：这段话要能解释「为什么某几条没有被覆盖」，
    /// 否则用户会以为解析结果丢了。
    public var summaryText: String {
        var parts: [String] = []
        if inserted > 0 { parts.append("新增 \(inserted) 条笔记") }
        if updated > 0 { parts.append("更新 \(updated) 条笔记") }
        if skippedUserEdited > 0 { parts.append("保留 \(skippedUserEdited) 条你改过的笔记") }
        if skippedDeleted > 0 { parts.append("跳过 \(skippedDeleted) 条你已删除的笔记") }
        if skippedInvalid > 0 { parts.append("忽略 \(skippedInvalid) 条没有内容的候选") }
        guard !parts.isEmpty else { return "这次解析没有产生笔记。" }
        return parts.joined(separator: "，") + "。"
    }
}

public extension DayCueStore {

    /// 把解析结果里 kind == note 的条目落成 NoteRecord。
    ///
    /// 幂等与优先级规则（与任务侧的 taskExists 同一套思路，但多两条）：
    /// 1. 同一个 (originCaptureId, originItemId) 只允许存在一条笔记；
    /// 2. 已存在且 user_edited = 1 → 跳过，绝不覆盖（用户改过的字不能被晚到的 AI 结果冲掉）；
    /// 3. 已存在且被软删除 → 跳过，不复活（用户删掉的东西不能因为一次重试又回来）；
    /// 4. 已存在且未编辑 → 更新内容，保留原 id、created_at 与用户自己加的标签。
    ///
    /// kind != note 的条目完全不参与统计：它们由任务路径处理，在这里计数会误导用户。
    @discardableResult
    func applyNoteCandidates(
        _ items: [ContractExtractionItem],
        captureId: String,
        occurredAt: String? = nil
    ) throws -> NoteUpsertOutcome {
        // 整批一个事务：要么全部按规则落库，要么一条都不写。
        // 半途失败会让「跳过了几条」这个计数与库里的真实状态对不上，用户看到的信息就是假的。
        return try database.transaction {
            var outcome = NoteUpsertOutcome()

            for item in items {
                guard item.kind == .note else { continue }

                let title = Self.noteTitle(for: item)
                let body = Self.noteBody(for: item)
                // 先判内容有效性：如果候选是空的，绝不能拿它去覆盖一条已有笔记的正文。
                guard !title.isEmpty || !body.isEmpty else {
                    outcome.skippedInvalid += 1
                    continue
                }

                let existing = try note(
                    originCaptureId: captureId,
                    originItemId: item.itemId,
                    includeDeleted: true
                )

                if let existing {
                    if existing.deletedAt != nil {
                        outcome.skippedDeleted += 1
                        continue
                    }
                    if existing.userEdited {
                        outcome.skippedUserEdited += 1
                        continue
                    }

                    var updated = existing
                    updated.title = title
                    updated.body = body
                    updated.courseHint = item.courseHint
                    // 标签是用户自己加的，后端候选里没有对应字段，绝不能在重试时抹掉。
                    updated.tags = existing.tags
                    // occurredAt 只在这次解析明确给出时才改，避免把已有的发生时间清空。
                    if let occurredAt { updated.occurredAt = occurredAt }
                    try updateNote(updated)
                    outcome.updated += 1
                    continue
                }

                let now = DayCueClock.nowUTCString()
                let record = NoteRecord(
                    id: DayCueID.new(),
                    title: title,
                    body: body,
                    tags: [],
                    courseHint: item.courseHint,
                    originCaptureId: captureId,
                    originItemId: item.itemId,
                    originKind: .capture,
                    userEdited: false,
                    occurredAt: occurredAt,
                    createdAt: now,
                    updatedAt: now,
                    deletedAt: nil
                )
                _ = try insertNote(record)
                outcome.inserted += 1
            }

            return outcome
        }
    }

    /// 契约响应入口。
    ///
    /// occurredAt 默认取这条记录的录入时刻：笔记的「发生时间」应当指向用户当时说话/拍照的时刻，
    /// 而不是这次解析的时刻，否则重试一次就把历史时间线改写了。
    @discardableResult
    func applyNoteCandidates(response: ExtractionResponse) throws -> NoteUpsertOutcome {
        // 局部变量不叫 capture：那会和 self.capture(id:) 同名，
        // 这种「靠作用域规则解释得通、但读者要停下来想一下」的写法不值得省一个词。
        let storedCapture = try capture(id: response.captureId)
        return try applyNoteCandidates(
            response.items,
            captureId: response.captureId,
            occurredAt: storedCapture?.recordedAt
        )
    }

    /// 标题：后端 title 优先；为空时退回证据文本的首行。
    ///
    /// 为什么不给「未命名笔记」这类兜底文案：那会把「后端没给标题」伪装成一条正常笔记，
    /// 用户点进去看不到任何可判断的信息；拿证据首行至少能让他认出这条笔记的来源。
    private static func noteTitle(for item: ContractExtractionItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return String(firstNonEmptyLine(of: item.sourceEvidence).prefix(60))
    }

    /// 正文：detail 优先，退回证据原文（body 在库里是 NOT NULL，没有内容时给空串）。
    private static func noteBody(for item: ContractExtractionItem) -> String {
        if let detail = item.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        return item.sourceEvidence
    }

    private static func firstNonEmptyLine(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
