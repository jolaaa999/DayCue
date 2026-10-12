import SwiftUI
import DayCueCore

/// 冲突页里的一条字段级裁决行。
struct ReconciliationConflictRow: Identifiable, Equatable {
    let taskId: String
    let taskTitle: String
    let difference: ReconciliationFieldDifference

    var id: String { taskId + "|" + difference.field.rawValue }
}

/// 同一任务下的一组冲突行。
struct ReconciliationConflictGroup: Identifiable, Equatable {
    let taskId: String
    let taskTitle: String
    let rows: [ReconciliationConflictRow]

    var id: String { taskId }
}

/// 对账冲突裁决页。
///
/// 刻意不提供「全部用本地 / 全部用外部」这类一键按钮：
/// 同一个任务的不同字段可能各自该保留不同的一方，一键全选等于放弃逐字段判断，
/// 而「同一字段双方都改过」正是最需要人来看的那种情况。
/// 单方修改不会出现在这里——引擎已经按「改的一方为准」处理掉了。
struct ReconciliationView: View {

    let plan: ReconciliationPlan
    /// 任务标题查询：决策里只有实体 ID，标题要由调用方提供。
    let taskTitle: (String) -> String
    /// 提交一条裁决。返回给用户看的提示文案；写库与外部动作由调用方负责。
    let submit: (ReconciliationResolution) async -> String?

    @State private var selections: [String: ReconciliationValueSource] = [:]
    @State private var message: String?
    @State private var isSubmitting = false

    init(
        plan: ReconciliationPlan,
        taskTitle: @escaping (String) -> String = { $0 },
        submit: @escaping (ReconciliationResolution) async -> String? = { _ in nil }
    ) {
        self.plan = plan
        self.taskTitle = taskTitle
        self.submit = submit
    }

    var body: some View {
        List {
            if conflictRows.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: "没有需要处理的冲突",
                        message: "没有同一字段被两边同时修改的情况。单方修改会以改过的一方为准，不需要你裁决。"
                    )
                }
            } else {
                Section {
                    Text("这些字段在本地和苹果提醒事项里都被改过。请逐项选择保留哪一边；DayCue 不会替你决定。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            conflictRow(row)
                        }
                    } header: {
                        Text(group.taskTitle)
                    }
                }

                Section {
                    Button {
                        Task { await submitSelections() }
                    } label: {
                        Text(submitButtonTitle)
                    }
                    .disabled(unresolvedCount > 0 || isSubmitting)
                } footer: {
                    Text("每一项都要单独选择，所以这里没有「全部用某一边」的一键按钮。")
                        .font(.caption)
                }
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("对账")
    }

    // MARK: - 子视图

    @ViewBuilder
    private func conflictRow(_ row: ReconciliationConflictRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.difference.field.displayName)
                .font(.subheadline.weight(.semibold))

            valueLine(label: "本地", value: row.difference.localValue)
            valueLine(label: "苹果", value: row.difference.externalValue)

            HStack(spacing: 8) {
                ForEach(ReconciliationValueSource.allCases, id: \.rawValue) { source in
                    Button(source.displayName) {
                        selections[row.id] = source
                    }
                    .buttonStyle(.bordered)
                    .tint(selections[row.id] == source ? Color.accentColor : Color.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func valueLine(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value ?? "（空）")
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    // MARK: - 数据整理

    private var groups: [ReconciliationConflictGroup] {
        var order: [String] = []
        var buckets: [String: [ReconciliationConflictRow]] = [:]
        for decision in plan.conflicts {
            guard case let .markConflict(entityId, differences) = decision else { continue }
            for difference in differences where difference.isConflict {
                let row = ReconciliationConflictRow(
                    taskId: entityId,
                    taskTitle: taskTitle(entityId),
                    difference: difference
                )
                if buckets[entityId] == nil { order.append(entityId) }
                buckets[entityId, default: []].append(row)
            }
        }
        return order.map { entityId in
            ReconciliationConflictGroup(
                taskId: entityId,
                taskTitle: taskTitle(entityId),
                rows: buckets[entityId] ?? []
            )
        }
    }

    private var conflictRows: [ReconciliationConflictRow] {
        groups.flatMap(\.rows)
    }

    /// 还有多少条冲突没有选择。为 0 才允许提交。
    private var unresolvedCount: Int {
        conflictRows.filter { selections[$0.id] == nil }.count
    }

    private var submitButtonTitle: String {
        if isSubmitting { return "提交中…" }
        if unresolvedCount > 0 { return "还有 \(unresolvedCount) 项未选择" }
        return "提交裁决"
    }

    private func submitSelections() async {
        isSubmitting = true
        var messages: [String] = []
        for row in conflictRows {
            guard let source = selections[row.id] else { continue }
            let resolution = ReconciliationResolution(
                entityId: row.taskId,
                field: row.difference.field,
                source: source
            )
            if let note = await submit(resolution) {
                messages.append(note)
            }
        }
        isSubmitting = false
        message = messages.isEmpty ? "已提交你的选择。" : messages.joined(separator: "\n")
    }
}
