import Foundation

// MARK: - 枚举：取值范围必须与 SQLite CHECK 约束、契约文档一一对应

/// 捕获类型。rawValue 直接进库，所以一旦发布就不能改。
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case text
    case audio
    case image

    public var displayName: String {
        switch self {
        case .text: return "文字"
        case .audio: return "录音"
        case .image: return "图片"
        }
    }
}

/// 捕获项在本地的处理状态。用户先看到 local（已保存），随后才是解析中的状态。
public enum CaptureStatus: String, Codable, CaseIterable, Sendable {
    /// 已保存到本机，尚未发起解析
    case local
    /// 正在调用后端解析
    case extracting
    /// 解析完成，已有候选
    case extracted
    /// 解析失败（网络/超时/模型输出非法）
    case failed
    /// 存在必须用户澄清的歧义
    case needsClarification = "needs_clarification"

    public var displayName: String {
        switch self {
        case .local: return "已保存到本机"
        case .extracting: return "解析中"
        case .extracted: return "解析完成"
        case .failed: return "解析失败"
        case .needsClarification: return "需要澄清"
        }
    }
}

public enum ProposalStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected
    case needsClarification = "needs_clarification"

    public var displayName: String {
        switch self {
        case .pending: return "待确认"
        case .accepted: return "已确认"
        case .rejected: return "已忽略"
        case .needsClarification: return "需要澄清"
        }
    }
}

/// 解析模式。fixture 是后端显式启用的模拟结果，UI 必须标注「模拟结果」。
public enum ExtractionMode: String, Codable, CaseIterable, Sendable {
    case live
    case fixture

    public var displayName: String {
        switch self {
        case .live: return "真实解析"
        case .fixture: return "模拟结果"
        }
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case open
    case done
    case cancelled

    public var displayName: String {
        switch self {
        case .open: return "待办"
        case .done: return "已完成"
        case .cancelled: return "已取消"
        }
    }
}

/// 截止时间的形态。date 型只有年月日，绝不能补一个假的 UTC 午夜。
public enum DueKind: String, Codable, CaseIterable, Sendable {
    case none
    case date
    case datetime
}

/// 写入苹果提醒事项的状态。
///
/// 这个枚举是「五个独立阶段」里系统写入那一段的唯一真相来源；
/// UI 显示的四选一文案就是从这里推导，不允许别处再拼状态文案。
public enum ExternalWriteState: String, Codable, CaseIterable, Sendable {
    case notRequested = "not_requested"
    case waitingForPermission = "waiting_for_permission"
    case pending
    case written
    case failed
    case unknown
    case needsReconciliation = "needs_reconciliation"

    /// 今天页「四选一」文案。
    public var displayName: String {
        switch self {
        case .notRequested: return "仅保存在 App"
        case .waitingForPermission: return "等待写入苹果提醒事项"
        case .pending: return "等待写入苹果提醒事项"
        case .written: return "已写入苹果提醒事项"
        case .failed: return "写入失败"
        case .unknown: return "写入状态未知，待对账"
        case .needsReconciliation: return "写入状态待对账"
        }
    }

    /// 是否需要出现在今天页的「同步异常」分区。
    public var isSyncIssue: Bool {
        switch self {
        case .failed, .unknown, .needsReconciliation:
            return true
        case .notRequested, .waitingForPermission, .pending, .written:
            return false
        }
    }
}

/// 外部状态机。只允许这里列出的迁移，防止「失败回执把 written 打回 pending」这类倒退。
public enum ExternalWriteStateMachine {
    /// 单步迁移表。注意 pending 不再指向 written 的反向迁移——回执只能前进或转对账。
    private static let allowed: [ExternalWriteState: Set<ExternalWriteState>] = [
        .notRequested: [.waitingForPermission, .pending, .failed],
        .waitingForPermission: [.pending, .failed, .notRequested],
        .pending: [.written, .failed, .unknown, .waitingForPermission],
        .written: [.needsReconciliation, .failed, .unknown],
        .failed: [.pending, .unknown, .needsReconciliation, .waitingForPermission],
        .unknown: [.needsReconciliation, .written, .failed, .pending],
        .needsReconciliation: [.written, .failed, .pending, .unknown]
    ]

    public static func canTransition(from: ExternalWriteState, to: ExternalWriteState) -> Bool {
        if from == to { return true }
        return allowed[from]?.contains(to) ?? false
    }

    /// 非法迁移返回 nil，由调用方决定是记录日志还是抛出错误；这里不抛异常，
    /// 因为同步流程里「拒绝一次非法迁移」不应该中断整批对账。
    public static func transition(from: ExternalWriteState, to: ExternalWriteState) -> ExternalWriteState? {
        canTransition(from: from, to: to) ? to : nil
    }
}

public enum OutboxEntityType: String, Codable, CaseIterable, Sendable {
    case task
    case capture
    case proposal
    case externalBinding = "external_binding"

    public var displayName: String {
        switch self {
        case .task: return "任务"
        case .capture: return "记录"
        case .proposal: return "候选"
        case .externalBinding: return "外部绑定"
        }
    }
}

public enum OutboxOperationKind: String, Codable, CaseIterable, Sendable {
    /// 创建苹果提醒事项
    case createReminder = "create_reminder"
    /// 删除苹果提醒事项
    case deleteReminder = "delete_reminder"
    /// 更新苹果提醒事项
    case updateReminder = "update_reminder"
    /// 上传捕获并解析
    case extractCapture = "extract_capture"

    public var displayName: String {
        switch self {
        case .createReminder: return "创建提醒"
        case .deleteReminder: return "删除提醒"
        case .updateReminder: return "更新提醒"
        case .extractCapture: return "解析记录"
        }
    }
}

public enum OutboxState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case unknown

    public var isTerminal: Bool {
        self == .succeeded
    }
}

/// 候选条目的类型。note 没有行动意图，不应该自动变成提醒。
public enum ProposalItemKind: String, Codable, CaseIterable, Sendable {
    case task
    case note

    public var displayName: String {
        switch self {
        case .task: return "任务"
        case .note: return "笔记"
        }
    }
}

/// 已知歧义码 + 开放枚举兜底。
///
/// 契约明确说 ambiguities[].code 是开放枚举，客户端遇到未知 code 必须按「需要澄清」处理，
/// 所以这里保留 unknown 分支而不是把 code 直接当 String 用。
/// 注意：这里只声明 RawRepresentable/Hashable，不声明 Codable。
/// 它的编解码统一由 ContractAmbiguity 用 rawValue 手工处理，
/// 少一个"依赖编译器为带关联值枚举合成 Codable"的隐含约定。
public enum AmbiguityCode: RawRepresentable, Hashable, Sendable {
    case deadlineOnly
    case missingYear
    case weekdayDateConflict
    case ambiguousAMPM
    case ambiguousPlace
    case unresolvedDate
    case pastTime
    case dstNonexistent
    case dstAmbiguous
    case assumedNextDay
    case modelUncertain
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "deadline_only": self = .deadlineOnly
        case "missing_year": self = .missingYear
        case "weekday_date_conflict": self = .weekdayDateConflict
        case "ambiguous_ampm": self = .ambiguousAMPM
        case "ambiguous_place": self = .ambiguousPlace
        case "unresolved_date": self = .unresolvedDate
        case "past_time": self = .pastTime
        case "dst_nonexistent": self = .dstNonexistent
        case "dst_ambiguous": self = .dstAmbiguous
        case "assumed_next_day": self = .assumedNextDay
        case "model_uncertain": self = .modelUncertain
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .deadlineOnly: return "deadline_only"
        case .missingYear: return "missing_year"
        case .weekdayDateConflict: return "weekday_date_conflict"
        case .ambiguousAMPM: return "ambiguous_ampm"
        case .ambiguousPlace: return "ambiguous_place"
        case .unresolvedDate: return "unresolved_date"
        case .pastTime: return "past_time"
        case .dstNonexistent: return "dst_nonexistent"
        case .dstAmbiguous: return "dst_ambiguous"
        case .assumedNextDay: return "assumed_next_day"
        case .modelUncertain: return "model_uncertain"
        case .unknown(let raw): return raw
        }
    }

    /// 未知 code 一律要求澄清；已知 code 里只有「只是截止日」这类提示性歧义不强制澄清。
    public var requiresClarification: Bool {
        switch self {
        case .deadlineOnly, .assumedNextDay:
            return false
        case .unknown:
            return true
        default:
            return true
        }
    }

    public var displayName: String {
        switch self {
        case .deadlineOnly: return "只设了截止日，未设提醒时刻"
        case .missingYear: return "缺少年份"
        case .weekdayDateConflict: return "日期与星期不一致"
        case .ambiguousAMPM: return "上午/下午不明确"
        case .ambiguousPlace: return "地点不明确"
        case .unresolvedDate: return "日期无法确定"
        case .pastTime: return "时间已经过去"
        case .dstNonexistent: return "夏令时跳过的时刻"
        case .dstAmbiguous: return "夏令时重复的时刻"
        case .assumedNextDay: return "按次日理解"
        case .modelUncertain: return "模型不确定"
        case .unknown(let raw): return "未识别的歧义（\(raw)）"
        }
    }
}

// MARK: - 记录结构

/// 一条捕获记录。对应 capture_item 表。
public struct CaptureRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: CaptureKind
    public var rawText: String?
    public var transcript: String?
    public var ocrText: String?
    /// 用户是否手工改过文本。置 1 之后，晚到的解析结果不得覆盖文本字段。
    public var userEdited: Bool
    public var mediaPath: String?
    /// UTC RFC3339 字符串
    public var recordedAt: String
    /// 录入时所在时区（IANA）
    public var recordedTimezone: String
    public var status: CaptureStatus
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = DayCueID.new(),
        kind: CaptureKind,
        rawText: String? = nil,
        transcript: String? = nil,
        ocrText: String? = nil,
        userEdited: Bool = false,
        mediaPath: String? = nil,
        recordedAt: String,
        recordedTimezone: String,
        status: CaptureStatus = .local,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.rawText = rawText
        self.transcript = transcript
        self.ocrText = ocrText
        self.userEdited = userEdited
        self.mediaPath = mediaPath
        self.recordedAt = recordedAt
        self.recordedTimezone = recordedTimezone
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayText: String {
        if let rawText, !rawText.isEmpty { return rawText }
        if let transcript, !transcript.isEmpty { return transcript }
        if let ocrText, !ocrText.isEmpty { return ocrText }
        return kind.displayName + "记录"
    }

    /// 交给解析后端的正文。用户编辑优先，其次才是识别结果。
    public var effectiveText: String {
        if let rawText, !rawText.isEmpty { return rawText }
        if let transcript, !transcript.isEmpty { return transcript }
        return ocrText ?? ""
    }
}

public struct AttachmentRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var captureId: String
    public var mediaType: String
    public var localPath: String
    public var byteSize: Int
    public var sha256: String
    public var createdAt: String

    public init(
        id: String = DayCueID.new(),
        captureId: String,
        mediaType: String,
        localPath: String,
        byteSize: Int,
        sha256: String,
        createdAt: String
    ) {
        self.id = id
        self.captureId = captureId
        self.mediaType = mediaType
        self.localPath = localPath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}

/// 一次解析响应落库后的形态。payload_json 保留后端原文，便于后续追溯和对账。
public struct ProposalRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var captureId: String
    public var schemaVersion: String
    public var payloadJSON: String
    public var mode: ExtractionMode
    public var status: ProposalStatus
    public var createdAt: String

    public init(
        id: String = DayCueID.new(),
        captureId: String,
        schemaVersion: String,
        payloadJSON: String,
        mode: ExtractionMode,
        status: ProposalStatus = .pending,
        createdAt: String
    ) {
        self.id = id
        self.captureId = captureId
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
        self.mode = mode
        self.status = status
        self.createdAt = createdAt
    }
}

/// 任务。字段名与 SQLite 列名保持一一对应，读写时不做隐式换算。
public struct TaskRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var status: TaskStatus
    public var dueKind: DueKind
    /// 用户时区下的墙上时间：date 型是 YYYY-MM-DD，datetime 型是 YYYY-MM-DDTHH:MM:SS
    public var dueLocal: String?
    /// 仅 datetime 型有值，UTC RFC3339
    public var dueUTC: String?
    public var timezone: String
    public var remindLocal: String?
    public var remindUTC: String?
    public var courseHint: String?
    public var originCaptureId: String?
    public var originItemId: String?
    public var externalWriteState: ExternalWriteState
    public var lastReceiptAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String = DayCueID.new(),
        title: String,
        detail: String? = nil,
        status: TaskStatus = .open,
        dueKind: DueKind = .none,
        dueLocal: String? = nil,
        dueUTC: String? = nil,
        timezone: String = TimeZone.current.identifier,
        remindLocal: String? = nil,
        remindUTC: String? = nil,
        courseHint: String? = nil,
        originCaptureId: String? = nil,
        originItemId: String? = nil,
        externalWriteState: ExternalWriteState = .notRequested,
        lastReceiptAt: String? = nil,
        createdAt: String = "",
        updatedAt: String = "",
        deletedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.dueKind = dueKind
        self.dueLocal = dueLocal
        self.dueUTC = dueUTC
        self.timezone = timezone
        self.remindLocal = remindLocal
        self.remindUTC = remindUTC
        self.courseHint = courseHint
        self.originCaptureId = originCaptureId
        self.originItemId = originItemId
        self.externalWriteState = externalWriteState
        self.lastReceiptAt = lastReceiptAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

public struct ExternalBindingRecord: Equatable, Sendable {
    public var taskId: String
    public var provider: String
    public var listId: String?
    public var listTitle: String?
    public var externalId: String?
    public var externalLastModified: String?
    public var snapshotJSON: String?
    public var createdAt: String

    public init(
        taskId: String,
        provider: String,
        listId: String? = nil,
        listTitle: String? = nil,
        externalId: String? = nil,
        externalLastModified: String? = nil,
        snapshotJSON: String? = nil,
        createdAt: String
    ) {
        self.taskId = taskId
        self.provider = provider
        self.listId = listId
        self.listTitle = listTitle
        self.externalId = externalId
        self.externalLastModified = externalLastModified
        self.snapshotJSON = snapshotJSON
        self.createdAt = createdAt
    }
}

public struct OutboxOperationRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var entityType: OutboxEntityType
    public var entityId: String
    public var op: OutboxOperationKind
    /// 确定性生成的幂等键，禁止用随机 UUID。库上有 UNIQUE 约束兜底。
    public var idempotencyKey: String
    public var payloadJSON: String?
    public var attempt: Int
    public var state: OutboxState
    public var nextRetryAt: String?
    public var lastError: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = DayCueID.new(),
        entityType: OutboxEntityType,
        entityId: String,
        op: OutboxOperationKind,
        idempotencyKey: String,
        payloadJSON: String? = nil,
        attempt: Int = 0,
        state: OutboxState = .pending,
        nextRetryAt: String? = nil,
        lastError: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.entityType = entityType
        self.entityId = entityId
        self.op = op
        self.idempotencyKey = idempotencyKey
        self.payloadJSON = payloadJSON
        self.attempt = attempt
        self.state = state
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 第一阶段只建表不写入。保留结构是为了让表结构与后续阶段一致，避免日后迁移改字段名。
public struct MemoryRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var statement: String
    public var status: String
    public var sourceCaptureId: String?
    public var reviewAt: String?
    public var createdAt: String
    public var deletedAt: String?

    public init(
        id: String = DayCueID.new(),
        kind: String,
        statement: String,
        status: String,
        sourceCaptureId: String? = nil,
        reviewAt: String? = nil,
        createdAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.statement = statement
        self.status = status
        self.sourceCaptureId = sourceCaptureId
        self.reviewAt = reviewAt
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

// MARK: - 第二阶段及以后：笔记 / 课表 / 追问 / 记忆 / 地点 / 主动消息 / 同步
//
// 这些类型与 Schema v2 的表一一对应。放在同一个文件里，是为了让
// 「表结构」与「内存模型」的差异一眼可见——两者一旦分家，迁移就会写错。

/// 笔记的来源。保留来源是为了让「这条笔记从哪来」永远可追溯。
public enum NoteOriginKind: String, Codable, CaseIterable, Sendable {
    case capture
    case followUp = "follow_up"
    case manual
    case memory

    public var displayName: String {
        switch self {
        case .capture: return "记录"
        case .followUp: return "课后回复"
        case .manual: return "手动创建"
        case .memory: return "记忆"
        }
    }
}

/// 可持久化的笔记。不再是 proposal.payload_json 里的一个片段。
public struct NoteRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var courseHint: String?
    public var originCaptureId: String?
    public var originItemId: String?
    public var originKind: NoteOriginKind
    /// 用户改过的笔记不允许被重试解析覆盖，与 capture 的 userEdited 同一套规则。
    public var userEdited: Bool
    public var occurredAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String,
        title: String,
        body: String,
        tags: [String] = [],
        courseHint: String? = nil,
        originCaptureId: String? = nil,
        originItemId: String? = nil,
        originKind: NoteOriginKind = .manual,
        userEdited: Bool = false,
        occurredAt: String? = nil,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.courseHint = courseHint
        self.originCaptureId = originCaptureId
        self.originItemId = originItemId
        self.originKind = originKind
        self.userEdited = userEdited
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// 单双周。week_parity 只描述纸面规则，不代表某次课真的上了。
public enum WeekParity: String, Codable, CaseIterable, Sendable {
    case all
    case odd
    case even

    public var displayName: String {
        switch self {
        case .all: return "每周"
        case .odd: return "单周"
        case .even: return "双周"
        }
    }
}

/// 课程。followUpEnabled 是「按课程开关课后追问」的落点。
public struct CourseRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var teacher: String?
    public var location: String?
    public var term: String?
    public var color: String?
    public var followUpEnabled: Bool
    public var followUpDelayMinutes: Int
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String,
        name: String,
        teacher: String? = nil,
        location: String? = nil,
        term: String? = nil,
        color: String? = nil,
        followUpEnabled: Bool = false,
        followUpDelayMinutes: Int = 5,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.teacher = teacher
        self.location = location
        self.term = term
        self.color = color
        self.followUpEnabled = followUpEnabled
        self.followUpDelayMinutes = followUpDelayMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// 每周重复规则：星期几 + 节次 + 单双周 + 生效周范围。
public struct CourseScheduleRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var courseId: String
    public var weekday: Int
    public var sectionStart: Int
    public var sectionEnd: Int
    public var startTimeLocal: String
    public var endTimeLocal: String
    public var weekParity: WeekParity
    public var weekStart: Int
    public var weekEnd: Int
    public var effectiveFrom: String?
    public var effectiveTo: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        courseId: String,
        weekday: Int,
        sectionStart: Int,
        sectionEnd: Int,
        startTimeLocal: String,
        endTimeLocal: String,
        weekParity: WeekParity = .all,
        weekStart: Int = 1,
        weekEnd: Int = 30,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.courseId = courseId
        self.weekday = weekday
        self.sectionStart = sectionStart
        self.sectionEnd = sectionEnd
        self.startTimeLocal = startTimeLocal
        self.endTimeLocal = endTimeLocal
        self.weekParity = weekParity
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum CourseInstanceStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case cancelled
    case rescheduled

    public var displayName: String {
        switch self {
        case .scheduled: return "正常"
        case .cancelled: return "停课"
        case .rescheduled: return "调课"
        }
    }
}

public enum CourseInstanceOrigin: String, Codable, CaseIterable, Sendable {
    case rule
    case manual
    case ics
    case ocr

    public var displayName: String {
        switch self {
        case .rule: return "由课表生成"
        case .manual: return "手动添加"
        case .ics: return "ICS 导入"
        case .ocr: return "图片识别"
        }
    }
}

/// 一次具体的课。endsAtUTC 是**预计**结束时间，只用来排通知。
/// 它不是「实际下课」，更不是出勤记录——这条限制写在类型注释里，防止后面被误用。
public struct CourseInstanceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var courseId: String
    public var ruleId: String?
    public var startsAtUTC: String
    public var endsAtUTC: String
    public var timezone: String
    public var status: CourseInstanceStatus
    public var location: String?
    public var note: String?
    public var origin: CourseInstanceOrigin
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        courseId: String,
        ruleId: String? = nil,
        startsAtUTC: String,
        endsAtUTC: String,
        timezone: String,
        status: CourseInstanceStatus = .scheduled,
        location: String? = nil,
        note: String? = nil,
        origin: CourseInstanceOrigin = .rule,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.courseId = courseId
        self.ruleId = ruleId
        self.startsAtUTC = startsAtUTC
        self.endsAtUTC = endsAtUTC
        self.timezone = timezone
        self.status = status
        self.location = location
        self.note = note
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum FollowUpState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case delivered
    case snoozed
    case skipped
    case answered
    case expired
    case cancelled

    public var displayName: String {
        switch self {
        case .scheduled: return "已安排"
        case .delivered: return "已发出"
        case .snoozed: return "稍后提醒"
        case .skipped: return "已跳过"
        case .answered: return "已回复"
        case .expired: return "已过期"
        case .cancelled: return "已取消"
        }
    }

    /// 终态不允许再被调度器拾取，否则会出现「跳过之后又被追问」。
    public var isTerminal: Bool {
        switch self {
        case .answered, .skipped, .expired, .cancelled: return true
        case .scheduled, .delivered, .snoozed: return false
        }
    }
}

public struct FollowUpRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var courseInstanceId: String
    public var courseId: String
    public var state: FollowUpState
    public var scheduledAtUTC: String
    public var deliveredAtUTC: String?
    public var snoozeUntilUTC: String?
    public var attempt: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        courseInstanceId: String,
        courseId: String,
        state: FollowUpState = .scheduled,
        scheduledAtUTC: String,
        deliveredAtUTC: String? = nil,
        snoozeUntilUTC: String? = nil,
        attempt: Int = 0,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.courseInstanceId = courseInstanceId
        self.courseId = courseId
        self.state = state
        self.scheduledAtUTC = scheduledAtUTC
        self.deliveredAtUTC = deliveredAtUTC
        self.snoozeUntilUTC = snoozeUntilUTC
        self.attempt = attempt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum FollowUpReplyKind: String, Codable, CaseIterable, Sendable {
    case text
    case audio
}

/// 课后回复。归档后必须能顺着 noteId / taskId 找回关联。
public struct FollowUpReplyRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var followUpId: String
    public var courseId: String
    public var kind: FollowUpReplyKind
    public var text: String?
    public var transcript: String?
    public var mediaPath: String?
    public var noteId: String?
    public var taskId: String?
    public var createdAt: String

    public init(
        id: String,
        followUpId: String,
        courseId: String,
        kind: FollowUpReplyKind,
        text: String? = nil,
        transcript: String? = nil,
        mediaPath: String? = nil,
        noteId: String? = nil,
        taskId: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.followUpId = followUpId
        self.courseId = courseId
        self.kind = kind
        self.text = text
        self.transcript = transcript
        self.mediaPath = mediaPath
        self.noteId = noteId
        self.taskId = taskId
        self.createdAt = createdAt
    }
}

/// 记忆状态。candidate 是推断出来的候选，confirmed 才算用户认可的事实。
public enum MemoryStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    case confirmed
    case retired
    case conflict

    public var displayName: String {
        switch self {
        case .candidate: return "候选"
        case .confirmed: return "已确认"
        case .retired: return "已失效"
        case .conflict: return "有冲突"
        }
    }

    /// 检索时只允许取出可用的记忆：候选与冲突都不能当作事实使用。
    public var isUsableAsFact: Bool { self == .confirmed }
}

/// 来源类型。inferred 永远不能冒充 user_setting / user_statement。
public enum MemorySourceKind: String, Codable, CaseIterable, Sendable {
    case userSetting = "user_setting"
    case userStatement = "user_statement"
    case inferred

    public var displayName: String {
        switch self {
        case .userSetting: return "用户设置"
        case .userStatement: return "用户说过"
        case .inferred: return "推断"
        }
    }

    /// 能不能作为「用户事实」直接用于回答。
    public var isUserAsserted: Bool { self != .inferred }
}

/// 记忆类别。控制「停止记录某类别」的粒度。
public enum MemoryCategory: String, Codable, CaseIterable, Sendable {
    case preference
    case goal
    case phase
    case experience
    case person
    case place

    public var displayName: String {
        switch self {
        case .preference: return "偏好"
        case .goal: return "目标"
        case .phase: return "阶段状态"
        case .experience: return "经历"
        case .person: return "人物"
        case .place: return "地点"
        }
    }
}

/// 记忆主记录。statement 是当前生效的说法，历史在 memory_revision 里。
public struct MemoryItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var category: MemoryCategory
    public var statement: String
    public var status: MemoryStatus
    public var sourceKind: MemorySourceKind
    public var confidence: Double?
    public var sourceRef: String?
    public var revision: Int
    public var effectiveFrom: String?
    public var effectiveTo: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String,
        category: MemoryCategory,
        statement: String,
        status: MemoryStatus = .candidate,
        sourceKind: MemorySourceKind = .inferred,
        confidence: Double? = nil,
        sourceRef: String? = nil,
        revision: Int = 1,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.category = category
        self.statement = statement
        self.status = status
        self.sourceKind = sourceKind
        self.confidence = confidence
        self.sourceRef = sourceRef
        self.revision = revision
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
