import SwiftUI
import DayCueCore

/// 今天页。
///
/// 三个分区：临期待办 / 待处理记录 / 同步异常。
/// 每个任务行显示完整日期与"四选一"的写入状态，用户可以完成、撤销、重试写入。
struct TodayView: View {

    @EnvironmentObject private var container: AppContainer
    @StateObject private var model = TodayViewModel()

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text(banner)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            todoSection
            pendingCaptureSection
            syncIssueSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("今天")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新")
            }
        }
        .task {
            model.attach(container)
            model.reload()
        }
        .onChange(of: container.reminders.storeChangedSignal) { _, _ in
            Task { await model.reconcileFromExternalChanges() }
        }
        .confirmationDialog(
            "这条提醒在苹果提醒事项里被改过",
            isPresented: Binding(
                get: { model.pendingUndo != nil },
                set: { newValue in if !newValue { model.cancelUndo() } }
            ),
            titleVisibility: .visible
        ) {
            Button("只解除绑定，保留外部提醒", role: .destructive) {
                Task { await model.confirmUndo() }
            }
            Button("取消", role: .cancel) {
                model.cancelUndo()
            }
        } message: {
            Text(model.pendingUndo?.message ?? "")
        }
    }

    // MARK: - 临期待办

    private var todoSection: some View {
        Section {
            if model.sections.allSatisfy({ $0.tasks.isEmpty }) {
                EmptyStateView(
                    systemImage: "sun.max",
                    title: "今天没有待办",
                    message: "到「记录」里说一句话、录一段音或拍张照片，确认后就会出现在这里。"
                )
            } else {
                ForEach(model.sections) { section in
                    ForEach(section.tasks) { task in
                        TaskRow(
                            task: task,
                            isBusy: model.busyTaskId == task.id,
                            canUndo: model.canUndo(task),
                            canRetry: model.canRetry(task),
                            onComplete: { Task { await model.complete(task) } },
                            onReopen: { Task { await model.reopen(task) } },
                            onUndo: { Task { await model.undo(task) } },
                            onRetry: { Task { await model.retry(task) } }
                        )
                    }
                    if let footer = section.footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("临期待办")
        }
    }

    // MARK: - 待处理记录

    private var pendingCaptureSection: some View {
        Section {
            if model.pendingCaptures.isEmpty {
                Text("没有待整理的记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingCaptures) { capture in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(capture.kind.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            CaptureStatusPill(status: capture.status)
                            Spacer()
                        }
                        Text(capture.displayText)
                            .font(.subheadline)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("待处理记录")
        } footer: {
            Text("这些记录已经保存在本机。回到「记录」页可以重新解析或手动创建任务。")
                .font(.caption)
        }
    }

    // MARK: - 同步异常

    private var syncIssueSection: some View {
        Section {
            if model.syncIssues.isEmpty {
                Text("没有同步异常。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.syncIssues) { task in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                        TaskRow(
                            task: task,
                            isBusy: model.busyTaskId == task.id,
                            canUndo: model.canUndo(task),
                            canRetry: model.canRetry(task),
                            onComplete: { Task { await model.complete(task) } },
                            onReopen: { Task { await model.reopen(task) } },
                            onUndo: { Task { await model.undo(task) } },
                            onRetry: { Task { await model.retry(task) } }
                        )
                    }
                }
            }
        } header: {
            Text("同步异常")
        } footer: {
            Text("「写入失败」表示系统写入没有完成；「待对账」表示外部项目可能被改动或删除。任务本身仍然保存在 App 里。")
                .font(.caption)
        }
    }
}

/// 单个任务行。
///
/// 日期用 TaskTimeDisplay 的完整日期（例如 2026-10-12 20:00），
/// 日期型截止日只显示 2026-10-16，不会出现"00:00"这种伪造时刻。
private struct TaskRow: View {

    let task: TaskRecord
    let isBusy: Bool
    let canUndo: Bool
    let canRetry: Bool
    let onComplete: () -> Void
    let onReopen: () -> Void
    let onUndo: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? Color.secondary : Color.primary)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(TaskTimeDisplay.scheduleSummary(for: task))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                WriteStatePill(state: task.externalWriteState, compact: true)
                if let course = task.courseHint, !course.isEmpty {
                    Text(course)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                if task.status == .open {
                    Button("完成", action: onComplete)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                } else if task.status == .done {
                    Button("撤销完成", action: onReopen)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
                if canRetry {
                    Button("重试写入", action: onRetry)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
                if canUndo {
                    Button("撤销", role: .destructive, action: onUndo)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}
