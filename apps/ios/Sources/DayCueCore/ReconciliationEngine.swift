import Foundation

// 苹果提醒事项对账的三方比较。
//
// 设计约束（按重要性排序）：
// 1. 引擎是纯函数，只输出「决策」，不碰数据库、不碰 EventKit。这样它才能在
//    macOS 上被 swift test 直接跑（DayCueCore 不允许依赖 iOS 专有框架）。
// 2. 同一字段双方都改过时，绝不自动选一个：必须产出 markConflict 交给用户。
// 3. 查询不完整时，绝不因为「快照里没有」就产出任何删除决策；
//    已绑定的记录在范围不完整时一律 noop —— 残缺数据不许覆盖本地。
// 4. 外部条目消失一律按「需要用户确认的删除」产出，不自动应用：
//    我们分不清「用户真的删了」和「用户改备注把标识行弄没了」。
// 5. 三方一致时全部 noop，连续跑两次结果一样（幂等）。

// MARK: - 字段

/// 参与对账的可比字段。
///
/// 只列「App 真正映射到外部」的字段。苹果侧的其他字段（优先级、子任务、标签）
/// 不参与比较，因为 App 从来没有写过它们，也就无从谈「谁改的」。
public enum ReconciliationField: String, Codable, CaseIterable, Sendable {
    case title
    case detail
    case status
    case due
    case remind
    case list

    public var displayName: String {
        switch self {
        case .title: return "标题"
        case .detail: return "备注"
        case .status: return "完成状态"
        case .due: return "截止时间"
        case .remind: return "提醒时刻"
        case .list: return "所属清单"
        }
    }
}

/// 冲突裁决时的取值来源。
public enum ReconciliationValueSource: String, Codable, CaseIterable, Sendable {
    case local
    case external

    public var displayName: String {
        switch self {
        case .local: return "用本地"
        case .external: return "用外部"
        }
    }
}

// MARK: - 可比状态

/// 本地 / 外部 / 上次快照统一用的「可比状态」。
///
/// 三方比较只有在同一套表示上才有意义，所以本地任务与外部提醒都要先投影成它。
/// 它同时是 sync_snapshot.payload_json 的编解码类型，这样基线与被比较的对象永远不会漂移。
public struct ReminderComparableState: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var status: TaskStatus
    public var dueKind: DueKind
    public var dueLocal: String?
    public var remindLocal: String?
    public var listId: String?

    public init(
        title: String,
        detail: String? = nil,
        status: TaskStatus = .open,
        dueKind: DueKind = .none,
        dueLocal: String? = nil,
        remindLocal: String? = nil,
        listId: String? = nil
    ) {
        self.title = title
        self.detail = Self.normalized(detail)
        self.status = status
        self.dueKind = dueKind
        self.dueLocal = dueLocal
        self.remindLocal = remindLocal
        self.listId = listId
    }

    /// 本地任务的投影。listId 不来自 task 表，而是来自 external_binding —— 清单归属是绑定信息。
    public init(task: TaskRecord, listId: String?) {
        self.init(
            title: task.title,
            detail: task.detail,
            status: task.status,
            dueKind: task.dueKind,
            dueLocal: task.dueLocal,
            remindLocal: task.remindLocal,
            listId: listId
        )
    }

    /// 外部提醒的投影。
    public init(external: ExternalReminderSnapshot) {
        self.init(
            title: external.title,
            detail: external.detail,
            // 苹果侧只有「完成 / 未完成」，没有 cancelled；未完成一律映射成 open。
            status: external.isCompleted ? .done : .open,
            dueKind: external.dueKind,
            dueLocal: external.dueLocal,
            remindLocal: external.remindLocal,
            listId: external.listId
        )
    }

    /// 空字符串与 nil 是同一个意思，必须归一，否则每次对账都会误报「备注被改过」。
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 字段的规范字符串。nil 表示「这个字段没有值」，与空串区分开。
    public func value(for field: ReconciliationField) -> String? {
        switch field {
        case .title: return title
        case .detail: return detail
        case .status: return status.rawValue
        case .due:
            // 日期型与精确型必须可区分：due_kind 变了但日期字符串没变，仍然是一次真实修改。
            guard dueKind != .none else { return nil }
            return dueKind.rawValue + "|" + (dueLocal ?? "")
        case .remind: return remindLocal
        case .list: return listId
        }
    }

    /// 把一个字段替换成指定来源的值，返回新状态（不改自身）。
    ///
    /// 抽出来的原因：界面预览与仓储写库必须共用同一套字段搬运规则，
    /// 否则「用户点了用外部」和「库里实际写入的值」会悄悄分叉。
    public func applying(
        _ difference: ReconciliationFieldDifference,
        from source: ReconciliationValueSource
    ) -> ReminderComparableState {
        let raw = source == .local ? difference.localValue : difference.externalValue
        var copy = self
        switch difference.field {
        case .title:
            copy.title = raw ?? ""
        case .detail:
            copy.detail = Self.normalized(raw)
        case .status:
            copy.status = raw.flatMap(TaskStatus.init(rawValue:)) ?? copy.status
        case .due:
            guard let raw, let separator = raw.firstIndex(of: "|") else {
                copy.dueKind = .none
                copy.dueLocal = nil
                return copy
            }
            let kind = String(raw[raw.startIndex..<separator])
            let local = String(raw[raw.index(after: separator)...])
            copy.dueKind = DueKind(rawValue: kind) ?? .none
            copy.dueLocal = copy.dueKind == .none || local.isEmpty ? nil : local
        case .remind:
            copy.remindLocal = Self.normalized(raw)
        case .list:
            copy.listId = Self.normalized(raw)
        }
        return copy
    }
}

// MARK: - 快照

/// 外部（苹果提醒事项）一条项目的快照。
///
/// taskId 为 nil 表示这条提醒的 notes 里没有 DayCue 任务 ID。这有两种可能，
/// 且后果完全不同，所以引擎不做假设：
/// - 用户自己在苹果里建的提醒（与对账无关，忽略）；
/// - 用户改了备注、把标识行弄没了（这正是 markExternalDeleted 必须让用户确认的原因）。
public struct ExternalReminderSnapshot: Equatable, Sendable {
    public var taskId: String?
    public var externalId: String
    public var listId: String?
    public var listTitle: String?
    public var title: String
    /// 已经剥离 DayCue 标识行后的用户备注。
    public var detail: String?
    public var isCompleted: Bool
    public var dueKind: DueKind
    public var dueLocal: String?
    public var remindLocal: String?
    public var lastModified: String?

    public init(
        taskId: String?,
        externalId: String,
        listId: String? = nil,
        listTitle: String? = nil,
        title: String,
        detail: String? = nil,
        isCompleted: Bool = false,
        dueKind: DueKind = .none,
        dueLocal: String? = nil,
        remindLocal: String? = nil,
        lastModified: String? = nil
    ) {
        self.taskId = taskId
        self.externalId = externalId
        self.listId = listId
        self.listTitle = listTitle
        self.title = title
        self.detail = detail
        self.isCompleted = isCompleted
        self.dueKind = dueKind
        self.dueLocal = dueLocal
        self.remindLocal = remindLocal
        self.lastModified = lastModified
    }
}

/// 本地一条任务的快照。
///
/// isDeleted 必须带出来：软删除的任务如果直接不出现在快照里，
/// 「本地已删」就会被误判成「从来没有过」，外部那条永远删不掉。
public struct LocalReminderSnapshot: Equatable, Sendable {
    public var taskId: String
    public var title: String
    public var detail: String?
    public var status: TaskStatus
    public var dueKind: DueKind
    public var dueLocal: String?
    public var remindLocal: String?
    public var listId: String?
    public var externalId: String?
    public var isDeleted: Bool

    public init(
        taskId: String,
        title: String,
        detail: String? = nil,
        status: TaskStatus = .open,
        dueKind: DueKind = .none,
        dueLocal: String? = nil,
        remindLocal: String? = nil,
        listId: String? = nil,
        externalId: String? = nil,
        isDeleted: Bool = false
    ) {
        self.taskId = taskId
        self.title = title
        self.detail = detail
        self.status = status
        self.dueKind = dueKind
        self.dueLocal = dueLocal
        self.remindLocal = remindLocal
        self.listId = listId
        self.externalId = externalId
        self.isDeleted = isDeleted
    }

    public init(task: TaskRecord, binding: ExternalBindingRecord?) {
        self.init(
            taskId: task.id,
            title: task.title,
            detail: task.detail,
            status: task.status,
            dueKind: task.dueKind,
            dueLocal: task.dueLocal,
            remindLocal: task.remindLocal,
            listId: binding?.listId,
            externalId: binding?.externalId,
            isDeleted: task.deletedAt != nil
        )
    }

    public var comparableState: ReminderComparableState {
        ReminderComparableState(
            title: title,
            detail: detail,
            status: status,
            dueKind: dueKind,
            dueLocal: dueLocal,
            remindLocal: remindLocal,
            listId: listId
        )
    }
}

/// 上一次同步的基线，对应 sync_snapshot 表的一行。
public struct ReconciliationBaseline: Equatable, Sendable {
    public let entityId: String
    public let provider: String
    public let state: ReminderComparableState
    public let capturedAt: String

    public init(
        entityId: String,
        provider: String = ReconciliationEngine.defaultProvider,
        state: ReminderComparableState,
        capturedAt: String = ""
    ) {
        self.entityId = entityId
        self.provider = provider
        self.state = state
        self.capturedAt = capturedAt
    }
}

// MARK: - 逐字段差异

/// 一个字段的三方取值与「该怎么处理」。
public struct ReconciliationFieldDifference: Equatable, Sendable {
    public let field: ReconciliationField
    public let previousValue: String?
    public let localValue: String?
    public let externalValue: String?
    /// true 表示双方都改过（或没有基线无法归因），必须由用户裁决。
    public let isConflict: Bool
    /// 单边修改时以哪一方为准；冲突或无法归因时为 nil。
    public let preferredSource: ReconciliationValueSource?

    public init(
        field: ReconciliationField,
        previousValue: String?,
        localValue: String?,
        externalValue: String?,
        isConflict: Bool,
        preferredSource: ReconciliationValueSource?
    ) {
        self.field = field
        self.previousValue = previousValue
        self.localValue = localValue
        self.externalValue = externalValue
        self.isConflict = isConflict
        self.preferredSource = preferredSource
    }

    /// 用户裁决单边修改时会用到的目标值；冲突时为 nil。
    public var preferredValue: String? {
        guard let preferredSource else { return nil }
        return preferredSource == .local ? localValue : externalValue
    }
}

/// 一条用户裁决。
public struct ReconciliationResolution: Equatable, Sendable {
    public let entityId: String
    public let field: ReconciliationField
    public let source: ReconciliationValueSource

    public init(entityId: String, field: ReconciliationField, source: ReconciliationValueSource) {
        self.entityId = entityId
        self.field = field
        self.source = source
    }
}

// MARK: - 决策

public enum ReconciliationDecision: Equatable, Sendable {
    /// 以外部为准（外部被改、本地没动）。
    case adoptExternal(entityId: String, differences: [ReconciliationFieldDifference])
    /// 以本地为准（本地被改、外部没动）。执行方只更新已存在的外部对象，不新建。
    case pushLocal(entityId: String, differences: [ReconciliationFieldDifference])
    /// 同一字段双方都改过：交给用户逐项裁决，引擎不选边。
    case markConflict(entityId: String, differences: [ReconciliationFieldDifference])
    /// 本地已删除，需要决定是否同步删除外部对象。
    case markLocalDeleted(entityId: String, externalId: String?)
    /// 外部条目在完整范围查询里消失。
    ///
    /// requiresUserConfirmation 恒为 true：我们无法区分「用户真的在苹果侧删了」
    /// 和「用户改了备注、把 DayCue 任务 ID 那行弄没了」。前者应当清掉本地绑定，
    /// 后者必须保住用户的数据。既然分不清，就绝不允许自动应用。
    case markExternalDeleted(entityId: String, externalId: String?, requiresUserConfirmation: Bool)
    case noop(entityId: String)

    public var entityId: String {
        switch self {
        case let .adoptExternal(entityId, _): return entityId
        case let .pushLocal(entityId, _): return entityId
        case let .markConflict(entityId, _): return entityId
        case let .markLocalDeleted(entityId, _): return entityId
        case let .markExternalDeleted(entityId, _, _): return entityId
        case let .noop(entityId): return entityId
        }
    }

    /// 决策涉及的差异。删除类决策没有字段级差异。
    public var differences: [ReconciliationFieldDifference] {
        switch self {
        case let .adoptExternal(_, differences): return differences
        case let .pushLocal(_, differences): return differences
        case let .markConflict(_, differences): return differences
        case .markLocalDeleted, .markExternalDeleted, .noop: return []
        }
    }

    public var conflictedDifferences: [ReconciliationFieldDifference] {
        differences.filter(\.isConflict)
    }

    public var isNoop: Bool {
        if case .noop = self { return true }
        return false
    }

    /// 会删除一侧数据的决策。查询不完整时绝不允许出现。
    public var isDeletionPropagation: Bool {
        switch self {
        case .markLocalDeleted, .markExternalDeleted: return true
        case .adoptExternal, .pushLocal, .markConflict, .noop: return false
        }
    }

    /// 决策是否要求外部写入（更新或删除）。界面据此提示「会改动苹果提醒事项」。
    public var requiresExternalWrite: Bool {
        switch self {
        case .pushLocal, .markLocalDeleted: return true
        case .adoptExternal, .markConflict, .markExternalDeleted, .noop: return false
        }
    }

    /// 是否必须等用户确认后才能执行。true 表示绝不允许自动应用。
    public var requiresUserConfirmation: Bool {
        switch self {
        case let .markExternalDeleted(_, _, requiresUserConfirmation):
            return requiresUserConfirmation
        case .markConflict:
            // 冲突本身就是等用户逐字段裁决，天然需要用户。
            return true
        case .markLocalDeleted:
            // 删除外部对象不可逆，同样不自动执行。
            return true
        case .adoptExternal, .pushLocal, .noop:
            return false
        }
    }

    /// 是否可以不经用户确认就执行。只有 adopt / push 这两类收敛动作算数。
    public var canApplyAutomatically: Bool {
        !isNoop && !requiresUserConfirmation
    }

    public var summary: String {
        switch self {
        case let .adoptExternal(_, differences):
            return "以苹果提醒事项为准更新：" + differences.map(\.field.displayName).joined(separator: "、")
        case let .pushLocal(_, differences):
            return "以本地为准更新外部：" + differences.map(\.field.displayName).joined(separator: "、")
        case let .markConflict(_, differences):
            let fields = differences.filter(\.isConflict).map(\.field.displayName).joined(separator: "、")
            return "需要你裁决：" + fields
        case .markLocalDeleted:
            return "本地已删除，需要确认是否删除苹果提醒事项里的对应条目。"
        case .markExternalDeleted:
            return "苹果提醒事项里的条目可能已被删除，需要你确认后处理，不会自动删除本地数据。"
        case .noop:
            return "无变化"
        }
    }
}

/// 外部条目的引用，用于在异常里给用户足够线索去人工核对。
public struct ExternalItemReference: Equatable, Sendable {
    public let externalId: String
    public let lastModified: String?

    public init(externalId: String, lastModified: String? = nil) {
        self.externalId = externalId
        self.lastModified = lastModified
    }

    public var displayText: String {
        guard let lastModified, !lastModified.isEmpty else { return externalId }
        return "\(externalId)（最后修改 \(lastModified)）"
    }
}

/// 对账过程中发现的、不属于常规字段差异的异常。
public enum ReconciliationAnomaly: Equatable, Sendable {
    /// 同一个 DayCue 任务在外部出现了多条。
    case duplicateExternalItems(taskId: String, items: [ExternalItemReference])
    /// 本地绑定的外部条目还在，但它的备注里已经找不到 DayCue 任务标识。
    /// 这是「用户改过备注」的直接证据，也是不能把外部消失当成删除的理由。
    case externalItemLostDayCueIdentifier(taskId: String, externalId: String)
    /// 本轮查询范围不完整，这条已绑定的记录没有做任何处理。
    case skippedDueToIncompleteScope(taskId: String, reason: String)

    public var taskId: String {
        switch self {
        case let .duplicateExternalItems(taskId, _): return taskId
        case let .externalItemLostDayCueIdentifier(taskId, _): return taskId
        case let .skippedDueToIncompleteScope(taskId, _): return taskId
        }
    }

    public var displayText: String {
        switch self {
        case let .duplicateExternalItems(taskId, items):
            return "任务 \(taskId) 在苹果提醒事项里有 \(items.count) 条重复条目："
                + items.map(\.displayText).joined(separator: "；")
        case let .externalItemLostDayCueIdentifier(taskId, externalId):
            return "任务 \(taskId) 绑定的外部条目（\(externalId)）备注里已经找不到 DayCue 任务标识，"
                + "可能是你改过备注。本轮不会据此删除本地数据。"
        case let .skippedDueToIncompleteScope(taskId, reason):
            return "任务 \(taskId) 本轮未做任何处理：外部查询不完整（\(reason)）。"
        }
    }
}

/// 一轮对账的完整产物。
public struct ReconciliationPlan: Equatable, Sendable {
    public let decisions: [ReconciliationDecision]
    public let scope: ReminderSnapshotScope
    public let anomalies: [ReconciliationAnomaly]
    public let generatedAt: String

    public init(
        decisions: [ReconciliationDecision],
        scope: ReminderSnapshotScope,
        anomalies: [ReconciliationAnomaly] = [],
        generatedAt: String = DayCueClock.nowUTCString()
    ) {
        self.decisions = decisions
        self.scope = scope
        self.anomalies = anomalies
        self.generatedAt = generatedAt
    }

    /// 本轮对账是否可信。false 时调用方不得执行任何删除。
    public var isComplete: Bool { scope.isComplete }

    public var conflicts: [ReconciliationDecision] {
        decisions.filter { if case .markConflict = $0 { return true }; return false }
    }

    public var conflictedEntityCount: Int { conflicts.count }

    public var conflictedFieldCount: Int {
        conflicts.reduce(0) { $0 + $1.conflictedDifferences.count }
    }

    public var deletionDecisions: [ReconciliationDecision] {
        decisions.filter(\.isDeletionPropagation)
    }

    public var hasDeletionPropagation: Bool { !deletionDecisions.isEmpty }

    public var deletionDecisionCount: Int { deletionDecisions.count }

    /// 必须用户确认后才能执行的决策。调用方不得绕过它自动应用。
    public var decisionsRequiringUserConfirmation: [ReconciliationDecision] {
        decisions.filter(\.requiresUserConfirmation)
    }

    public var requiresUserConfirmationCount: Int { decisionsRequiringUserConfirmation.count }

    /// 全部为 noop（三方一致且没有待办）。
    public var isEmpty: Bool { decisions.allSatisfy(\.isNoop) }
}

// MARK: - 引擎

public enum ReconciliationEngine {

    public static let defaultProvider = "apple_reminders"
    public static let defaultEntityType = "task"

    /// 三方比较。
    ///
    /// - Parameters:
    ///   - local: 本地任务快照（含软删除项）。
    ///   - external: 外部快照拉取结果，自带可信范围。
    ///   - previous: 上次同步基线；缺失表示「从来没有同步过」。
    public static func reconcile(
        local: [LocalReminderSnapshot],
        external: ExternalSnapshotFetch,
        previous: [ReconciliationBaseline],
        generatedAt: String = DayCueClock.nowUTCString()
    ) -> ReconciliationPlan {
        let localById = Dictionary(local.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
        let previousById = Dictionary(previous.map { ($0.entityId, $0) }, uniquingKeysWith: { first, _ in first })
        let externalIndex = indexExternal(external.items, localById: localById)

        var entityIds = Set(localById.keys)
        entityIds.formUnion(externalIndex.index.keys)
        entityIds.formUnion(previousById.keys)

        var decisions: [ReconciliationDecision] = []
        var anomalies = externalIndex.anomalies

        for entityId in entityIds.sorted() {
            let localSnapshot = localById[entityId]
            let externalSnapshot = externalIndex.index[entityId]
            let baseline = previousById[entityId]

            decisions.append(contentsOf: decide(
                entityId: entityId,
                local: localSnapshot,
                external: externalSnapshot,
                baseline: baseline,
                scope: external.scope
            ))

            // 范围不完整时，已绑定的记录本轮什么都不做。必须让用户看见「有记录被跳过了」，
            // 否则界面会显示「没有冲突」，用户会以为已经对完账了。
            if external.scope.isIncomplete,
               isBound(local: localSnapshot, external: externalSnapshot, baseline: baseline) {
                anomalies.append(.skippedDueToIncompleteScope(
                    taskId: entityId,
                    reason: external.scope.diagnosticName
                ))
            }

            // 绑定的外部对象还在，但备注里没有任务标识：这与「用户删掉了外部条目」
            // 在数据上长得一模一样，必须显式告诉用户去人工核对。
            if let externalId = localSnapshot?.externalId, !externalId.isEmpty,
               externalIndex.unidentifiedExternalIds.contains(externalId) {
                anomalies.append(.externalItemLostDayCueIdentifier(taskId: entityId, externalId: externalId))
            }
        }

        return ReconciliationPlan(
            decisions: decisions,
            scope: external.scope,
            anomalies: anomalies,
            generatedAt: generatedAt
        )
    }

    // MARK: 决策

    /// 一条记录是否已经与外部绑定。
    ///
    /// 三种证据任一成立即认为已绑定：有同步基线、本地记录了 externalId、或者本轮看到了外部条目。
    /// 这个判断决定「范围不完整时能不能动它」—— 已绑定的一律不许动。
    private static func isBound(
        local: LocalReminderSnapshot?,
        external: ExternalReminderSnapshot?,
        baseline: ReconciliationBaseline?
    ) -> Bool {
        if baseline != nil { return true }
        if let externalId = local?.externalId, !externalId.isEmpty { return true }
        return external != nil
    }

    private static func decide(
        entityId: String,
        local: LocalReminderSnapshot?,
        external: ExternalReminderSnapshot?,
        baseline: ReconciliationBaseline?,
        scope: ReminderSnapshotScope
    ) -> [ReconciliationDecision] {
        var localState: ReminderComparableState?
        if let local, !local.isDeleted { localState = local.comparableState }
        let externalState = external.map { ReminderComparableState(external: $0) }
        let previousState = baseline?.state

        let hasLocal = localState != nil
        let hasExternal = externalState != nil
        let hasBaseline = previousState != nil

        // 查询范围不完整时的收紧策略（主会话裁定）：
        // 残缺的外部集合既不能覆盖本地（禁止 adopt），也不能当作「外部没有」（禁止删除）。
        // 已绑定的记录一律 noop；只有「完全没有外部绑定」的记录才继续走正常逻辑
        // —— 首次写入不依赖外部查询范围，是安全的。
        if scope.isIncomplete, isBound(local: local, external: external, baseline: baseline) {
            return [.noop(entityId: entityId)]
        }

        switch (hasLocal, hasExternal, hasBaseline) {
        case (false, false, _):
            // 两侧都不在：可能是历史快照残留，等仓储清理即可。
            return [.noop(entityId: entityId)]

        case (true, true, true):
            return merge(
                entityId: entityId,
                local: localState!,
                external: externalState!,
                previous: previousState!
            )

        case (true, true, false):
            // 没有基线就无法归因「谁改的」，只能当冲突；内容一致则无需动作。
            //
            // 这是有意为之的取舍：没有基线时「本地单方改过」和「外部单方改过」在数据上
            // 无法区分，静默挑一边就是丢数据，代价远大于多问用户一次。
            guard let localState, let externalState else { return [.noop(entityId: entityId)] }
            if localState == externalState { return [.noop(entityId: entityId)] }
            return [.markConflict(entityId: entityId, differences: unattributedDifferences(
                local: localState,
                external: externalState
            ))]

        case (true, false, true):
            // 曾经同步过、这次外部没有。只有整轮查询可信才允许走到这里
            // （不完整时上面的守卫已经拦掉），而且即使可信也必须用户确认。
            guard scope.allowsDeletionPropagation else { return [.noop(entityId: entityId)] }
            return [.markExternalDeleted(
                entityId: entityId,
                externalId: local?.externalId,
                requiresUserConfirmation: true
            )]

        case (true, false, false):
            // 从未建立外部绑定：本地独立任务，外部没有它是正常的，不是被删除。
            return [.noop(entityId: entityId)]

        case (false, true, true):
            // 本地已删除，外部还在：是否连带删除外部交给用户。
            guard scope.allowsDeletionPropagation else { return [.noop(entityId: entityId)] }
            return [.markLocalDeleted(entityId: entityId, externalId: external?.externalId)]

        case (false, true, false):
            // 外部新增：导入成本地任务。
            // 范围不完整时一律禁止 adopt（上面的守卫已拦下）：残缺的外部集合不能凭空建本地任务。
            guard scope.allowsDeletionPropagation else { return [.noop(entityId: entityId)] }
            guard let externalState else { return [.noop(entityId: entityId)] }
            return [.adoptExternal(entityId: entityId, differences: adoptionDifferences(external: externalState))]
        }
    }

    /// 有基线时的逐字段三方比较。
    private static func merge(
        entityId: String,
        local: ReminderComparableState,
        external: ReminderComparableState,
        previous: ReminderComparableState
    ) -> [ReconciliationDecision] {
        var differences: [ReconciliationFieldDifference] = []
        var conflicts: [ReconciliationFieldDifference] = []
        var externalWins: [ReconciliationFieldDifference] = []
        var localWins: [ReconciliationFieldDifference] = []

        for field in ReconciliationField.allCases {
            let localValue = local.value(for: field)
            let externalValue = external.value(for: field)
            let previousValue = previous.value(for: field)

            // 两侧结果一致就不需要任何动作。三方一致即 noop 就落在这里。
            if localValue == externalValue { continue }

            let changedLocally = localValue != previousValue
            let changedExternally = externalValue != previousValue
            let isConflict = changedLocally && changedExternally

            // 注意：l != e 且不是冲突时，「谁变了」必然只有一种可能，
            // 所以这里的 else 分支一定能归因到本地。
            let preferred: ReconciliationValueSource?
            if isConflict {
                preferred = nil
            } else if changedExternally {
                preferred = .external
            } else {
                preferred = .local
            }

            let difference = ReconciliationFieldDifference(
                field: field,
                previousValue: previousValue,
                localValue: localValue,
                externalValue: externalValue,
                isConflict: isConflict,
                preferredSource: preferred
            )
            differences.append(difference)
            if isConflict {
                conflicts.append(difference)
            } else if preferred == .external {
                externalWins.append(difference)
            } else {
                localWins.append(difference)
            }
        }

        // 只要有一个字段是双方都改过，整条任务就交给用户：绝不擅自挑一边。
        if !conflicts.isEmpty {
            return [.markConflict(entityId: entityId, differences: differences)]
        }

        var decisions: [ReconciliationDecision] = []
        if !externalWins.isEmpty {
            decisions.append(.adoptExternal(entityId: entityId, differences: externalWins))
        }
        if !localWins.isEmpty {
            decisions.append(.pushLocal(entityId: entityId, differences: localWins))
        }
        if decisions.isEmpty {
            decisions.append(.noop(entityId: entityId))
        }
        return decisions
    }

    /// 没有基线时的差异：全部标记为冲突，因为「谁改的」无从判断。
    private static func unattributedDifferences(
        local: ReminderComparableState,
        external: ReminderComparableState
    ) -> [ReconciliationFieldDifference] {
        ReconciliationField.allCases.compactMap { field in
            let localValue = local.value(for: field)
            let externalValue = external.value(for: field)
            guard localValue != externalValue else { return nil }
            return ReconciliationFieldDifference(
                field: field,
                previousValue: nil,
                localValue: localValue,
                externalValue: externalValue,
                isConflict: true,
                preferredSource: nil
            )
        }
    }

    /// 外部新增时，把外部取值整体搬进本地。
    private static func adoptionDifferences(
        external: ReminderComparableState
    ) -> [ReconciliationFieldDifference] {
        ReconciliationField.allCases.compactMap { field in
            guard let externalValue = external.value(for: field) else { return nil }
            return ReconciliationFieldDifference(
                field: field,
                previousValue: nil,
                localValue: nil,
                externalValue: externalValue,
                isConflict: false,
                preferredSource: .external
            )
        }
    }

    /// 按稳定任务 ID 建外部索引。
    ///
    /// 同一任务出现多条时，优先选中与本地绑定一致的那条，并记录异常 ——
    /// 静悄悄挑一条会让用户永远看不到「外部有两条重复」这个事实。
    /// 同时收集「没有任务标识」的外部 ID，用来识别「备注被改掉」这种情况。
    private static func indexExternal(
        _ items: [ExternalReminderSnapshot],
        localById: [String: LocalReminderSnapshot]
    ) -> (
        index: [String: ExternalReminderSnapshot],
        anomalies: [ReconciliationAnomaly],
        unidentifiedExternalIds: Set<String>
    ) {
        var grouped: [String: [ExternalReminderSnapshot]] = [:]
        var unidentifiedExternalIds: Set<String> = []
        for item in items {
            guard let taskId = item.taskId, !taskId.isEmpty else {
                // 分不清是用户自己的提醒还是被改掉标识行的条目，先记下 ID，
                // 稍后与本地绑定比对才能区分这两种后果完全不同的情况。
                unidentifiedExternalIds.insert(item.externalId)
                continue
            }
            grouped[taskId, default: []].append(item)
        }

        var index: [String: ExternalReminderSnapshot] = [:]
        var anomalies: [ReconciliationAnomaly] = []
        for taskId in grouped.keys.sorted() {
            let group = grouped[taskId] ?? []
            if group.count == 1, let only = group.first {
                index[taskId] = only
                continue
            }
            let expectedExternalId = localById[taskId]?.externalId
            let preferred = group.first { $0.externalId == expectedExternalId }
                ?? group.max { lhs, rhs in (lhs.lastModified ?? "") < (rhs.lastModified ?? "") }
            if let preferred {
                index[taskId] = preferred
            }
            // 异常里带上每个外部 ID 与它的最后修改时间，用户才有线索去苹果侧人工核对。
            anomalies.append(.duplicateExternalItems(
                taskId: taskId,
                items: group
                    .map { ExternalItemReference(externalId: $0.externalId, lastModified: $0.lastModified) }
                    .sorted { $0.externalId < $1.externalId }
            ))
        }
        return (index, anomalies, unidentifiedExternalIds)
    }
}
