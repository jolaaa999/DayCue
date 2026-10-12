import SwiftUI
import DayCueCore

/// 解析结果预览页。
///
/// 它不占底栏标签，而是"记录"流程的一步。
/// 默认先预览再确认：用户逐条勾选、改标题、改时间，甚至把 task 改成 note。
/// 后端不可用时这里不会出现编造的候选，只会显示失败原因与手动创建入口。
struct ReviewView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [ReviewDraft]
    @State private var saving = false
    @State private var editing: EditingTarget?

    private let context: ReviewContext
    private let onFinished: (String?) -> Void

    /// 正在编辑哪一条的哪个时间字段。
    private struct EditingTarget: Identifiable {
        let id: String
        let index: Int
        let kind: EditorKind
    }

    private enum EditorKind: String, Identifiable {
        case due
        case remind
        var id: String { rawValue }
    }

    init(context: ReviewContext, onFinished: @escaping (String?) -> Void) {
        self.context = context
        self.onFinished = onFinished
        _drafts = State(initialValue: context.drafts)
    }

    var body: some View {
        NavigationStack {
            List {
                header

                if drafts.isEmpty {
                    Section {
                        EmptyStateView(
                            systemImage: "questionmark.circle",
                            title: "没有可确认的候选",
                            message: "后端没有返回任何任务或笔记。你可以手动创建一条任务。"
                        )
                    }
                }

                ForEach($drafts) { $draft in
                    DraftCard(
                        draft: $draft,
                        onEditDue: { editing = EditingTarget(id: draft.id, index: indexOf(draft.id), kind: .due) },
                        onEditRemind: { editing = EditingTarget(id: draft.id, index: indexOf(draft.id), kind: .remind) }
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("解析结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后处理") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("确认") { Task { await confirm() } }
                            .disabled(!drafts.contains { $0.isSelected })
                    }
                }
            }
            .sheet(item: $editing) { target in
                if target.index < drafts.count {
                    DateTimeEditorSheet(draft: $drafts[target.index], target: target.kind == .due ? .due : .remind)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var header: some View {
        Section {
            HStack(spacing: 8) {
                Text(context.mode.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (context.mode == .fixture ? Color.orange : Color.green).opacity(0.16),
                        in: Capsule()
                    )
                    .foregroundStyle(context.mode == .fixture ? Color.orange : Color.green)
                Spacer()
            }
            ForEach(Array(context.warnings.indices), id: \.self) { index in
                Text(context.warnings[index])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("确认之前不会写入苹果提醒事项。每条都可以单独取消勾选。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func indexOf(_ id: String) -> Int {
        drafts.firstIndex { $0.id == id } ?? 0
    }

    private func cancel() {
        // 保留为"待整理"，这样今天页还能看到它，而不是悄悄丢掉。
        try? container.store.updateCaptureStatus(id: context.captureId, status: .needsClarification)
        onFinished("已保留这条记录，可以稍后在「记录」页重新处理。")
        dismiss()
    }

    private func confirm() async {
        saving = true
        defer { saving = false }

        // 确认前再校验一次输入版本：预览打开期间记录若发生了变化，
        // 这份候选就不再对应当前输入，不能拿来创建任务。
        let currentCapture = (try? container.store.capture(id: context.captureId)).flatMap { $0 }
        if let currentCapture,
           CaptureInputVersion.make(from: currentCapture) != context.inputVersion {
            onFinished("记录内容在预览期间发生了变化，请重新解析后再确认。")
            dismiss()
            return
        }

        var created = 0
        var notes: [String] = []

        // 只有「被选中」且「类型是 task」的候选才创建任务；
        // 笔记永远不写进苹果提醒事项，也不计入任务数。规则在 Core 里，可被单元测试。
        for draft in drafts.tasksToCreate {
            let outcome = await container.writer.createTask(from: draft, captureId: context.captureId)
            if outcome.task != nil { created += 1 }
            if let note = outcome.note { notes.append(note) }
        }

        let anySelected = drafts.contains { $0.isSelected }
        try? container.store.updateProposalStatus(
            captureId: context.captureId,
            status: anySelected ? .accepted : .rejected
        )
        try? container.store.updateCaptureStatus(id: context.captureId, status: .extracted)

        let noteCount = drafts.selectedNoteCount
        var message = "已创建 \(created) 条任务。"
        if noteCount > 0 {
            // 说清楚笔记存在哪里：它只随这条记录的解析结果一起保存在本机数据库里，
            // 既不是任务，也不会出现在苹果提醒事项里。
            message += "另有 \(noteCount) 条笔记只保存在本机这条记录里（不会写入提醒事项，也不计入任务）。"
        }
        if !notes.isEmpty {
            message += " " + notes.joined(separator: " ")
        }
        onFinished(message)
        dismiss()
    }
}

/// 单条候选卡片。
private struct DraftCard: View {

    @Binding var draft: ReviewDraft
    let onEditDue: () -> Void
    let onEditRemind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("", isOn: $draft.isSelected)
                    .labelsHidden()
                Picker("类型", selection: $draft.kind) {
                    Text("任务").tag(ProposalItemKind.task)
                    Text("笔记").tag(ProposalItemKind.note)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                Spacer()
                if draft.isFixture {
                    Text("模拟结果")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            TextField("标题", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))

            if let detail = draft.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("原文依据：\(draft.sourceEvidence)", systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let expression = draft.dateExpression, !expression.isEmpty {
                    Text("时间表达：\(expression)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let due = draft.dueText {
                    Button {
                        onEditDue()
                    } label: {
                        Text("截止：\(due)")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("添加截止时间") { onEditDue() }
                        .font(.caption)
                }
            }

            if draft.kind == .task {
                reminderBlock
            }

            if !draft.ambiguities.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(draft.ambiguities.indices), id: \.self) { index in
                        ambiguityRow(draft.ambiguities[index])
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 歧义提示行。未知 code 用问号图标，提示性歧义用信息图标。
    private func ambiguityRow(_ ambiguity: ContractAmbiguity) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ambiguity.code.requiresClarification
                  ? "questionmark.circle.fill"
                  : "info.circle")
                .font(.caption)
                .foregroundStyle(ambiguity.code.requiresClarification ? Color.purple : Color.secondary)
            Text(ambiguity.message.isEmpty ? ambiguity.code.displayName : ambiguity.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reminderBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if draft.hasReminder {
                HStack(spacing: 10) {
                    // 用拼接而不是插值里再嵌字面量：嵌套引号在不同工具链上偶尔会被误读。
                    Text("提醒：" + (draft.remindText ?? "已设置"))
                        .font(.caption)
                    Button("修改") { onEditRemind() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    Button("清除", role: .destructive) {
                        draft.clearReminder()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            } else {
                // 「周五之前」这类只有截止日的任务：明确说没有提醒，并让用户自己决定。
                HStack(spacing: 10) {
                    Text("尚未设置提醒时间")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("添加提醒") { onEditRemind() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// 时间编辑弹层。截止时间与提醒时间都用它，避免两套写法出现不一致的时区处理。
struct DateTimeEditorSheet: View {

    enum Target {
        case due
        case remind
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var draft: ReviewDraft
    let target: Target

    @State private var dueKind: DueKind
    @State private var date: Date

    init(draft: Binding<ReviewDraft>, target: Target) {
        _draft = draft
        self.target = target
        let timeZone = TimeZone(identifier: draft.wrappedValue.timezone) ?? .current
        switch target {
        case .due:
            let parsed = draft.wrappedValue.dueLocal.flatMap { RFC3339.date(fromLocal: $0, timeZone: timeZone) }
            _date = State(initialValue: parsed ?? Date())
            _dueKind = State(initialValue: draft.wrappedValue.dueKind == .none ? .date : draft.wrappedValue.dueKind)
        case .remind:
            let parsed = draft.wrappedValue.remindLocal.flatMap { RFC3339.date(fromLocal: $0, timeZone: timeZone) }
            _date = State(initialValue: parsed ?? Date())
            _dueKind = State(initialValue: draft.wrappedValue.dueKind)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if target == .due {
                    Picker("截止方式", selection: $dueKind) {
                        Text("不设置").tag(DueKind.none)
                        Text("仅日期").tag(DueKind.date)
                        Text("精确时间").tag(DueKind.datetime)
                    }
                    .pickerStyle(.segmented)

                    if dueKind != .none {
                        DatePicker(
                            dueKind == .datetime ? "截止时间" : "截止日期",
                            selection: $date,
                            displayedComponents: dueDisplayedComponents
                        )
                    }

                    Text("「仅日期」只保存日期本身，不会变成当天零点；提醒时刻由你单独设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DatePicker("提醒时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    Text("提醒时间只影响什么时候提醒你，不会改变截止时间。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { apply() }
                }
            }
        }
    }

    /// 显式给 String，避免在 navigationTitle 的重载（LocalizedStringKey / StringProtocol / Text）之间歧义。
    private var editorTitle: String {
        target == .due ? "设置截止时间" : "设置提醒时间"
    }

    /// 显式给类型，避免在 DatePicker 参数位置上让编译器推断数组字面量。
    private var dueDisplayedComponents: DatePickerComponents {
        dueKind == .datetime ? [.date, .hourAndMinute] : [.date]
    }

    private func apply() {
        let timeZone = TimeZone(identifier: draft.timezone) ?? .current
        switch target {
        case .due:
            draft.setDue(kind: dueKind, date: dueKind == .none ? nil : date, timeZone: timeZone)
        case .remind:
            draft.setReminder(date: date, timeZone: timeZone)
        }
        dismiss()
    }
}
