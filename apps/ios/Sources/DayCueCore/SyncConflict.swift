import Foundation

// 云同步冲突的展示与裁决。
//
// 复用既有对账的**类型**，不另造冲突模型：
//   - ReconciliationPlan / ReconciliationDecision / ReconciliationFieldDifference
//   - ReconciliationResolution / ReconciliationValueSource / ReconciliationField
// 因此界面可以直接用 ReconciliationView(plan:taskTitle:submit:) 渲染，
// 裁决结果也走同一套 ReconciliationResolution。
//
// 一个取舍：ReconciliationField 是为「任务 vs 苹果提醒事项」设计的六个字段，
// 用到笔记/记录/课程/记忆上时只能把各自字段映射到语义最接近的一组。映射写在
// SyncConflictFields.groups 里，是唯一一处需要随实体类型维护的对应关系。
// 没有归属的字段统一放进 .list 这一组（它在这些实体上充当「其他」桶），
// 绝不因为「找不到对应的字段名」就把差异悄悄丢掉。

/// 一组一起裁决的字段。
public struct SyncConflictFieldGroup: Equatable, Sendable {
    public let field: ReconciliationField
    /// 参与这一组的载荷键名。整组一起比较、一起裁决。
    public let keys: [String]

    public init(field: ReconciliationField, keys: [String]) {
        self.field = field
        self.keys = keys
    }
}

/// 每种实体的字段分组。
public enum SyncConflictFields {

    public static func groups(for type: SyncEntityType) -> [SyncConflictFieldGroup] {
        switch type {
        case .task:
            return [
                SyncConflictFieldGroup(field: .title, keys: ["title"]),
                SyncConflictFieldGroup(field: .detail, keys: ["detail"]),
                SyncConflictFieldGroup(field: .status, keys: ["status"]),
                SyncConflictFieldGroup(field: .due, keys: ["dueKind", "dueLocal", "dueUTC", "timezone"]),
                SyncConflictFieldGroup(field: .remind, keys: ["remindLocal", "remindUTC"]),
                SyncConflictFieldGroup(field: .list, keys: ["courseHint", "originCaptureId", "originItemId"])
            ]
        case .note:
            return [
                SyncConflictFieldGroup(field: .title, keys: ["title"]),
                SyncConflictFieldGroup(field: .detail, keys: ["body"]),
                SyncConflictFieldGroup(field: .status, keys: ["userEdited"]),
                SyncConflictFieldGroup(field: .due, keys: ["occurredAt"]),
                SyncConflictFieldGroup(field: .remind, keys: ["originKind"]),
                SyncConflictFieldGroup(field: .list, keys: ["tags", "courseHint", "originCaptureId", "originItemId"])
            ]
        case .capture:
            return [
                SyncConflictFieldGroup(field: .title, keys: ["kind"]),
                SyncConflictFieldGroup(field: .detail, keys: ["rawText", "transcript", "ocrText"]),
                SyncConflictFieldGroup(field: .status, keys: ["status", "userEdited"]),
                SyncConflictFieldGroup(field: .due, keys: ["recordedAt", "recordedTimezone"]),
                SyncConflictFieldGroup(field: .remind, keys: ["mediaPath"]),
                SyncConflictFieldGroup(field: .list, keys: [])
            ]
        case .course:
            return [
                SyncConflictFieldGroup(field: .title, keys: ["name"]),
                SyncConflictFieldGroup(field: .detail, keys: ["teacher", "location"]),
                SyncConflictFieldGroup(field: .status, keys: ["followUpEnabled", "followUpDelayMinutes"]),
                SyncConflictFieldGroup(field: .due, keys: []),
                SyncConflictFieldGroup(field: .remind, keys: []),
                SyncConflictFieldGroup(field: .list, keys: ["term", "color"])
            ]
        case .memory:
            return [
                SyncConflictFieldGroup(field: .title, keys: ["statement"]),
                SyncConflictFieldGroup(field: .detail, keys: ["sourceRef"]),
                SyncConflictFieldGroup(field: .status, keys: ["status"]),
                SyncConflictFieldGroup(field: .due, keys: ["effectiveTo"]),
                SyncConflictFieldGroup(field: .remind, keys: []),
                SyncConflictFieldGroup(field: .list, keys: ["category", "kind", "sourceKind", "confidence", "revision", "effectiveFrom"])
            ]
        }
    }

    /// 把一条冲突里「涉及到的字段」按分组顺序列出来（去重、保持稳定顺序）。
    public static func conflictedFields(for type: SyncEntityType, local: [String: SyncJSONValue], server: [String: SyncJSONValue]) -> [ReconciliationField] {
        groups(for: type).compactMap { group in
            let localValue = SyncPayloadCodec.groupValue(local, keys: group.keys)
            let serverValue = SyncPayloadCodec.groupValue(server, keys: group.keys)
            return localValue == serverValue ? nil : group.field
        }
    }
}

/// 把待裁决冲突组装成既有的 ReconciliationPlan。
public enum SyncConflictPresenter {

    /// - Parameter generatedAt: 由调用方显式传入时间基准，Core 不读系统时钟。
    public static func plan(conflicts: [SyncConflictRecord], generatedAt: String) -> ReconciliationPlan {
        let decisions = conflicts.map { conflict in
            ReconciliationDecision.markConflict(
                entityId: conflict.entityId,
                differences: differences(for: conflict)
            )
        }
        // 服务端已经完整回应过（游标/结算都有明确结果），所以范围是完整的。
        return ReconciliationPlan(
            decisions: decisions,
            scope: .complete,
            anomalies: [],
            generatedAt: generatedAt
        )
    }

    /// 一条冲突的逐字段差异。全部标记为冲突：云同步没有可用的三方基线，
    /// 「谁改的」无从归因，只能交给用户。
    public static func differences(for conflict: SyncConflictRecord) -> [ReconciliationFieldDifference] {
        let local = dictionary(conflict.localPayloadJSON)
        let server = dictionary(conflict.serverPayloadJSON)
        let groups = SyncConflictFields.groups(for: conflict.entityType)
        let fields = conflict.conflictingFields.isEmpty
            ? groups.map(\.field)
            : conflict.conflictingFields

        var result: [ReconciliationFieldDifference] = []
        for field in fields {
            guard let group = groups.first(where: { $0.field == field }) else { continue }
            result.append(ReconciliationFieldDifference(
                field: field,
                previousValue: nil,
                localValue: SyncPayloadCodec.groupValue(local, keys: group.keys),
                externalValue: SyncPayloadCodec.groupValue(server, keys: group.keys),
                isConflict: true,
                preferredSource: nil
            ))
        }
        if result.isEmpty {
            // 没有任何可比较字段（例如服务端墓碑、本地也没有内容）：
            // 仍然要产生一行让用户确认，不能默默当成「没有冲突」。
            result.append(ReconciliationFieldDifference(
                field: .detail,
                previousValue: nil,
                localValue: nil,
                externalValue: conflict.serverDeleted ? "（服务端已删除）" : nil,
                isConflict: true,
                preferredSource: nil
            ))
        }
        return result
    }

    static func dictionary(_ json: String?) -> [String: SyncJSONValue] {
        guard let json, let value = try? DayCueJSON.decode(SyncJSONValue.self, from: json) else { return [:] }
        if case let .object(dict) = value { return dict }
        return [:]
    }
}

/// 一条裁决记录之后的结果。
public enum CloudConflictResolutionOutcome: Equatable, Sendable {
    case unknownConflict
    case stillWaiting(remainingFields: Int)
    case appliedKeptLocal
    case appliedAcceptedServer
    case appliedDeletedLocal
}

/// 把用户的逐字段裁决落到本地，并把结果重新排进待推送队列。
///
/// 累积语义：用户每裁决一个字段，就把该组键覆写进冲突记录的工作副本
/// （localPayloadJSON）。只有所有冲突字段都裁决过才落库，
/// 否则「逐字段提交」会每提交一次就丢掉上一个选择。
public struct CloudConflictResolver {

    private let store: DayCueStore

    public init(store: DayCueStore) {
        self.store = store
    }

    public func resolveAll(_ resolutions: [ReconciliationResolution], at: Date) throws -> [CloudConflictResolutionOutcome] {
        var outcomes: [CloudConflictResolutionOutcome] = []
        for resolution in resolutions {
            outcomes.append(try record(resolution, at: at))
        }
        return outcomes
    }

    @discardableResult
    public func record(_ resolution: ReconciliationResolution, at: Date) throws -> CloudConflictResolutionOutcome {
        let conflicts = try store.syncConflicts()
        // 实体 ID 是 UUID 字符串，跨类型也不会重复。
        guard let conflict = conflicts.first(where: { $0.entityId == resolution.entityId }) else {
            return .unknownConflict
        }
        let groups = SyncConflictFields.groups(for: conflict.entityType)
        guard conflict.conflictingFields.contains(resolution.field),
              let group = groups.first(where: { $0.field == resolution.field }) else {
            return .unknownConflict
        }

        var local = SyncConflictPresenter.dictionary(conflict.localPayloadJSON)
        let server = SyncConflictPresenter.dictionary(conflict.serverPayloadJSON)
        if resolution.source == .external {
            local = SyncPayloadCodec.merging(local, with: server, keys: group.keys)
        }

        var updated = conflict
        updated.localPayloadJSON = try DayCueJSON.encodeToString(local)
        if !updated.resolvedFields.contains(resolution.field) {
            updated.resolvedFields.append(resolution.field)
        }
        updated.choseLocal = conflict.choseLocal || (resolution.source == .local)

        guard updated.isFullyResolved else {
            try store.upsertSyncConflict(updated)
            let remaining = Set(updated.conflictingFields).subtracting(updated.resolvedFields).count
            return .stillWaiting(remainingFields: remaining)
        }

        // 服务端已是墓碑，且用户在所有字段上都选了服务端 = 同意删除本地。
        if updated.serverDeleted, !updated.choseLocal {
            try store.applyCloudDeletion(entityType: updated.entityType, entityId: updated.entityId, at: at)
            try store.markSyncChangeSynced(
                entityType: updated.entityType,
                entityId: updated.entityId,
                serverVersion: updated.serverVersion,
                contentHash: SyncPayloadCodec.changeHash(operation: .delete, payloadJSON: nil),
                at: at
            )
            try store.deleteSyncConflict(entityType: updated.entityType, entityId: updated.entityId)
            return .appliedDeletedLocal
        }

        let payload: SyncEntityPayload
        do {
            payload = try SyncPayloadCodec.payload(from: local)
        } catch {
            // 工作副本解不出结构时绝不落库：宁可让用户再选一次。
            return .unknownConflict
        }

        try store.applyCloudPayload(
            entityType: updated.entityType,
            entityId: updated.entityId,
            payload: payload,
            updatedAt: DayCueClock.nowUTCString(date: at)
        )
        try store.deleteSyncConflict(entityType: updated.entityType, entityId: updated.entityId)
        // 先离开 conflict 状态，enqueue 才愿意改写这一行。
        try store.requeueSyncChange(entityType: updated.entityType, entityId: updated.entityId, at: at)
        try store.enqueueSyncChange(
            entityType: updated.entityType,
            entityId: updated.entityId,
            operation: .upsert,
            payloadJSON: try SyncPayloadCodec.json(payload),
            baseVersion: updated.serverVersion,
            at: at
        )
        return updated.choseLocal ? .appliedKeptLocal : .appliedAcceptedServer
    }
}
