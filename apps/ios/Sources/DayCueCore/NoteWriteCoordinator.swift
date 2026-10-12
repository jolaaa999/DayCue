import Foundation

/// 「本地笔记有变更」的通知口。
///
/// 为什么不直接在视图里写完就调 CloudSyncService：
///   1. DayCueCore 一旦引用 App 层的 @MainActor 类型，就再也不能在 macOS 上
///      swift test（Package.swift 的注释说明了这条边界）；
///   2. 「先写成功、再通知」这条顺序规则必须和写入绑在同一处，散在每个调用点
///      早晚会出现某条入口漏通知（例如只改了正文却没让云同步知道）。
/// 所以这里只声明「有变更」这件事本身，由谁来同步交给 AppContainer 装配时决定。
public protocol NoteLocalChangeReporting {

    /// 本地笔记写入（新建 / 编辑 / 删除）已经成功落库，可以入队同步了。
    func noteLocalChange()
}

/// 手动写入笔记时可能出现的业务错误。
public enum NoteWriteError: Error, Equatable {
    /// 标题和正文都是空的。不落库：列表里多一行没有任何信息的笔记，
    /// 只会让用户以为自己误触了什么。
    case emptyContent
}

/// 用户发起的笔记写入编排：新建 / 编辑 / 删除。
///
/// 与 AI 落库路径（NoteExtraction 的 applyNoteCandidates / applySelectedNoteDrafts）
/// 的边界必须说清楚：
///   - 这里新建的笔记 originKind 固定为 .manual，且 originCaptureId / originItemId
///     一律为 nil。手动创建没有原始记录，就不写任何 capture/item id 去假装有；
///   - AI 路径只按 (origin_capture_id, origin_item_id) 这两列定位已有笔记，
///     手动笔记这两列都是 NULL，所以 AI 重试永远匹配不到它——不会覆盖它，
///     也不可能把它从软删除状态里复活；
///   - 删除统一走 DayCueStore.softDeleteNote：deleted_at 只写一次，
///     且所有查询都过滤 deleted_at。
///
/// 权限与「记忆记录」开关的一致性（与 AI 笔记逐条核对过）：
///   - 写笔记本身不需要任何系统权限；AI 笔记的落库路径同样不检查权限。
///     记录阶段需要的麦克风/语音权限是「采集」的门槛，不是「笔记」的门槛。
///   - 两者都不受 isRecordingEnabled(category:) 约束。那个开关管的是长期记忆，
///     不是用户自己的笔记；若拿它去拦笔记，等于「关了记录就不许我手记」。
///   - 笔记要变成记忆，唯一入口是 MemoryIngestCoordinator.ingest，
///     那里会在**落库那一刻**再查一次 isRecordingEnabled，
///     所以手动笔记与 AI 笔记一样绕不过记忆开关。
public struct NoteWriteCoordinator {

    public let store: DayCueStore
    private let reporter: NoteLocalChangeReporting

    public init(store: DayCueStore, reporter: NoteLocalChangeReporting) {
        self.store = store
        self.reporter = reporter
    }

    // MARK: - 新建

    /// 手动新建一条笔记。
    ///
    /// id 可以显式传：这是「确定性 id」的能力，测试要构造主键冲突时用得上，
    /// 将来做草稿恢复也能保持 id 稳定；正常运行用默认值即可。
    @discardableResult
    public func createManualNote(
        title: String,
        body: String,
        tags: [String] = [],
        courseHint: String? = nil,
        occurredAt: String? = nil,
        id: String = DayCueID.new()
    ) throws -> NoteRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            throw NoteWriteError.emptyContent
        }

        let now = DayCueClock.nowUTCString()
        let record = NoteRecord(
            id: id,
            title: trimmedTitle,
            body: body,
            tags: NoteTagCodec.normalize(tags),
            // 课程提示留空时写 NULL：空串会被 notes(courseHint: "") 当成一个真实的筛选值。
            courseHint: Self.normalizedCourseHint(courseHint),
            originCaptureId: nil,
            originItemId: nil,
            originKind: .manual,
            // 手动笔记不靠 userEdited 防覆盖（AI 路径根本匹配不到它），
            // 置 false 是为了让「已编辑」这个界面信号只在用户真的改过之后出现。
            userEdited: false,
            occurredAt: occurredAt,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )

        let saved = try store.insertNote(record)
        // 只有 insertNote 正常返回才通知。抛出时把错误交给调用方，
        // 绝不能对外宣称「已经写入、已经排队同步」。
        reporter.noteLocalChange()
        return saved
    }

    // MARK: - 编辑

    /// 保存用户对标题 / 正文 / 标签的修改。
    ///
    /// 刻意**不接收** courseHint、originCaptureId、occurredAt：详情页目前不编辑这些字段，
    /// 参数里没有它们，调用方就不可能「顺手」把它们清成 nil（整行覆盖最容易丢字段）。
    /// 空内容在这里是允许的（用户清空一篇笔记是明确动作），与新建的规则不同。
    @discardableResult
    public func updateNoteContent(
        id: String,
        title: String,
        body: String,
        tags: [String]
    ) throws -> NoteRecord {
        guard var record = try store.note(id: id) else {
            throw NoteStoreError.noteNotFound(id)
        }

        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.body = body
        record.tags = NoteTagCodec.normalize(tags)
        // 与详情页原来的行为一致：把 user_edited 直接写进待更新行，
        // 紧接着的 markNoteUserEdited 只是把这条不变量再确认一遍。
        record.userEdited = true

        try store.updateNote(record)
        try store.markNoteUserEdited(id: id)

        reporter.noteLocalChange()
        guard let reloaded = try store.note(id: id) else {
            throw NoteStoreError.noteNotFound(id)
        }
        return reloaded
    }

    // MARK: - 删除

    /// 软删除一条笔记。
    ///
    /// 复用 softDeleteNote 而不是自己写 UPDATE：deleted_at 只在第一次删除时写入，
    /// 重复删除不推迟时间，对账/同步拿到的删除时间是稳定的。
    public func deleteNote(id: String) throws {
        try store.softDeleteNote(id: id)
        reporter.noteLocalChange()
    }

    private static func normalizedCourseHint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
