import Foundation

/// 预览页里可编辑的一条候选。
///
/// 为什么不直接用 ContractExtractionItem：用户在预览里可以改标题、改时间、改 kind，
/// 甚至给「周五之前」手工补一个提醒时刻。这些修订必须有地方落，
/// 而且「用户改过什么」要能被判断出来（晚到的 AI 结果不能覆盖）。
public struct ReviewDraft: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ProposalItemKind
    public var title: String
    public var detail: String?
    public var sourceEvidence: String
    public var dateExpression: String?
    public var dueKind: DueKind
    /// 用户时区下的墙上时间；date 型是 YYYY-MM-DD，datetime 型是 YYYY-MM-DDTHH:MM:SS
    public var dueLocal: String?
    public var dueUTC: String?
    public var timezone: String
    public var remindLocal: String?
    public var remindUTC: String?
    public var courseHint: String?
    public var ambiguities: [ContractAmbiguity]
    public var confidence: Double?
    public var isSelected: Bool
    /// 用户是否亲手改过时间。撤销功能据此判断「这不是自动创建的原样」。
    public var hasUserEditedTime: Bool
    /// mode=fixture 时界面上必须标注「模拟结果」。
    public var isFixture: Bool

    public init(
        id: String,
        kind: ProposalItemKind,
        title: String,
        detail: String? = nil,
        sourceEvidence: String,
        dateExpression: String? = nil,
        dueKind: DueKind,
        dueLocal: String? = nil,
        dueUTC: String? = nil,
        timezone: String,
        remindLocal: String? = nil,
        remindUTC: String? = nil,
        courseHint: String? = nil,
        ambiguities: [ContractAmbiguity] = [],
        confidence: Double? = nil,
        isSelected: Bool = true,
        hasUserEditedTime: Bool = false,
        isFixture: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sourceEvidence = sourceEvidence
        self.dateExpression = dateExpression
        self.dueKind = dueKind
        self.dueLocal = dueLocal
        self.dueUTC = dueUTC
        self.timezone = timezone
        self.remindLocal = remindLocal
        self.remindUTC = remindUTC
        self.courseHint = courseHint
        self.ambiguities = ambiguities
        self.confidence = confidence
        self.isSelected = isSelected
        self.hasUserEditedTime = hasUserEditedTime
        self.isFixture = isFixture
    }

    /// 「尚未设置提醒时间」。提醒为 null 只说明没有提醒时刻，不代表没有截止时间。
    public var hasReminder: Bool {
        remindLocal != nil || remindUTC != nil
    }

    public var deadlineOnly: Bool {
        dueKind != .none && !hasReminder
    }

    /// 展示用：先按 due_kind 分流，避免日期型被渲染成带时刻的字符串。
    public var dueText: String? {
        TaskTimeDisplay.dueText(kind: dueKind, local: dueLocal)
    }

    public var remindText: String? {
        remindLocal.flatMap { TaskTimeDisplay.dateTimeText($0) }
    }

    public var requiresClarification: Bool {
        ambiguities.contains { $0.code.requiresClarification }
    }

    // MARK: - 转换

    /// 后端候选 -> 可编辑草稿。这里不做任何「补全」：remind 为 null 就保持 null。
    public static func from(item: ContractExtractionItem, mode: ExtractionMode) -> ReviewDraft {
        ReviewDraft(
            id: item.itemId,
            kind: item.kind,
            title: item.title,
            detail: item.detail,
            sourceEvidence: item.sourceEvidence,
            dateExpression: item.dateExpression,
            dueKind: item.due.kind,
            dueLocal: item.due.local,
            dueUTC: item.due.utc,
            timezone: item.due.timezone ?? TimeZone.current.identifier,
            remindLocal: item.remind?.local,
            remindUTC: item.remind?.utc,
            courseHint: item.courseHint,
            ambiguities: item.ambiguities,
            confidence: item.confidence,
            isSelected: true,
            hasUserEditedTime: false,
            isFixture: mode == .fixture
        )
    }

    public static func from(response: ExtractionResponse) -> [ReviewDraft] {
        response.items.map { from(item: $0, mode: response.mode) }
    }

    /// 草稿 -> 任务行。
    ///
    /// 任务只从 kind == .task 的草稿生成：笔记没有行动意图，不应该变成提醒。
    public func makeTask(captureId: String, now: String = DayCueClock.nowUTCString()) -> TaskRecord {
        TaskRecord(
            title: title,
            detail: detail,
            status: .open,
            dueKind: dueKind,
            dueLocal: dueLocal,
            dueUTC: dueUTC,
            timezone: timezone,
            remindLocal: remindLocal,
            remindUTC: remindUTC,
            courseHint: courseHint,
            originCaptureId: captureId,
            originItemId: id,
            externalWriteState: .notRequested,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 用户手工加提醒时用这个，统一把 local 与 utc 一起算出来，
    /// 避免出现「只有 local 没有 utc」的半截数据。
    public mutating func setReminder(date: Date, timeZone: TimeZone) {
        remindLocal = RFC3339.localString(from: date, timeZone: timeZone)
        remindUTC = RFC3339.utcString(from: date)
        hasUserEditedTime = true
    }

    public mutating func clearReminder() {
        remindLocal = nil
        remindUTC = nil
        hasUserEditedTime = true
    }

    /// 用户在预览里改截止时间。
    public mutating func setDue(kind: DueKind, date: Date?, timeZone: TimeZone) {
        dueKind = kind
        timezone = timeZone.identifier
        guard let date else {
            dueLocal = nil
            dueUTC = nil
            hasUserEditedTime = true
            return
        }
        switch kind {
        case .none:
            dueLocal = nil
            dueUTC = nil
        case .date:
            // 日期型只有年月日：写墙上时间，不写 UTC，避免伪造当日午夜。
            dueLocal = RFC3339.localDateString(from: date, timeZone: timeZone)
            dueUTC = nil
        case .datetime:
            dueLocal = RFC3339.localString(from: date, timeZone: timeZone)
            dueUTC = RFC3339.utcString(from: date)
        }
        hasUserEditedTime = true
    }
}
