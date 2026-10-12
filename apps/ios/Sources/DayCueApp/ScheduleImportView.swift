import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import DayCueCore

/// ICS 文件类型。系统不认识 ".ics" 时退回纯文本，
/// 让用户至少还能选到文件，而不是整个入口不可用。
private let icsContentType: UTType = UTType(filenameExtension: "ics") ?? .plainText

/// 课表导入：图片识别 + ICS 文件。
///
/// 铁律：**未确认不得写入**。
/// 这个页面只做「识别 -> 预览 -> 逐条确认」，真正的写库动作只在用户点了
/// 「确认并写入」之后发生，而且只写被勾选的那些条目（见 ScheduleWritePlanner）。
///
/// 产品限制：课表里的预计结束时间只用于排版和提前排本地通知，
/// 它不等于实际下课，也不代表用户出席了这节课。
struct ScheduleImportView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ScheduleImportViewModel()
    @State private var pickedPhoto: PhotosPickerItem?

    private let onImported: () -> Void

    init(onImported: @escaping () -> Void = {}) {
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            List {
                sourceSection
                if model.pickedImage != nil || !model.ocrCandidates.isEmpty {
                    imagePreviewSection
                    ocrCandidateSection
                }
                if model.icsPlan != nil {
                    icsCourseSection
                }
                optionsSection
                messageSection
                confirmSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("导入课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                model.attach(container)
            }
            .fileImporter(
                isPresented: $model.showICSImporter,
                allowedContentTypes: [icsContentType],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    model.importICS(from: url)
                case let .failure(error):
                    model.errorMessage = "文件选择失败：\(error.localizedDescription)"
                }
            }
            .onChange(of: pickedPhoto) { _, newValue in
                guard newValue != nil else { return }
                Task { await model.handlePickedPhoto(newValue) }
            }
        }
    }

    // MARK: - 来源

    private var sourceSection: some View {
        Section {
            PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                Label("选择课表照片并识别文字", systemImage: "text.viewfinder")
            }
            Button {
                model.showICSImporter = true
            } label: {
                Label("选择 ICS 文件", systemImage: "doc.text")
            }
        } header: {
            Text("来源")
        } footer: {
            Text("图片识别在本机完成。ICS 是教务系统常见的日历导出格式。两种来源都只生成预览，不会直接改动你的课表。")
                .font(.caption)
        }
    }

    // MARK: - 图片与识别

    private var imagePreviewSection: some View {
        Section {
            if let image = model.pickedImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.unmatchedLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("这些行没有识别成课程，已原样列出：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.unmatchedLines, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("识别结果")
        }
    }

    // MARK: - OCR 候选

    private var ocrCandidateSection: some View {
        Section {
            ForEach($model.ocrCandidates) { $item in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $item.isConfirmed) {
                        Text(item.candidate.courseName.isEmpty ? "（未识别出课程名）" : item.candidate.courseName)
                            .font(.subheadline.weight(.medium))
                    }

                    Text(item.candidate.confidence.displayName + " · 需要你确认后才写入")
                        .font(.caption2)
                        .foregroundStyle(item.candidate.confidence == .high ? Color.green : Color.orange)

                    TextField("课程名", text: $item.candidate.courseName)

                    Picker("星期", selection: $item.candidate.weekday) {
                        Text("未识别").tag(Int?.none)
                        ForEach(1...7, id: \.self) { weekday in
                            Text(ScheduleOCRMapping.weekdayName(weekday)).tag(Int?.some(weekday))
                        }
                    }

                    Picker("开始节次", selection: $item.candidate.sectionStart) {
                        Text("未识别").tag(Int?.none)
                        ForEach(1...20, id: \.self) { section in
                            Text("第 \(section) 节").tag(Int?.some(section))
                        }
                    }

                    Picker("结束节次", selection: $item.candidate.sectionEnd) {
                        Text("未识别").tag(Int?.none)
                        ForEach(1...20, id: \.self) { section in
                            Text("第 \(section) 节").tag(Int?.some(section))
                        }
                    }

                    Picker("单双周", selection: $item.candidate.weekParity) {
                        ForEach(WeekParity.allCases, id: \.self) { parity in
                            Text(parity.displayName).tag(parity)
                        }
                    }

                    Stepper("起始周：第 \(item.candidate.weekStart) 周", value: $item.candidate.weekStart, in: 1...30)
                    Stepper("结束周：第 \(item.candidate.weekEnd) 周", value: $item.candidate.weekEnd, in: 1...30)

                    if let teacher = item.candidate.teacher, !teacher.isEmpty {
                        Text("老师：\(teacher)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let location = item.candidate.location, !location.isEmpty {
                        Text("地点：\(location)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(item.candidate.issues, id: \.self) { issue in
                        Text("· " + issue)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Text("原文：" + item.candidate.sourceLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Button {
                model.confirmOCRImport()
                if model.errorMessage == nil {
                    onImported()
                    dismiss()
                }
            } label: {
                Label("确认并写入勾选的 \(model.confirmedCandidateCount) 条课程", systemImage: "checkmark.circle")
            }
            .disabled(model.confirmedCandidateCount == 0)
        } header: {
            Text("识别出的课程（逐条确认）")
        } footer: {
            Text("没有勾选的条目一个字节都不会写入。字段不全的条目即使勾选，也会被跳过并在下面说明原因。")
                .font(.caption)
        }
    }

    // MARK: - ICS 课程

    private var icsCourseSection: some View {
        Section {
            if let plan = model.icsPlan {
                LabeledContent("解析到的事件", value: "\(plan.eventCount) 条")
                LabeledContent("展开出的课程实例", value: "\(plan.expandedOccurrenceCount) 次")

                ForEach($model.icsCourses) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $item.isConfirmed) {
                            Text(item.candidate.name)
                                .font(.subheadline.weight(.medium))
                        }
                        if let location = item.candidate.location, !location.isEmpty {
                            Text("地点：\(location)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(item.candidate.eventCount) 个事件 · \(item.candidate.instanceCount) 次课")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let first = item.candidate.firstStartsAtUTC {
                            Text("首次：\(first)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Button {
                model.confirmICSImport()
                if model.errorMessage == nil {
                    onImported()
                    dismiss()
                }
            } label: {
                Label("确认并写入勾选的 \(model.confirmedICSCourseCount) 门课程", systemImage: "checkmark.circle")
            }
            .disabled(model.confirmedICSCourseCount == 0)

            if model.icsSkippedLineCount > 0 {
                Text("有 \(model.icsSkippedLineCount) 行无法解析，已跳过；其余内容仍然可以导入。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("文件里的课程（逐条确认）")
        } footer: {
            Text("ICS 里的事件本身就是具体的某几次课，所以导入的是课程实例而不是每周规则。重复导入同一份文件会命中同一批实例，不会产生重复。")
                .font(.caption)
        }
    }

    // MARK: - 选项

    private var optionsSection: some View {
        Section {
            Toggle("导入后为这些课安排课后追问", isOn: $model.followUpEnabled)
            if model.followUpEnabled {
                Stepper("预计下课后 \(model.followUpDelayMinutes) 分钟", value: $model.followUpDelayMinutes, in: 0...240, step: 5)
            }
        } header: {
            Text("导入选项")
        } footer: {
            Text("追问是提前排好的本地通知，到点不会运行后台 AI。预计下课时间不等于实际下课，也不代表出勤。")
                .font(.caption)
        }
    }

    // MARK: - 提示

    @ViewBuilder
    private var messageSection: some View {
        if let error = model.errorMessage {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        if !model.ocrWarnings.isEmpty {
            Section {
                ForEach(model.ocrWarnings, id: \.self) { warning in
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("识别说明")
            }
        }
        if let imported = model.importSummary {
            Section {
                Text(imported)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("写入结果")
            }
        }
    }

    // MARK: - 确认

    private var confirmSection: some View {
        Section {
            Text(model.hasAnythingToConfirm
                 ? "确认按钮只写勾选的条目。写入后可以到课表页逐格核对。"
                 : "先选择照片或 ICS 文件，识别出内容后再逐条确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 视图模型

/// OCR 候选的界面包装：candidate 是待确认的数据，isConfirmed 是用户是否勾选。
struct EditableScheduleCandidate: Identifiable {
    var candidate: ScheduleCandidate
    var isConfirmed: Bool
    var id: String { candidate.id }
}

/// ICS 课程的界面包装。
struct EditableICSCourse: Identifiable {
    var candidate: ICSCourseCandidate
    var isConfirmed: Bool
    var id: String { candidate.id }
}

@MainActor
final class ScheduleImportViewModel: ObservableObject {

    @Published var ocrCandidates: [EditableScheduleCandidate] = []
    @Published var ocrWarnings: [String] = []
    @Published var unmatchedLines: [String] = []
    @Published var icsCourses: [EditableICSCourse] = []
    @Published private(set) var icsPlan: ICSImportPlan?
    @Published private(set) var icsSkippedLineCount = 0
    @Published var pickedImage: UIImage?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var importSummary: String?
    @Published var showICSImporter = false
    @Published var followUpEnabled = false
    @Published var followUpDelayMinutes = 5

    private var container: AppContainer?

    func attach(_ container: AppContainer) {
        self.container = container
    }

    var confirmedCandidateCount: Int {
        ocrCandidates.filter { $0.isConfirmed && $0.candidate.isCompleteForRule }.count
    }

    var confirmedICSCourseCount: Int {
        icsCourses.filter { $0.isConfirmed }.count
    }

    var hasAnythingToConfirm: Bool {
        !ocrCandidates.isEmpty || icsPlan != nil
    }

    // MARK: - 图片识别

    func handlePickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil
        importSummary = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "这张图读不出来，请换一张。"
            return
        }
        pickedImage = image
        ocrCandidates = []
        icsPlan = nil
        await recognize(image)
    }

    private func recognize(_ image: UIImage) async {
        guard let container else { return }
        statusMessage = "正在本机识别文字…"
        do {
            let text = try await container.ocr.recognizeText(in: image)
            let result = ScheduleOCRMapping.map(text: text)
            ocrCandidates = result.candidates.map { EditableScheduleCandidate(candidate: $0, isConfirmed: false) }
            ocrWarnings = result.warnings
            unmatchedLines = result.unmatchedLines
            statusMessage = result.candidates.isEmpty
                ? "没有识别出课程。可以手动添加，或换一张更清晰的图片。"
                : "识别出 \(result.candidates.count) 条候选，请逐条确认。"
        } catch {
            // OCR 失败不能编造内容：如实说明，让用户换图或手动添加。
            statusMessage = nil
            ocrCandidates = []
            ocrWarnings = []
            unmatchedLines = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "文字识别失败：\(error)"
        }
    }

    // MARK: - ICS

    func importICS(from url: URL) {
        errorMessage = nil
        importSummary = nil
        ocrCandidates = []
        pickedImage = nil

        // 文件来自系统文档选择器，必须显式申请访问权限，否则读出来是空。
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let fallbackTimeZone = container?.currentTimeZone ?? .current
            let parseResult = ICSParser.parse(text: text, fallbackTimeZone: fallbackTimeZone)
            let now = Date()
            let range = expansionRange(timeZone: fallbackTimeZone)
            let plan = ICSImportPlanner.plan(
                parseResult: parseResult,
                rangeStart: range.start,
                rangeEnd: range.end,
                fallbackTimeZone: fallbackTimeZone,
                now: now
            )
            icsPlan = plan
            icsCourses = plan.courses.map { EditableICSCourse(candidate: $0, isConfirmed: false) }
            icsSkippedLineCount = plan.skippedLineCount
            statusMessage = plan.courses.isEmpty
                ? "文件里没有解析出任何课程。如果这不是空文件，请检查导出格式。"
                : "解析出 \(plan.courses.count) 门课程，请逐条确认。"
        } catch {
            icsPlan = nil
            icsCourses = []
            errorMessage = "读取 ICS 文件失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 写入

    func confirmOCRImport() {
        guard let container else { return }
        errorMessage = nil
        importSummary = nil

        let confirmedIds = Set(ocrCandidates.filter { $0.isConfirmed }.map { $0.id })
        guard !confirmedIds.isEmpty else {
            errorMessage = "还没有勾选任何候选。未确认的内容不会写入。"
            return
        }

        let store = container.store
        let now = Date()
        let timeZone = container.currentTimeZone
        let plan = ScheduleWritePlanner.plan(
            candidates: ocrCandidates.map { $0.candidate },
            confirmedIds: confirmedIds,
            term: store.setting(DayCueStore.CourseSettingKey.term),
            followUpEnabled: followUpEnabled,
            followUpDelayMinutes: followUpDelayMinutes,
            now: now
        )

        guard !plan.isEmpty else {
            errorMessage = plan.warnings.first ?? "勾选的内容还不能写入，请补全课程名、星期与节次。"
            return
        }

        let range = expansionRange(timeZone: timeZone)
        do {
            let outcome = try store.applyScheduleWritePlanAndExpand(
                plan,
                anchor: store.courseTermAnchor(),
                rangeStart: range.start,
                rangeEnd: range.end,
                timeZone: timeZone,
                now: now
            )
            let created = outcome.expansions.reduce(0) { $0 + $1.created.count }
            importSummary = "已写入 \(outcome.write.insertedCourses) 门课程、\(outcome.write.insertedRules) 条每周规则，生成 \(created) 个课程实例。"
            ocrWarnings = plan.warnings + outcome.warnings
        } catch {
            errorMessage = "写入失败：\(error)"
        }
    }

    func confirmICSImport() {
        guard let container else { return }
        errorMessage = nil
        importSummary = nil

        guard let icsPlan else {
            errorMessage = "还没有可导入的 ICS 内容。"
            return
        }
        let confirmedIds = Set(icsCourses.filter { $0.isConfirmed }.map { $0.id })
        guard !confirmedIds.isEmpty else {
            errorMessage = "还没有勾选任何课程。未确认的内容不会写入。"
            return
        }

        let store = container.store
        let now = Date()
        let timeZone = container.currentTimeZone
        let plan = ScheduleWritePlanner.plan(
            icsImportPlan: icsPlan,
            confirmedCourseIds: confirmedIds,
            term: store.setting(DayCueStore.CourseSettingKey.term),
            followUpEnabled: followUpEnabled,
            followUpDelayMinutes: followUpDelayMinutes,
            now: now
        )

        guard !plan.isEmpty else {
            errorMessage = plan.warnings.first ?? "没有可写入的课程。"
            return
        }

        let range = expansionRange(timeZone: timeZone)
        do {
            let outcome = try store.applyScheduleWritePlanAndExpand(
                plan,
                anchor: nil,
                rangeStart: range.start,
                rangeEnd: range.end,
                timeZone: timeZone,
                now: now
            )
            importSummary = "已写入 \(outcome.write.insertedCourses) 门课程、\(outcome.write.createdInstances.count) 个课程实例；\(outcome.write.preservedInstanceIds.count) 个已存在的实例保持原样。"
            icsPlanWarningMerge(plan.warnings + outcome.warnings)
        } catch {
            errorMessage = "写入失败：\(error)"
        }
    }

    private func icsPlanWarningMerge(_ warnings: [String]) {
        var merged = warnings
        if icsSkippedLineCount > 0 {
            merged.append("有 \(icsSkippedLineCount) 行无法解析，已跳过；其余内容照常导入。")
        }
        ocrWarnings = merged
    }

    /// 展开课程实例的区间：有学期锚点就从第 1 周周一开始算 20 周，
    /// 没有锚点就按「现在起 120 天」。两种都是显式区间，不依赖当前日期之外的假设。
    private func expansionRange(timeZone: TimeZone) -> (start: Date, end: Date) {
        if let anchor = container?.store.courseTermAnchor(),
           let firstMonday = CourseInstanceExpander.startOfLocalDay(
                localDate: anchor.firstWeekMondayLocalDate,
                timeZone: timeZone
           ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let end = calendar.date(byAdding: .day, value: 20 * 7, to: firstMonday) ?? firstMonday
            return (firstMonday, end.addingTimeInterval(-1))
        }
        let now = Date()
        return (now, now.addingTimeInterval(120 * 24 * 60 * 60))
    }
}
