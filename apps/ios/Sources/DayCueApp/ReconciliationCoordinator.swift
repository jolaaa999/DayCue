import Foundation
import Combine
import EventKit
import DayCueCore

// 对账编排层：把 EventKit 的真实快照喂给引擎，再把引擎的决策落到本地与存储。
//
// 这个文件只做「编排」，不重新实现任何判定：
// - 范围可不可信交给 ExternalReminderSnapshotAdapter + ReminderSnapshotQuery；
// - 谁改了什么交给 ReconciliationEngine；
// - 基线与游标的读写交给 DayCueStore+Sync（复用既有方法，不新拼 SQL）。
//
// 唯一的铁律：删除类的决策永远不自动执行。
// canApplyAutomatically 为 false 的决策一律进 pendingConfirmations 等用户点头，
// 因为「外部条目消失」分不清是真删除还是用户改备注把标识行弄没了。

/// 写回外部提醒的结果。
///
/// 不用 Bool：notFound 与 failed 的处置完全不同 ——
/// 前者说明外部对象已经没了（要重新走删除确认），后者通常可以下一轮重试。
enum ExternalReminderApplyOutcome: Equatable {
    case applied
    case notFound
    case notAuthorized
    case failed(String)

    var isSuccess: Bool { self == .applied }

    /// 给人看的失败说明；成功时为 nil。
    var message: String? {
        switch self {
        case .applied:
            return nil
        case .notFound:
            return "苹果提醒事项里已经找不到这条条目（可能已被删除），本轮没有改动它。"
        case .notAuthorized:
            return "没有提醒事项权限，无法写回苹果提醒事项。"
        case let .failed(detail):
            return "写回苹果提醒事项失败：\(detail)"
        }
    }
}

/// 把一条已存在的外部提醒更新成给定状态。
///
/// 抽成协议是为了让编排器不直接持有 EventKit 细节，将来换写入通道只改这一处实现。
@MainActor
protocol ExternalReminderFieldWriting {
    func apply(
        _ state: ReminderComparableState,
        task: TaskRecord,
        externalId: String
    ) async -> ExternalReminderApplyOutcome
}

@MainActor
final class ReconciliationCoordinator: ObservableObject {

    /// 游标 scope。写成常量，避免各处拼字符串导致读不到同一行。
    static let cursorScope = "apple_reminders.reconciliation"

    /// 最近一轮对账结果。为 nil 表示本次启动还没跑过。
    @Published private(set) var plan: ReconciliationPlan?
    /// 上次对账时间（UTC RFC3339 原文），用 DayCueClock.nowUTCString()。
    @Published private(set) var lastReconciledAt: String?
    /// 必须用户确认后才能执行的决策。绝不自动应用。
    @Published private(set) var pendingConfirmations: [ReconciliationDecision] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    /// 编排过程里的人话提示（写回失败、清单不可写等）。只用于展示，不落库。
    @Published private(set) var notes: [String] = []

    private var store: DayCueStore?
    private var reminders: ReminderService?
    private var snapshots: ExternalReminderSnapshotSource?
    private var writer: ExternalReminderFieldWriting?

    init() {}

    // MARK: - 接入依赖

    /// 由视图在出现时调用。
    ///
    /// 重复调用是幂等的：SwiftUI 的 .task 可能在每次进入页面时重跑，
    /// 重建依赖会丢掉正在进行的对账状态，也会让界面看到的结果闪一下。
    func attach(store: DayCueStore, reminders: ReminderService) {
        if self.store === store { return }
        self.store = store
        self.reminders = reminders
        // 读与写共用同一个 EKEventStore 实例：两个实例各自缓存会让「刚写进去的读不到」。
        let eventStore = EKEventStore()
        self.snapshots = ExternalReminderSnapshotAdapter(eventStore: eventStore)
        self.writer = EventKitReminderFieldWriter(eventStore: eventStore)
    }

    var isAttached: Bool { store != nil }

    var pendingConfirmationCount: Int { pendingConfirmations.count }

    var hasConflicts: Bool { !(plan?.conflicts.isEmpty ?? true) }

    // MARK: - 一轮对账

    /// 跑一轮完整对账：读本地 -> 读基线 -> 读外部 -> 比较 -> 落库 -> 分流应用。
    ///
    /// 注意顺序：先把 plan 与 lastReconciledAt 发布出去，再自动应用。
    /// 这样即使自动应用中途失败，用户也已经能看到「对账结果」与失败原因，
    /// 而不是页面停在空白。
    func beginReconciliation() async {
        guard !isRunning else { return }
        guard let store = self.store, let snapshots = self.snapshots else {
            lastError = "对账还没有接入本地库，请稍后重试。"
            return
        }

        isRunning = true
        lastError = nil
        notes = []
        defer { isRunning = false }

        do {
            // 1. 本地侧：任务 + 绑定。必须带软删除项，
            //    否则「本地已删除」会被当成「从来没有过」，外部那条永远没机会处理。
            let local = try loadLocalSnapshots(store)
            // 2. 上次基线：缺失表示「从来没有同步过」，引擎会因此更保守（当冲突处理）。
            let previous = try store.reconciliationBaselines()
            // 3. 外部侧：一次真实快照，自带「这次查询可不可信」。
            let fetch = await snapshots.fetchSnapshot()
            // 4. 纯函数比较。
            let plan = ReconciliationEngine.reconcile(local: local, external: fetch, previous: previous)

            self.plan = plan
            self.lastReconciledAt = DayCueClock.nowUTCString()
            self.pendingConfirmations = plan.decisionsRequiringUserConfirmation

            // 游标先落：即使后面自动应用失败，用户也能看到「对到哪一刻」。
            try store.setSyncCursor(scope: Self.cursorScope, cursor: plan.generatedAt)

            await applyAutomatically(
                plan: plan,
                fetch: fetch,
                store: store,
                local: local,
                previous: previous
            )
        } catch {
            lastError = "对账失败：\(error)"
        }
    }

    // MARK: - 本地读取

    /// 读出「本地任务 + 外部绑定」的快照集合。
    ///
    /// 逐条查绑定而不是一次查全表：DayCueStore+Sync / +Task 没有暴露批量绑定查询，
    /// 而铁律要求只新建文件、不改既有仓储，所以这里用自己的循环补上。
    private func loadLocalSnapshots(_ store: DayCueStore) throws -> [LocalReminderSnapshot] {
        let tasks = try store.tasks(status: nil, includeDeleted: true, limit: 1000)
        return try tasks.map { task in
            let binding = try store.externalBinding(taskId: task.id)
            return LocalReminderSnapshot(task: task, binding: binding)
        }
    }

    // MARK: - 自动应用（严格按 canApplyAutomatically 分流）

    /// 把可以自动应用的决策落库，其余一律不碰。
    ///
    /// 分流的唯一依据是引擎给出的 decision.canApplyAutomatically：
    /// true 只有 adoptExternal / pushLocal 两种「收敛」动作；
    /// false（冲突、本地删、外部删）全部留给用户。
    private func applyAutomatically(
        plan: ReconciliationPlan,
        fetch: ExternalSnapshotFetch,
        store: DayCueStore,
        local: [LocalReminderSnapshot],
        previous: [ReconciliationBaseline]
    ) async {
        let localById = Dictionary(local.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
        let externalById = externalIndex(fetch.items)
        let baselinedIds = Set(previous.map(\.entityId))

        for decision in plan.decisions {
            if decision.canApplyAutomatically {
                switch decision {
                case let .adoptExternal(entityId, _):
                    guard let external = externalById[entityId] else { continue }
                    adoptExternal(
                        entityId: entityId,
                        external: external,
                        store: store,
                        local: localById[entityId]
                    )
                case let .pushLocal(entityId, differences):
                    await pushLocal(
                        entityId: entityId,
                        differences: differences,
                        store: store,
                        local: localById[entityId]
                    )
                default:
                    // canApplyAutomatically 只会是这两种；这里只是穷尽分支的兜底。
                    continue
                }
                continue
            }

            // 需要用户确认的（尤其是删除）绝不在这里执行。
            if decision.requiresUserConfirmation { continue }

            // 剩下的只有 noop。补种基线是安全的，也是必要的：
            // 没有基线时引擎无法归因「谁改的」，会把单边修改误判成冲突。
            seedBaselineIfNeeded(
                entityId: decision.entityId,
                store: store,
                local: localById[decision.entityId],
                external: externalById[decision.entityId],
                hasBaseline: baselinedIds.contains(decision.entityId),
                scopeIsComplete: plan.isComplete
            )
        }
    }

    /// 有多个外部条目指向同一个任务时，只取第一条用于自动应用。
    /// 重复条目的完整信息由引擎放进 anomalies 交给用户看，这里不擅自选边。
    private func externalIndex(_ items: [ExternalReminderSnapshot]) -> [String: ExternalReminderSnapshot] {
        var index: [String: ExternalReminderSnapshot] = [:]
        for item in items {
            guard let taskId = item.taskId, !taskId.isEmpty else { continue }
            if index[taskId] == nil { index[taskId] = item }
        }
        return index
    }

    /// 补种基线。
    ///
    /// 只在「范围完整 + 本地有这条 + 外部也真实存在」时补。
    /// 绝不能给「外部没有」的纯本地任务补基线：那等于凭空造一个外部绑定，
    /// 下一轮就会看到「外部条目消失」，然后建议用户删除自己的数据。
    private func seedBaselineIfNeeded(
        entityId: String,
        store: DayCueStore,
        local: LocalReminderSnapshot?,
        external: ExternalReminderSnapshot?,
        hasBaseline: Bool,
        scopeIsComplete: Bool
    ) {
        guard scopeIsComplete, !hasBaseline, let local, !local.isDeleted, external != nil else { return }
        try? store.writeReconciliationBaseline(local.comparableState, entityId: entityId)
    }

    // MARK: - adoptExternal

    /// 以外部为准：把外部取值搬进本地（本地没有这条时就是导入）。
    private func adoptExternal(
        entityId: String,
        external: ExternalReminderSnapshot,
        store: DayCueStore,
        local: LocalReminderSnapshot?
    ) {
        let state = ReminderComparableState(external: external)
        let existingBinding = try? store.externalBinding(taskId: entityId)

        if (try? store.task(id: entityId)) != nil {
            guard var updated = try? store.task(id: entityId) else { return }
            applyState(state, to: &updated)
            do {
                try store.updateTask(updated)
            } catch {
                notes.append("采用苹果侧改动时保存本地失败：\(error)")
                return
            }
        } else {
            // 外部新增：本地还没有这条任务，按外部取值导入。
            let imported = makeTask(from: external)
            guard (try? store.insertTask(imported)) != nil else {
                notes.append("导入苹果提醒事项里的新条目失败。")
                return
            }
        }

        persistBinding(entityId: entityId, external: external, store: store, existing: existingBinding)
        // 与外部收敛之后才推进基线：这条基线代表「双方一致的状态」。
        try? store.writeReconciliationBaseline(state, entityId: entityId)
    }

    /// 外部对象引用与清单归属属于绑定信息，不属于 task 表，所以单独写。
    private func persistBinding(
        entityId: String,
        external: ExternalReminderSnapshot,
        store: DayCueStore,
        existing: ExternalBindingRecord?
    ) {
        let binding = ExternalBindingRecord(
            taskId: entityId,
            provider: ReconciliationEngine.defaultProvider,
            listId: external.listId,
            listTitle: external.listTitle,
            externalId: external.externalId,
            externalLastModified: external.lastModified,
            // snapshotJSON 是写入链留下的原始快照，对账不重写它，
            // 免得把写入侧「我写过什么」的证据覆盖掉。
            snapshotJSON: existing?.snapshotJSON,
            createdAt: existing?.createdAt ?? DayCueClock.nowUTCString()
        )
        try? store.upsertExternalBinding(binding)
    }

    // MARK: - pushLocal

    /// 以本地为准：把本地字段写回外部对象。只更新已存在的条目，不创建、不删除。
    private func pushLocal(
        entityId: String,
        differences: [ReconciliationFieldDifference],
        store: DayCueStore,
        local: LocalReminderSnapshot?
    ) async {
        guard let writer = self.writer else { return }
        guard let task = try? store.task(id: entityId), !task.isDeleted else { return }
        let binding = try? store.externalBinding(taskId: entityId)

        guard let externalId = local?.externalId ?? binding?.externalId, !externalId.isEmpty else {
            // 没有任何外部标识就没有可写回的对象，如实记一条提示，而不是假装成功。
            notes.append("任务「\(task.title)」的改动没有可写回的外部条目。")
            return
        }

        let target = ReminderComparableState(task: task, listId: binding?.listId)
        let outcome = await writer.apply(target, task: task, externalId: externalId)
        if outcome.isSuccess {
            let fields = differences.map(\.field.displayName).joined(separator: "、")
            notes.append("已把「\(task.title)」的\(fields)更新到苹果提醒事项。")
            // 只有外部写成功才推进基线。失败时保留旧基线，下一轮还会看到这条差异，
            // 不会因为一次失败就假装已经同步、把用户的修改静默丢掉。
            try? store.writeReconciliationBaseline(target, entityId: entityId)
        } else if let message = outcome.message {
            notes.append(message)
        }
    }

    // MARK: - 用户裁决

    /// 提交一批字段级裁决，返回给用户看的提示。
    func applyResolutions(_ resolutions: [ReconciliationResolution]) async -> [String] {
        guard let store = self.store,
              let writer = self.writer,
              let plan = self.plan else {
            return ["对账还没有可用的结果，请先开始一次对账。"]
        }

        // 用户裁决只说「用哪一边」，具体取值必须来自引擎产出的差异 ——
        // 界面层不重算一份，否则「用户点的」和「库里写的」会悄悄分叉。
        var differencesByField: [String: ReconciliationFieldDifference] = [:]
        for decision in plan.conflicts {
            for difference in decision.differences where difference.isConflict {
                differencesByField[Self.differenceKey(entityId: decision.entityId, field: difference.field)] = difference
            }
        }

        var grouped: [String: [ReconciliationResolution]] = [:]
        var order: [String] = []
        for resolution in resolutions {
            if grouped[resolution.entityId] == nil { order.append(resolution.entityId) }
            grouped[resolution.entityId, default: []].append(resolution)
        }

        var messages: [String] = []
        for entityId in order {
            let message = await applyResolutions(
                entityId: entityId,
                resolutions: grouped[entityId] ?? [],
                differencesByField: differencesByField,
                store: store,
                writer: writer
            )
            messages.append(message)
        }
        return messages
    }

    /// 供 ReconciliationView.submit 直接使用：一次提交一条字段裁决。
    func apply(_ resolution: ReconciliationResolution) async -> String? {
        let messages = await applyResolutions([resolution])
        return messages.first
    }

    /// 同一个任务的同一个字段是唯一键，与 ReconciliationView 的行 id 同构。
    private static func differenceKey(entityId: String, field: ReconciliationField) -> String {
        entityId + "|" + field.rawValue
    }

    private func applyResolutions(
        entityId: String,
        resolutions: [ReconciliationResolution],
        differencesByField: [String: ReconciliationFieldDifference],
        store: DayCueStore,
        writer: ExternalReminderFieldWriting
    ) async -> String {
        guard let task = try? store.task(id: entityId) else {
            return "找不到任务 \(entityId)，本轮没有改动。"
        }
        let binding = try? store.externalBinding(taskId: entityId)

        var state = ReminderComparableState(task: task, listId: binding?.listId)
        var needsExternalWrite = false
        for resolution in resolutions {
            guard let difference = differencesByField[Self.differenceKey(entityId: entityId, field: resolution.field)] else {
                continue
            }
            // 复用引擎的字段搬运规则，界面预览与写库因此不会出现两套逻辑。
            state = state.applying(difference, from: resolution.source)
            if resolution.source == .local {
                // 选「用本地」意味着外部要跟着改；选「用外部」只改本地就够了，
                // 因为外部本来就是那个值，再写一次只会白白刷新它的修改时间。
                needsExternalWrite = true
            }
        }

        var updated = task
        applyState(state, to: &updated)
        do {
            try store.updateTask(updated)
        } catch {
            return "保存本地改动失败：\(error)"
        }

        // 清单归属记在 external_binding 上，只有它真的变了才需要单独写一次。
        if let listId = state.listId, listId != binding?.listId {
            let existing = binding ?? ExternalBindingRecord(
                taskId: entityId,
                provider: ReconciliationEngine.defaultProvider,
                createdAt: DayCueClock.nowUTCString()
            )
            let moved = ExternalBindingRecord(
                taskId: entityId,
                provider: existing.provider,
                listId: listId,
                listTitle: existing.listTitle,
                externalId: existing.externalId,
                externalLastModified: existing.externalLastModified,
                snapshotJSON: existing.snapshotJSON,
                createdAt: existing.createdAt
            )
            try? store.upsertExternalBinding(moved)
        }

        if needsExternalWrite {
            guard let externalId = binding?.externalId, !externalId.isEmpty else {
                return "已保存本地改动，但这条任务没有外部绑定，无法写回苹果提醒事项。"
            }
            let outcome = await writer.apply(state, task: updated, externalId: externalId)
            guard outcome.isSuccess else {
                return outcome.message ?? "写回苹果提醒事项失败，本地改动已经保存。"
            }
        }

        // 双方都收敛到 state 之后再记基线，这条任务下次就不会再被判成需要处理。
        try? store.writeReconciliationBaseline(state, entityId: entityId)
        // 已裁决的实体从待确认列表移除，避免用户处理完还看到旧条目。
        pendingConfirmations.removeAll { $0.entityId == entityId }
        return "已按你的选择更新「\(state.title)」。"
    }

    // MARK: - 待确认的删除

    /// 处理一条待用户确认的删除决策。
    ///
    /// - confirmed == true：真的执行（清绑定 / 删外部条目）。
    /// - confirmed == false：一个字都不改。下次对账还会提示 ——
    ///   在没有新证据之前，我们确实分不清「真删除」和「备注被改坏」。
    func resolvePendingConfirmation(
        _ decision: ReconciliationDecision,
        confirmed: Bool
    ) async -> String? {
        guard let store = self.store else { return "对账还没有接入本地库。" }
        let entityId = decision.entityId
        guard pendingConfirmations.contains(where: { $0.entityId == entityId }) else {
            return "这一条已经处理过了。"
        }
        defer { pendingConfirmations.removeAll { $0.entityId == entityId } }

        switch decision {
        case .markExternalDeleted:
            guard confirmed else {
                return "已保留现状，没有改动任何数据。下次对账仍会提示这一条。"
            }
            // 确认外部确实没了：清掉基线与绑定，但**保留本地任务本身**。
            // 我们分不清「用户真删了」和「用户改备注弄丢了标识行」，
            // 所以任何情况下都不允许因为这条决策删除本地数据。
            try? store.deleteSyncSnapshot(
                entityType: ReconciliationEngine.defaultEntityType,
                entityId: entityId,
                provider: ReconciliationEngine.defaultProvider
            )
            try? store.deleteExternalBinding(taskId: entityId)
            return "已解除这条任务的对外绑定。本地任务保留，不会被删除。"

        case let .markLocalDeleted(_, externalId):
            guard confirmed else {
                return "已保留苹果提醒事项里的条目，没有改动任何数据。下次对账仍会提示这一条。"
            }
            guard let externalId, !externalId.isEmpty else {
                // 没有外部标识就没法删外部对象，只能清理本地记账。
                try? store.deleteExternalBinding(taskId: entityId)
                return "外部标识缺失，已只清理本地绑定。"
            }
            guard let reminders = self.reminders else {
                return "对账还没有接入提醒事项服务。"
            }
            do {
                try reminders.deleteReminder(withIdentifier: externalId)
            } catch {
                return "删除苹果提醒事项失败：\(error.localizedDescription)"
            }
            try? store.deleteExternalBinding(taskId: entityId)
            try? store.deleteSyncSnapshot(
                entityType: ReconciliationEngine.defaultEntityType,
                entityId: entityId,
                provider: ReconciliationEngine.defaultProvider
            )
            // 留一条墓碑：即使以后重放这段逻辑，也不会对同一个外部对象再删一次。
            try? store.upsertSyncTombstone(SyncTombstoneRecord(
                entityType: ReconciliationEngine.defaultEntityType,
                entityId: entityId,
                deletedAt: DayCueClock.nowUTCString()
            ))
            return "已删除苹果提醒事项里的对应条目。"

        default:
            // 冲突走 ReconciliationView 的逐字段裁决，不在这里处理。
            return "这一条需要到冲突页逐字段处理。"
        }
    }

    // MARK: - 状态搬运

    /// 把可比状态写进任务条目。只碰 App 真正映射到外部的字段，其余原样保留。
    private func applyState(_ state: ReminderComparableState, to task: inout TaskRecord) {
        let timeZone = TimeZone(identifier: task.timezone) ?? .current
        task.title = state.title
        task.detail = state.detail
        task.status = state.status
        task.dueKind = state.dueKind
        task.dueLocal = state.dueLocal
        switch state.dueKind {
        case .none:
            task.dueLocal = nil
            task.dueUTC = nil
        case .date:
            // 日期型截止日只有墙上日期，绝不能补一个假的 UTC 午夜。
            task.dueUTC = nil
        case .datetime:
            task.dueUTC = state.dueLocal
                .flatMap { RFC3339.date(fromLocal: $0, timeZone: timeZone) }
                .map { RFC3339.utcString(from: $0) }
        }
        task.remindLocal = state.remindLocal
        task.remindUTC = state.remindLocal
            .flatMap { RFC3339.date(fromLocal: $0, timeZone: timeZone) }
            .map { RFC3339.utcString(from: $0) }
    }

    /// 从外部条目导入一条新任务。
    private func makeTask(from external: ExternalReminderSnapshot) -> TaskRecord {
        let timeZone = TimeZone.current
        var task = TaskRecord(
            title: external.title,
            detail: external.detail,
            status: external.isCompleted ? .done : .open,
            dueKind: external.dueKind,
            timezone: timeZone.identifier,
            remindLocal: external.remindLocal,
            // 这条本来就从外部导入，不存在「写入」这一步；直接落成 written，
            // 否则提醒归属会以为外部还没接管，又给同一件事排一条本地通知（双重提醒）。
            externalWriteState: .written
        )
        task.dueLocal = external.dueLocal
        switch external.dueKind {
        case .none:
            task.dueUTC = nil
        case .date:
            task.dueUTC = nil
        case .datetime:
            task.dueUTC = external.dueLocal
                .flatMap { RFC3339.date(fromLocal: $0, timeZone: timeZone) }
                .map { RFC3339.utcString(from: $0) }
        }
        task.remindUTC = external.remindLocal
            .flatMap { RFC3339.date(fromLocal: $0, timeZone: timeZone) }
            .map { RFC3339.utcString(from: $0) }
        return task
    }
}

// MARK: - EventKit 字段写回

/// 把一条已存在的外部提醒更新成给定状态。
///
/// 为什么需要它：ReminderService 只有「创建 / 删除 / 查重」，
/// 没有任何「更新已有条目字段」的入口，而对账的 pushLocal 正是这个动作。
/// 这里严格限定三件事：
/// 1. 只更新「按稳定标识找得到」的已有条目，绝不创建、绝不按标题匹配；
/// 2. 只改 App 真正映射过去的字段（清单、标题、备注、完成状态、截止时间、绝对时间提醒）；
/// 3. 不在这里执行删除 —— 删除必须由用户确认，并走编排器的 resolvePendingConfirmation。
@MainActor
final class EventKitReminderFieldWriter: ExternalReminderFieldWriting {

    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func apply(
        _ state: ReminderComparableState,
        task: TaskRecord,
        externalId: String
    ) async -> ExternalReminderApplyOutcome {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .notAuthorized
        }
        // 按稳定标识取，不用谓词全表扫：这是「绝不误伤别的条目」的第一道保证。
        guard let reminder = eventStore.calendarItem(withIdentifier: externalId) as? EKReminder else {
            return .notFound
        }
        // 标识行丢了就停止写回：那多半意味着用户改过备注，
        // 继续写会把「这到底是谁的条目」彻底搞乱。
        guard ExternalIdentifier.taskId(fromNotes: reminder.notes) != nil else {
            return .failed("外部条目的 DayCue 任务标识已经丢失，已停止写回以免误伤你改过的备注。")
        }

        // 清单是唯一可能失败的前置动作，先校验它，
        // 避免改了别的字段才发现清单不可写，留下半改不改的状态。
        if let listId = state.listId, listId != reminder.calendar?.calendarIdentifier {
            guard let calendar = eventStore.calendar(withIdentifier: listId) else {
                return .failed("找不到目标清单（\(listId)），外部条目没有改动。")
            }
            guard calendar.allowsContentModifications else {
                return .failed("清单「\(calendar.title)」不可写入，外部条目没有改动。")
            }
            reminder.calendar = calendar
        }

        let timeZone = TimeZone(identifier: task.timezone) ?? .current
        reminder.title = state.title
        reminder.notes = notes(from: reminder, detail: state.detail)
        // 苹果侧只有完成 / 未完成两种状态；App 的 cancelled 没有对应值，按未完成处理。
        reminder.isCompleted = state.status == .done
        reminder.dueDateComponents = dueComponents(for: state, timeZone: timeZone)
        applyAlarm(to: reminder, state: state, timeZone: timeZone)

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .applied
    }

    // MARK: - 字段映射

    /// 重建 notes：用户备注换成新值，DayCue 的记账行原样保留。
    /// 记账行（任务 ID 与深链）丢了，这条外部条目就再也认不回是哪个任务了。
    private func notes(from reminder: EKReminder, detail: String?) -> String {
        let preserved = (reminder.notes ?? "")
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix(ExternalIdentifier.notePrefix) || trimmed.hasPrefix("daycue://")
            }
        var lines: [String] = []
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            lines.append(detail)
        }
        lines.append(contentsOf: preserved)
        return lines.joined(separator: "\n")
    }

    /// 与 ReminderService.dueComponents 保持同一套换算：日期型只给年月日，
    /// 精确时间型给到分钟，这样写出去再读回来是同一个墙面时间。
    private func dueComponents(for state: ReminderComparableState, timeZone: TimeZone) -> DateComponents? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch state.dueKind {
        case .none:
            return nil
        case .date:
            guard let local = state.dueLocal,
                  let date = RFC3339.date(fromLocal: local, timeZone: timeZone) else {
                return nil
            }
            return calendar.dateComponents([.year, .month, .day], from: date)
        case .datetime:
            guard let local = state.dueLocal,
                  let date = RFC3339.date(fromLocal: local, timeZone: timeZone) else {
                return nil
            }
            return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
    }

    private func applyAlarm(to reminder: EKReminder, state: ReminderComparableState, timeZone: TimeZone) {
        // 只替换绝对时间的提醒。相对偏移的提醒（用户在苹果侧自己加的「提前 1 天」）
        // 不是 App 写的，删掉等于抹掉用户的设置，所以原样保留。
        if let alarms = reminder.alarms {
            for alarm in alarms where alarm.absoluteDate != nil {
                reminder.removeAlarm(alarm)
            }
        }
        guard let local = state.remindLocal,
              let date = RFC3339.date(fromLocal: local, timeZone: timeZone) else {
            return
        }
        reminder.addAlarm(EKAlarm(absoluteDate: date))
    }
}
