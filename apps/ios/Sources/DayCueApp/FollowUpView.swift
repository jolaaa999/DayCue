import SwiftUI
import UserNotifications
import DayCueCore

/// 课后追问页：列出追问，支持「稍后 / 跳过 / 文字回复 / 语音回复」。
///
/// 产品底线（界面文案里也要写清楚）：
/// 1. 追问是**提前排好的本地通知**，到点不会运行后台 AI；
/// 2. 追问时刻 = 预计结束时间 + 课程延迟，预计结束不等于实际下课，也不代表出席；
/// 3. 复习建议必须用户点「接受」才会创建任务，不接受就一条也不建。
struct FollowUpView: View {

    @EnvironmentObject private var container: AppContainer
    @StateObject private var model = FollowUpViewModel()

    var body: some View {
        NavigationStack {
            List {
                introSection

                if model.activeItems.isEmpty && model.historyItems.isEmpty {
                    emptySection
                } else {
                    if !model.activeItems.isEmpty { activeSection }
                    if !model.historyItems.isEmpty { historySection }
                }

                if !model.statusMessages.isEmpty {
                    Section {
                        ForEach(model.statusMessages, id: \.self) { message in
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("操作结果")
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("课后追问")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.reschedule() }
                    } label: {
                        Label("重新安排", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task {
                model.attach(container)
                model.reload()
            }
            .refreshable {
                model.reload()
            }
            .sheet(item: $model.replyTarget) { item in
                FollowUpReplySheet(item: item) { message in
                    model.statusMessages.insert(message, at: 0)
                    model.reload()
                }
            }
        }
    }

    // MARK: - 说明

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("追问是提前排好的本地通知", systemImage: "bell.badge")
                    .font(.subheadline.weight(.medium))
                Text("到点不会运行后台 AI，也不会自动回答。只有你回复之后，才会归档成笔记，并按需给出复习建议。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("追问时刻是「预计下课时间 + 课程延迟」。预计下课不等于实际下课，也不代表你出席了这节课。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var emptySection: some View {
        Section {
            EmptyStateView(
                systemImage: "bubble.left.and.text.bubble.right",
                title: "暂时没有课后追问",
                message: "到课表页给课程打开「课后追问」，并确认学期第 1 周周一。追问会按预计下课时间提前排成本地通知，到点后出现在这里。"
            )
        }
    }

    // MARK: - 待处理

    private var activeSection: some View {
        Section {
            ForEach(model.activeItems) { item in
                FollowUpRow(item: item, timeZone: model.timeZone) {
                    model.snooze(item, minutes: $0)
                } onSkip: {
                    model.skip(item)
                } onReply: {
                    model.replyTarget = item
                }
            }
        } header: {
            Text("待回复")
        } footer: {
            Text("「稍后」只推迟这条追问的提醒时间，重复多次后会建议你直接跳过，避免一直打扰。")
                .font(.caption)
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        Section {
            ForEach(model.historyItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.courseName)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(item.followUp.state.displayName)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                    Text("追问时刻：" + item.effectiveText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reply = item.reply {
                        Text(reply.kind == .audio ? "语音回复已归档" : "文字回复已归档")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let noteTitle = item.noteTitle {
                            Text("关联笔记：" + noteTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let taskTitle = item.taskTitle {
                            Text("关联任务：" + taskTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("没有创建任务：当时没有接受复习建议。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("没有回复，已\(item.followUp.state.displayName)。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("历史")
        }
    }
}

// MARK: - 列表行

private struct FollowUpRow: View {

    let item: FollowUpItem
    let timeZone: TimeZone
    let onSnooze: (Int) -> Void
    let onSkip: () -> Void
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.courseName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(item.followUp.state.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Text("预计下课：" + item.instanceEndText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("追问时刻：" + item.effectiveText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if item.followUp.attempt > 0 {
                Text("已经稍后过 \(item.followUp.attempt) 次")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Menu {
                    ForEach(FollowUpViewModel.snoozeOptions, id: \.minutes) { option in
                        Button(option.title) { onSnooze(option.minutes) }
                    }
                } label: {
                    Label("稍后", systemImage: "clock")
                        .font(.subheadline)
                }

                Button {
                    onSkip()
                } label: {
                    Label("跳过", systemImage: "arrow.uturn.forward")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)

                Button {
                    onReply()
                } label: {
                    Label("回复", systemImage: "square.and.pencil")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 回复面板

/// 文字 / 语音回复，以及「接受复习建议才建任务」的确认。
private struct FollowUpReplySheet: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let item: FollowUpItem
    let onArchived: (String) -> Void

    @State private var text = ""
    @State private var transcript = ""
    @State private var mediaPath: String?
    @State private var isTranscribing = false
    @State private var acceptedSuggestionId: String?
    @State private var dueDateEnabled = false
    @State private var dueDate = Date()
    @State private var errorMessage: String?
    @State private var archivedNote: NoteRecord?
    @State private var archivedTask: TaskRecord?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                } header: {
                    Text("这节课讲了什么？")
                } footer: {
                    Text("写了什么就存什么，不会替你改写或总结。回复归档成笔记，原样保留。")
                        .font(.caption)
                }

                voiceSection

                if !suggestions.isEmpty {
                    suggestionSection
                }

                if let archivedNote {
                    Section {
                        LabeledContent("笔记", value: archivedNote.title)
                        Text(archivedNote.body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let archivedTask {
                            LabeledContent("任务", value: archivedTask.title)
                            if let due = archivedTask.dueLocal {
                                LabeledContent("截止", value: due)
                            }
                        } else {
                            Text("没有创建任务：你没有接受任何复习建议。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("已归档")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("回复追问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("归档") { submit() }
                        .disabled(archivedNote != nil)
                }
            }
        }
    }

    private var voiceSection: some View {
        Section {
            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在转写这段录音…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if container.recorder.isRecording {
                // 录音时长用 TimelineView 驱动：AudioRecorderService 的变更信号没有
                // 经过 AppContainer 转发，直接读 elapsed 不会触发重绘。
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Button(role: .destructive) {
                        Task { await stopRecording() }
                    } label: {
                        Label("停止录音（已录 \(Int(container.recorder.elapsed)) 秒）", systemImage: "stop.circle")
                    }
                }
            } else {
                Button {
                    Task { await startRecording() }
                } label: {
                    Label(mediaPath == nil ? "录一段语音回复" : "重新录音", systemImage: "mic")
                }
            }

            if !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("转写结果（会一起归档）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("转写文本", text: $transcript, axis: .vertical)
                        .lineLimit(2...6)
                }
            }

            if let lastError = container.recorder.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("语音回复")
        } footer: {
            Text("录音先存到本机，再尝试转写。转写失败也不会丢录音：语音本身仍然会归档。")
                .font(.caption)
        }
    }

    private var suggestionSection: some View {
        Section {
            ForEach(suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { acceptedSuggestionId == suggestion.id },
                        set: { isOn in
                            acceptedSuggestionId = isOn ? suggestion.id : nil
                        }
                    )) {
                        Text(suggestion.title)
                            .font(.subheadline.weight(.medium))
                    }
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if acceptedSuggestionId == suggestion.id {
                        Toggle("设置截止日期", isOn: $dueDateEnabled)
                        if dueDateEnabled {
                            DatePicker("截止", selection: $dueDate, displayedComponents: .date)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("复习建议（可选）")
        } footer: {
            Text("这些建议只是根据回复里的关键词给出的提示。只有你打开开关表示接受，才会创建任务；不接受就什么都不会建。")
                .font(.caption)
        }
    }

    private var suggestions: [FollowUpReviewSuggestion] {
        FollowUpArchivePlanner.suggestions(for: combinedBody)
    }

    private var combinedBody: String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty { return trimmedText }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 录音

    private func startRecording() async {
        errorMessage = nil
        do {
            // 重录时先清掉上一段，避免用户以为新录音被保留了。
            container.recorder.discard()
            mediaPath = nil
            transcript = ""
            try await container.recorder.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        guard let url = container.recorder.stop() else {
            errorMessage = "没有录到声音。"
            return
        }

        // 先转写，再落盘：转写失败也不能让录音消失。
        isTranscribing = true
        do {
            let outcome = try await container.transcriber.transcribe(
                audioURL: url,
                timezone: container.currentTimeZone.identifier
            )
            transcript = outcome.text
        } catch {
            // 转写失败只提示，不阻断归档：语音本身仍然是有效回复。
            errorMessage = "转写没有完成：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        isTranscribing = false

        do {
            let stored = try container.media.storeAudio(at: url, captureId: item.followUp.id)
            mediaPath = stored.url.path
        } catch {
            errorMessage = "录音保存失败：\(error.localizedDescription)"
        }
        container.recorder.clearAfterSubmit()
    }

    // MARK: - 归档

    private func submit() {
        errorMessage = nil
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !spoken.isEmpty || mediaPath != nil else {
            errorMessage = "请先写点内容，或录一段语音。空回复不会被归档。"
            return
        }

        let accepted = suggestions.first { $0.id == acceptedSuggestionId }
        let timeZone = container.currentTimeZone
        let request = FollowUpArchiveRequest(
            followUp: item.followUp,
            course: container.store.course(id: item.followUp.courseId) ?? nil,
            replyKind: mediaPath == nil ? .text : .audio,
            text: body.isEmpty ? nil : body,
            transcript: spoken.isEmpty ? nil : spoken,
            mediaPath: mediaPath,
            instanceStartsAtUTC: item.instance?.startsAtUTC,
            // 只有用户明确接受的那一条建议会进来；nil 时归档器不会建任务。
            acceptedSuggestion: accepted,
            taskDueLocalDate: accepted != nil && dueDateEnabled
                ? RFC3339.localDateString(from: dueDate, timeZone: timeZone)
                : nil,
            timeZone: timeZone,
            now: Date()
        )

        guard let plan = FollowUpArchivePlanner.plan(request) else {
            errorMessage = "这条回复无法归档（追问已经是终态，或内容为空）。"
            return
        }

        do {
            let outcome = try container.store.applyFollowUpArchive(plan)
            archivedNote = outcome.note
            archivedTask = outcome.task
            // 归档成功后立刻过一遍记忆抽取：学生的口头回复里经常带着
            // "我习惯先看文献再做题"这类自带原文依据的偏好，这是记忆最自然的来源。
            // 抽取失败不能影响归档结果，所以这里吞掉错误（候选落没落库由记忆页自己显示）。
            _ = try? container.memoryIngest.ingest(replies: [outcome.reply], now: Date())
            let taskSuffix = outcome.task == nil ? "没有创建任务。" : "并创建了任务「\(outcome.task?.title ?? "")」。"
            onArchived("回复已归档为笔记「\(outcome.note.title)」，\(taskSuffix)")
        } catch {
            errorMessage = "归档失败：\(error)"
        }
    }
}

// MARK: - 列表项

/// 追问 + 它关联的课程/实例/回复，界面直接用，不再自己查库。
struct FollowUpItem: Identifiable, Equatable {
    var followUp: FollowUpRecord
    var courseName: String
    var instance: CourseInstanceRecord?
    var instanceEndText: String
    var effectiveText: String
    var isPickupable: Bool
    var reply: FollowUpReplyRecord?
    var noteTitle: String?
    var taskTitle: String?

    var id: String { followUp.id }
}

// MARK: - 视图模型

@MainActor
final class FollowUpViewModel: ObservableObject {

    struct SnoozeOption: Equatable {
        let title: String
        let minutes: Int
    }

    static let snoozeOptions: [SnoozeOption] = [
        SnoozeOption(title: "10 分钟后", minutes: 10),
        SnoozeOption(title: "30 分钟后", minutes: 30),
        SnoozeOption(title: "1 小时后", minutes: 60),
        SnoozeOption(title: "今晚", minutes: 4 * 60)
    ]

    @Published private(set) var activeItems: [FollowUpItem] = []
    @Published private(set) var historyItems: [FollowUpItem] = []
    @Published var statusMessages: [String] = []
    @Published var errorMessage: String?
    @Published var replyTarget: FollowUpItem?

    private(set) var timeZone: TimeZone = .current
    private var container: AppContainer?
    private let notifications = FollowUpNotificationScheduler()

    func attach(_ container: AppContainer) {
        self.container = container
    }

    func reload() {
        guard let container else { return }
        timeZone = container.currentTimeZone
        let store = container.store
        let now = Date()
        errorMessage = nil

        do {
            let all = try store.followUps(limit: 300)
            var coursesById: [String: CourseRecord] = [:]
            for course in try store.courses(includeDeleted: true, limit: 300) {
                coursesById[course.id] = course
            }
            let prepared = all.map { followUp -> FollowUpItem in
                makeItem(
                    followUp: followUp,
                    now: now,
                    coursesById: coursesById,
                    store: store
                )
            }
            activeItems = prepared
                .filter { !$0.followUp.state.isTerminal }
                .sorted { $0.followUp.scheduledAtUTC < $1.followUp.scheduledAtUTC }
            historyItems = prepared
                .filter { $0.followUp.state.isTerminal }
                .sorted { $0.followUp.updatedAt > $1.followUp.updatedAt }
        } catch {
            errorMessage = "读取课后追问失败：\(error)"
        }
    }

    /// 稍后：时间与次数上限都由 FollowUpScheduler 判定，这里只展示结果。
    func snooze(_ item: FollowUpItem, minutes: Int) {
        guard let container else { return }
        let now = Date()
        let until = now.addingTimeInterval(TimeInterval(minutes) * 60)
        do {
            switch try container.store.snoozeFollowUp(id: item.followUp.id, until: until, at: now) {
            case let .applied(record):
                if let effective = FollowUpScheduler.effectiveDate(of: record) {
                    statusMessages.insert("已改到 " + displayTime(effective, timeZone: timeZone) + " 再提醒。", at: 0)
                    notifications.cancel(ids: [record.id])
                    Task { await notifications.schedule([record], coursesById: [:], at: now, timeZone: timeZone) }
                }
            case .limitReached:
                statusMessages.insert("稍后次数已达上限，建议直接「跳过」，避免一直被打扰。", at: 0)
            case .notFound:
                errorMessage = "这条追问已经不在了。"
            }
            reload()
        } catch {
            errorMessage = "稍后失败：\(error)"
        }
    }

    func skip(_ item: FollowUpItem) {
        guard let container else { return }
        let now = Date()
        guard let updated = FollowUpScheduler.applying(item.followUp, state: .skipped, at: now) else {
            errorMessage = "这条追问已经是终态，不能再改。"
            return
        }
        do {
            _ = try container.store.applyFollowUpState(updated)
            notifications.cancel(ids: [item.followUp.id])
            statusMessages.insert("已跳过这条追问，之后不会再提醒。", at: 0)
            reload()
        } catch {
            errorMessage = "跳过失败：\(error)"
        }
    }

    /// 重新安排：跑一次纯调度并落库，再为可发的追问排本地通知。
    func reschedule() async {
        guard let container else { return }
        let now = Date()
        timeZone = container.currentTimeZone
        let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let end = now.addingTimeInterval(30 * 24 * 60 * 60)
        do {
            let outcome = try container.store.rescheduleFollowUps(from: start, to: end, at: now)
            var messages: [String] = []
            messages.append("检查了 \(outcome.instancesConsidered) 节课：新建 \(outcome.applied.createdCount) 条追问，重排 \(outcome.applied.updatedCount) 条，过期 \(outcome.applied.expiredCount) 条。")
            if !outcome.applied.skipped.isEmpty {
                messages.append("有 \(outcome.applied.skipped.count) 节课没有安排追问（停课或课程开关关闭）。")
            }
            messages.append(contentsOf: outcome.applied.warnings)
            statusMessages = messages

            reload()

            let granted = await notifications.requestAuthorization()
            if granted {
                var coursesById: [String: CourseRecord] = [:]
                for course in (try? container.store.courses(includeDeleted: true, limit: 300)) ?? [] {
                    coursesById[course.id] = course
                }
                let toSchedule = activeItems.map { $0.followUp }
                let count = await notifications.schedule(toSchedule, coursesById: coursesById, at: now, timeZone: timeZone)
                statusMessages.insert("已排 \(count) 条本地通知。追问到点只会提醒你，不会自动生成任何内容。", at: 0)
            } else {
                statusMessages.insert("没有通知权限，追问不会弹出提醒。可以在系统设置里开启通知。", at: 0)
            }
        } catch {
            errorMessage = "重新安排失败：\(error)"
        }
    }

    // MARK: - 组装列表项

    private func makeItem(
        followUp: FollowUpRecord,
        now: Date,
        coursesById: [String: CourseRecord],
        store: DayCueStore
    ) -> FollowUpItem {
        let course = coursesById[followUp.courseId]
        let instance = (try? store.instance(id: followUp.courseInstanceId)) ?? nil
        let endClock = instance.flatMap { CourseGridPlacement.clock(ofUTC: $0.endsAtUTC, timeZone: timeZone) }
        let effective = FollowUpScheduler.effectiveDate(of: followUp)

        var reply: FollowUpReplyRecord?
        var noteTitle: String?
        var taskTitle: String?
        if let latest = ((try? store.followUpReplies(followUpId: followUp.id)) ?? []).last {
            reply = latest
            if let noteId = latest.noteId, let note = (try? store.followUpArchiveNote(id: noteId)) ?? nil {
                noteTitle = note.title
            }
            if let taskId = latest.taskId, let task = (try? store.task(id: taskId)) ?? nil {
                taskTitle = task.title
            }
        }

        return FollowUpItem(
            followUp: followUp,
            courseName: course?.name ?? "未知课程",
            instance: instance,
            instanceEndText: endClock ?? "时间未知",
            effectiveText: displayTime(effective, timeZone: timeZone),
            isPickupable: FollowUpScheduler.isPickupable(followUp, at: now),
            reply: reply,
            noteTitle: noteTitle,
            taskTitle: taskTitle
        )
    }

    private func displayTime(_ date: Date?, timeZone: TimeZone) -> String {
        guard let date else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 本地通知

/// 追问的本地通知排期。
///
/// 追问**只能**以本地通知的形式发出：没有「到点运行后台 AI」的路径。
/// iOS 不保证后台任务按时执行，只有本地通知能做到「准时且可解释」。
struct FollowUpNotificationScheduler {

    static let identifierPrefix = "followup."

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    /// 只为「还没到点、且尚未落终态」的追问排通知；已经该响的不补排，免得立刻弹一堆。
    @discardableResult
    func schedule(
        _ followUps: [FollowUpRecord],
        coursesById: [String: CourseRecord],
        at now: Date,
        timeZone: TimeZone
    ) async -> Int {
        let center = UNUserNotificationCenter.current()
        var scheduled = 0

        for followUp in followUps {
            guard !followUp.state.isTerminal else { continue }
            guard followUp.state == .scheduled || followUp.state == .snoozed else { continue }
            guard let fireDate = FollowUpScheduler.effectiveDate(of: followUp), fireDate > now else { continue }
            // 已经过期的追问不排：它会在调度器里落成 expired。
            guard !FollowUpScheduler.isExpired(followUp, at: now) else { continue }

            let courseName = coursesById[followUp.courseId]?.name
            let content = UNMutableNotificationContent()
            content.title = "这节课上完了吗？"
            content.body = (courseName.map { "「\($0)」" } ?? "刚下课") + "写一句就归档成笔记。不回复也不会自动生成任何内容。"
            content.sound = .default
            content.userInfo = ["followUpId": followUp.id]

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.identifierPrefix + followUp.id,
                content: content,
                trigger: trigger
            )
            if (try? await center.add(request)) != nil {
                scheduled += 1
            }
        }

        return scheduled
    }

    func cancel(ids: [String]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids.map { Self.identifierPrefix + $0 })
    }
}
