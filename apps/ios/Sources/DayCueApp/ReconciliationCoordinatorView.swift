import SwiftUI
import DayCueCore

/// 对账容器视图。
///
/// 无参构造：依赖从 AppContainer（EnvironmentObject）里取，
/// 这样 SettingsView 只需要写 ReconciliationCoordinatorView()，
/// 不必知道 store 与 ReminderService 是从哪里来的。
///
/// 它只做三件事：
/// 1. 把 coordinator 的 plan / lastReconciledAt 交给既有的 SyncStatusView 展示；
/// 2. 有冲突时给出进入 ReconciliationView 逐字段裁决的入口；
/// 3. 有待确认的删除时给出明确的「需要你确认」入口，绝不自动执行。
struct ReconciliationCoordinatorView: View {

    @EnvironmentObject private var container: AppContainer
    @StateObject private var coordinator = ReconciliationCoordinator()
    @State private var showingConfirmations = false

    var body: some View {
        SyncStatusView(lastReconciledAt: coordinator.lastReconciledAt, plan: coordinator.plan)
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("提醒事项对账")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await coordinator.beginReconciliation() }
                    } label: {
                        if coordinator.isRunning {
                            ProgressView()
                        } else {
                            Text("重新对账")
                        }
                    }
                    .disabled(coordinator.isRunning || !coordinator.isAttached)
                }
            }
            .task {
                // 每次进入页面都重放一次接入；attach 是幂等的，不会重建依赖。
                coordinator.attach(store: container.store, reminders: container.reminders)
                // 只有还没对过账才自动跑一轮，避免每次回到这个页面都去打 EventKit。
                if coordinator.lastReconciledAt == nil {
                    await coordinator.beginReconciliation()
                }
            }
            .sheet(isPresented: $showingConfirmations) {
                ReconciliationConfirmationSheet(coordinator: coordinator)
            }
    }

    // MARK: - 底部操作条

    /// 之所以用 safeAreaInset 而不是再包一层 List：
    /// SyncStatusView 自己就是 List，套一层会出现嵌套列表的滚动问题。
    @ViewBuilder
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.isRunning {
                ProgressView("正在对账…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = coordinator.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = coordinator.notes.last {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.pendingConfirmationCount > 0 {
                Button {
                    showingConfirmations = true
                } label: {
                    Label(
                        "有 \(coordinator.pendingConfirmationCount) 项需要你确认",
                        systemImage: "hand.raised.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if let plan = coordinator.plan, !plan.conflicts.isEmpty {
                NavigationLink {
                    ReconciliationView(
                        plan: plan,
                        taskTitle: { entityId in
                            (try? container.store.task(id: entityId))?.title ?? entityId
                        },
                        submit: { resolution in
                            await coordinator.apply(resolution)
                        }
                    )
                } label: {
                    Label(
                        "处理 \(plan.conflictedEntityCount) 条任务 / \(plan.conflictedFieldCount) 个字段的冲突",
                        systemImage: "arrow.left.arrow.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if coordinator.plan == nil && !coordinator.isRunning {
                Text("还没有对账结果。点右上角「重新对账」开始。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// 待确认决策清单。
///
/// 这里只处理「删除」这类不可逆动作；字段冲突走 ReconciliationView 的逐字段裁决。
private struct ReconciliationConfirmationSheet: View {

    @ObservedObject var coordinator: ReconciliationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if coordinator.pendingConfirmations.isEmpty {
                    Section {
                        Text("没有需要确认的项目。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("这些结论需要你确认后才会执行。DayCue 不会自动删除任何一侧的数据。")
                            .font(.footnote)
                    }

                    ForEach(coordinator.pendingConfirmations, id: \.entityId) { decision in
                        Section {
                            Button("确认处理这一条") {
                                Task {
                                    message = await coordinator.resolvePendingConfirmation(decision, confirmed: true)
                                }
                            }
                            Button("先不动，保持原样") {
                                Task {
                                    message = await coordinator.resolvePendingConfirmation(decision, confirmed: false)
                                }
                            }
                        } header: {
                            Text(decision.summary)
                        } footer: {
                            Text(decision.entityId)
                                .font(.caption2)
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("需要你确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
