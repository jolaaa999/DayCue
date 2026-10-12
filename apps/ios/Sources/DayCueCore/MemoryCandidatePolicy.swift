import Foundation

// 候选与冲突策略。纯逻辑，不碰数据库、不读时钟。
//
// 产品底线：
// - 推断出来的记忆**一律先落 candidate**，永远不能自己变成 confirmed；
//   只有用户在界面上点了「确认」才允许改状态。
// - 用户设置（user_setting）与用户说过（user_statement）属于用户断言，可以直接 confirmed。
// - 同一类别里出现互斥说法时落 conflict 交用户处理，**绝不自动覆盖**旧说法。

/// 待入库的一条记忆说法。
public struct MemoryDraft: Equatable, Sendable {

    public var category: MemoryCategory
    public var statement: String
    public var sourceKind: MemorySourceKind
    public var confidence: Double?
    public var sourceRef: String?
    public var effectiveFrom: String?
    public var effectiveTo: String?

    public init(
        category: MemoryCategory,
        statement: String,
        sourceKind: MemorySourceKind,
        confidence: Double? = nil,
        sourceRef: String? = nil,
        effectiveFrom: String? = nil,
        effectiveTo: String? = nil
    ) {
        self.category = category
        self.statement = statement
        self.sourceKind = sourceKind
        self.confidence = confidence
        self.sourceRef = sourceRef
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
    }
}

/// 入库结论。status 是唯一允许写进 memory_item.status 的值。
public struct MemoryAdmission: Equatable, Sendable {

    public var status: MemoryStatus
    /// 与这条说法互斥的既有记忆 id。界面据此提示「和某条已确认记忆冲突」。
    public var conflictingMemoryIds: [String]
    /// 同类别里已经存在完全相同说法的记忆。重复入库时提示用户而不是造两条。
    public var duplicateOfMemoryId: String?
    /// 给人看的中文说明，界面可以直接展示。
    public var reason: String

    /// 需要用户确认才允许当事实使用。
    public var requiresUserConfirmation: Bool {
        status != .confirmed
    }

    public init(
        status: MemoryStatus,
        conflictingMemoryIds: [String] = [],
        duplicateOfMemoryId: String? = nil,
        reason: String
    ) {
        self.status = status
        self.conflictingMemoryIds = conflictingMemoryIds
        self.duplicateOfMemoryId = duplicateOfMemoryId
        self.reason = reason
    }
}

/// 单值类别。
///
/// 阶段状态与地点在现实里只可能有一个当前值：你不会同时处于两个阶段，
/// 也不会同时住在两个地方。对这两类来说，同类别里出现第二种说法本身就是需要用户裁决的冲突。
/// 其余类别（偏好、目标、经历、人物）允许多条并存，只在检测到明确互斥时才报冲突。
public extension MemoryCategory {
    var isSingleValued: Bool {
        switch self {
        case .phase, .place:
            return true
        case .preference, .goal, .experience, .person:
            return false
        }
    }
}

public enum MemoryConflictDetector {

    /// 否定标记。是否出现否定是这里唯一使用的语义信号，规则简单且可解释。
    /// 刻意不把「不」之外的词做得更聪明：宁可漏报冲突让用户自己发现，
    /// 也不要误报一堆「喜欢咖啡 vs 喜欢跑步」的假冲突。
    public static let negationMarkers: [String] = ["不", "没", "未", "无", "别", "非"]

    /// 主题重叠阈值。低于它就算两句话毫无关系，即使一句带否定也不算互斥。
    public static let subjectOverlapThreshold: Double = 0.34

    /// 归一化：小写、去掉空白与标点，只留下有意义的字。
    /// 去标点之后「喜欢咖啡。」与「喜欢 咖啡」才会被认成同一句。
    public static func normalizedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        var result = ""
        for scalar in trimmed.unicodeScalars where !separators.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    public static func sameStatement(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedText(lhs)
        let b = normalizedText(rhs)
        return !a.isEmpty && a == b
    }

    /// 两句话是不是在说同一个主题。
    ///
    /// 用 MemoryTokenizer 的词集合算 Jaccard 相似度：共用词越少，越可能只是碰巧都带「喜欢」。
    public static func sharesSubject(_ lhs: String, _ rhs: String) -> Bool {
        let a = Set(MemoryTokenizer.tokens(in: normalizedText(lhs)))
        let b = Set(MemoryTokenizer.tokens(in: normalizedText(rhs)))
        guard !a.isEmpty, !b.isEmpty else { return false }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return false }
        return Double(intersection) / Double(union) >= subjectOverlapThreshold
    }

    public static func hasNegation(_ text: String) -> Bool {
        let normalized = normalizedText(text)
        return negationMarkers.contains { normalized.contains($0) }
    }

    /// 互斥判定：说同一个主题，但一正一反。
    public static func isMutuallyExclusive(_ lhs: String, _ rhs: String) -> Bool {
        guard !sameStatement(lhs, rhs) else { return false }
        guard hasNegation(lhs) != hasNegation(rhs) else { return false }
        return sharesSubject(lhs, rhs)
    }

    /// 找出与 draft 互斥的既有记忆。
    ///
    /// 只考虑同一类别、未删除、且没有退役的记忆；retired 是用户主动作废的旧说法，
    /// 拿它报冲突只会让用户反复处理同一件事。
    public static func conflicts(
        of draft: MemoryDraft,
        among existing: [MemoryItem],
        ignoringMemoryId: String? = nil
    ) -> [MemoryItem] {
        existing.filter { item in
            guard item.deletedAt == nil else { return false }
            guard item.status != .retired else { return false }
            guard item.category == draft.category else { return false }
            if let ignoringMemoryId, item.id == ignoringMemoryId { return false }
            if sameStatement(draft.statement, item.statement) { return false }
            if draft.category.isSingleValued { return true }
            return isMutuallyExclusive(draft.statement, item.statement)
        }
    }

    /// 找出同类别里说法完全相同的既有记忆。
    public static func duplicate(
        of draft: MemoryDraft,
        among existing: [MemoryItem],
        ignoringMemoryId: String? = nil
    ) -> MemoryItem? {
        existing.first { item in
            guard item.deletedAt == nil else { return false }
            guard item.category == draft.category else { return false }
            if let ignoringMemoryId, item.id == ignoringMemoryId { return false }
            return sameStatement(draft.statement, item.statement)
        }
    }
}

public enum MemoryCandidatePolicy {

    /// 决定一条新说法应该以什么状态入库。
    ///
    /// 判断顺序及其理由：
    /// 1. 空说法直接挡回去，落成 candidate 等用户补充，不允许写一条空事实。
    /// 2. inferred 一律 candidate，**即使与既有说法互斥也不升级**——
    ///    推断不是事实，冲突只通过 conflictingMemoryIds 暴露给界面。
    /// 3. 其余（用户设置 / 用户说过）若与既有说法互斥则落 conflict，绝不覆盖旧说法。
    /// 4. 都不是才允许 confirmed。
    public static func admit(
        _ draft: MemoryDraft,
        among existing: [MemoryItem] = [],
        ignoringMemoryId: String? = nil
    ) -> MemoryAdmission {
        let trimmed = draft.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MemoryAdmission(
                status: .candidate,
                reason: "这条记忆还没有具体内容，先作为候选保存，等你补充完整。"
            )
        }

        let conflicts = MemoryConflictDetector.conflicts(
            of: draft,
            among: existing,
            ignoringMemoryId: ignoringMemoryId
        )
        let duplicate = MemoryConflictDetector.duplicate(
            of: draft,
            among: existing,
            ignoringMemoryId: ignoringMemoryId
        )
        let conflictIds = conflicts.map(\.id)

        if draft.sourceKind == .inferred {
            var reason = "这是从你的记录里推断出来的，先作为候选保存在这里，只有你确认之后才算事实。"
            if !conflictIds.isEmpty {
                reason += " 注意：它和已有的 \(conflictIds.count) 条记忆说法不一致，需要你来决定以哪条为准。"
            }
            if duplicate != nil {
                reason += " 同类里已经有一样的说法。"
            }
            return MemoryAdmission(
                status: .candidate,
                conflictingMemoryIds: conflictIds,
                duplicateOfMemoryId: duplicate?.id,
                reason: reason
            )
        }

        if !conflictIds.isEmpty {
            return MemoryAdmission(
                status: .conflict,
                conflictingMemoryIds: conflictIds,
                duplicateOfMemoryId: duplicate?.id,
                reason: "这条说法和你已经确认过的 \(conflictIds.count) 条记忆互相矛盾，DayCue 不会替你决定，请手动选择保留哪条。"
            )
        }

        var reason = "这是你自己给出的内容，已直接记为事实。"
        if duplicate != nil {
            reason += " 同类里已经有一模一样的说法。"
        }
        return MemoryAdmission(
            status: .confirmed,
            conflictingMemoryIds: [],
            duplicateOfMemoryId: duplicate?.id,
            reason: reason
        )
    }

    /// 按入库结论拼出一条待写入的 MemoryItem。
    ///
    /// 把「策略 -> 记录」的转换放在这里，是为了让界面与批处理走同一条路径，
    /// 不会出现某个入口忘了用 policy 的 status、把推断直接写成了 confirmed。
    public static func makeItem(
        _ draft: MemoryDraft,
        admission: MemoryAdmission,
        id: String = DayCueID.new(),
        createdAt: String,
        updatedAt: String? = nil
    ) -> MemoryItem {
        MemoryItem(
            id: id,
            category: draft.category,
            statement: draft.statement.trimmingCharacters(in: .whitespacesAndNewlines),
            status: admission.status,
            sourceKind: draft.sourceKind,
            confidence: draft.confidence,
            sourceRef: draft.sourceRef,
            revision: 1,
            effectiveFrom: draft.effectiveFrom,
            effectiveTo: draft.effectiveTo,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt,
            deletedAt: nil
        )
    }
}
