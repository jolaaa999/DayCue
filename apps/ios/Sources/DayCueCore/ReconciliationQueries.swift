import Foundation

// 对账的查询语义。
//
// 这一层的唯一职责是把「查到了什么」和「这次查询可不可信」分开表达。
// 一旦把「查询失败」塌缩成「没有这条」，对账就会去删用户的数据——
// 所以类型里必须留出「范围不完整」这个状态，而不是靠调用方自觉。

/// 一次外部快照查询的可信范围。
///
/// 结论枚举直接复用 ReminderLookupOutcome，而不是另造一套词汇：
/// 「查不了」和「确实没有」必须用同一套枚举表达，
/// 否则对账层某天就会把 queryFailed 当成 notFound，然后据此删掉本地数据。
public enum ReminderSnapshotScope: Equatable, Sendable {
    /// 已授权，且未完成 / 已完成两段查询都成功返回。
    case complete
    /// 查询不可信。关联的结论说明具体是哪一种失败。
    case incomplete(ReminderLookupOutcome)

    public var isComplete: Bool { self == .complete }
    public var isIncomplete: Bool { !isComplete }

    /// 只有范围完整的整轮对账才允许传播删除（删本地或删外部）。
    /// 这是「查询失败绝不能被当作项目不存在」在对账层的第一道闸门。
    public var allowsDeletionPropagation: Bool { isComplete }

    /// 给人看的诊断名。与 ReminderLookupOutcome.diagnosticName 用同一套措辞。
    public var diagnosticName: String {
        switch self {
        case .complete: return "查询完整"
        case let .incomplete(outcome): return outcome.diagnosticName
        }
    }

    /// 界面文案。不完整时必须明确写出「未做任何删除」，避免用户误以为已经清理过。
    public var userFacingMessage: String {
        switch self {
        case .complete:
            return "本次对账查询完整，可以按结论处理删除。"
        case let .incomplete(outcome):
            return "对账不完整（\(outcome.diagnosticName)），未做任何删除。"
        }
    }
}

/// 一段查询的结果（未完成段 / 已完成段）。
///
/// 形状刻意与 ReminderLookupPolicy.Fetch 保持一致：success 与 items 必须分开，
/// 因为 EventKit 用「回调收到 nil」表示这一批没取到，而那不等于「这一批是空的」。
public struct ReminderSnapshotSegment: Equatable, Sendable {
    public let succeeded: Bool
    public let items: [ExternalReminderSnapshot]

    public init(succeeded: Bool, items: [ExternalReminderSnapshot] = []) {
        self.succeeded = succeeded
        self.items = items
    }

    public static let failed = ReminderSnapshotSegment(succeeded: false)

    public static func ok(_ items: [ExternalReminderSnapshot]) -> ReminderSnapshotSegment {
        ReminderSnapshotSegment(succeeded: true, items: items)
    }
}

/// 一次完整的外部快照拉取结果。
///
/// items 只在 scope 可信时才能当作「全量」；不完整时它只是「已经看到的那部分」，
/// 调用方与引擎都不允许从它的缺失推断出删除。
public struct ExternalSnapshotFetch: Equatable, Sendable {
    public let scope: ReminderSnapshotScope
    public let items: [ExternalReminderSnapshot]

    public init(scope: ReminderSnapshotScope, items: [ExternalReminderSnapshot]) {
        self.scope = scope
        self.items = items
    }

    public static func complete(_ items: [ExternalReminderSnapshot]) -> ExternalSnapshotFetch {
        ExternalSnapshotFetch(scope: .complete, items: items)
    }

    /// 查询失败时仍然可以带上已经拿到的部分条目（用于展示），但 scope 会标记为不可信。
    public static func incomplete(
        _ outcome: ReminderLookupOutcome,
        partialItems: [ExternalReminderSnapshot] = []
    ) -> ExternalSnapshotFetch {
        ExternalSnapshotFetch(scope: .incomplete(outcome), items: partialItems)
    }
}

public enum ReminderSnapshotQuery {

    /// 由「是否授权 + 两段查询各自是否成功」得出可信范围。
    ///
    /// 只有两段都成功才算完整：EventKit 的未完成与已完成是两个不同谓词，
    /// 漏掉一段就等于把用户勾掉的那条当成不存在。
    public static func classifyScope(
        authorized: Bool,
        incompleteSucceeded: Bool,
        completedSucceeded: Bool
    ) -> ReminderSnapshotScope {
        guard authorized else { return .incomplete(.notAuthorized) }
        switch (incompleteSucceeded, completedSucceeded) {
        case (true, true):
            return .complete
        case (false, false):
            return .incomplete(.queryFailed)
        default:
            return .incomplete(.incompleteScope)
        }
    }

    /// 把两段查询合并成一次对账输入。
    ///
    /// 不完整时只回传「成功那一段」的条目：失败段的空数组只代表没查成，
    /// 绝不能进入 items 被下游当成「外部确实没有这些项」。
    public static func make(
        authorized: Bool,
        incomplete: ReminderSnapshotSegment,
        completed: ReminderSnapshotSegment
    ) -> ExternalSnapshotFetch {
        let scope = classifyScope(
            authorized: authorized,
            incompleteSucceeded: incomplete.succeeded,
            completedSucceeded: completed.succeeded
        )
        if scope.isComplete {
            return ExternalSnapshotFetch(scope: .complete, items: incomplete.items + completed.items)
        }
        var partial: [ExternalReminderSnapshot] = []
        if incomplete.succeeded { partial.append(contentsOf: incomplete.items) }
        if completed.succeeded { partial.append(contentsOf: completed.items) }
        return ExternalSnapshotFetch(scope: scope, items: partial)
    }
}

/// 外部提醒 notes 字段的解析。
///
/// ReminderService 会把「DayCue 任务 ID」和一条 daycue:// 深链写进 notes，
/// 这两行是程序自己的记账信息，不属于用户备注，参与字段比较前必须剥掉，
/// 否则每次对账都会因为这两行的存在/缺失而误报「备注被改过」。
public enum ExternalReminderNoteField {

    /// 按稳定标识找回本地任务 ID。解析不出来返回 nil —— 绝不按标题猜。
    public static func taskId(fromNotes notes: String?) -> String? {
        ExternalIdentifier.taskId(fromNotes: notes)
    }

    /// 剥离程序记账行后剩下的用户备注；全空返回 nil，避免 "" 与 nil 被当成两个值。
    public static func userDetail(fromNotes notes: String?) -> String? {
        guard let notes else { return nil }
        let kept = notes.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(ExternalIdentifier.notePrefix) { return false }
            if trimmed.hasPrefix("daycue://") { return false }
            return true
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
