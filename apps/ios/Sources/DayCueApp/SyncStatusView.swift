import SwiftUI
import DayCueCore

/// 同步状态页。
///
/// 只回答三个问题：上次什么时候对账的、这次结果可不可信、还有多少条要处理。
/// 查询失败时必须把「对账不完整，未做任何删除」直接写在脸上，
/// 否则用户会以为 App 已经清理过外部已删除的条目。
struct SyncStatusView: View {

    /// 上次对账时间（UTC RFC3339 原文）。为 nil 表示还没对账过。
    let lastReconciledAt: String?
    /// 最近一轮对账结果。为 nil 表示本次启动还没有跑过对账。
    let plan: ReconciliationPlan?

    var body: some View {
        List {
            Section {
                statusRow("上次对账时间", lastReconciledAt ?? "还没有对账过")
            } footer: {
                Text("对账只读比对本地、苹果提醒事项与上次同步快照，不会因为一次查询失败就删除任何数据。")
                    .font(.caption)
            }

            if let plan {
                Section("本轮结果") {
                    statusRow("查询范围", plan.isComplete ? "完整" : "不完整")
                    statusRow("待处理冲突", "\(plan.conflictedEntityCount) 条任务 / \(plan.conflictedFieldCount) 个字段")
                    statusRow("查询结论", plan.scope.diagnosticName)
                }

                if !plan.isComplete {
                    Section {
                        Label("对账不完整，未做任何删除", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text(plan.scope.userFacingMessage)
                            .font(.caption)
                    }
                }

                if !plan.anomalies.isEmpty {
                    Section {
                        ForEach(plan.anomalies.indices, id: \.self) { index in
                            Text(plan.anomalies[index].displayText)
                                .font(.footnote)
                        }
                    } header: {
                        Text("异常")
                    } footer: {
                        Text("同一任务在外部出现多条时会列在这里，需要你到苹果提醒事项里删掉多余的那条。")
                            .font(.caption)
                    }
                }

                if plan.hasDeletionPropagation {
                    Section("需要你确认的删除") {
                        Text("本轮发现 \(plan.deletionDecisionCount) 条任务的某一侧已经不存在。是否同步删除另一侧由你决定，DayCue 不会自动删。")
                            .font(.footnote)
                        Text("外部条目的删除永远需要你确认：DayCue 分不清「你真的在苹果侧删了」和「你改了备注、把任务标识那行弄没了」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("还没有可展示的对账结果。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("同步状态")
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
