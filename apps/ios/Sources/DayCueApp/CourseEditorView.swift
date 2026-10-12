import SwiftUI
import DayCueCore

/// 课程编辑器：手动增改课程与它的每周规则（星期、节次、单双周、周次范围）。
///
/// 为什么把「学期第 1 周周一」也放在这里：单双周必须有一个确定的第一周才能算。
/// 缺它时**不猜**一个开学日期——猜错的后果是整学期的单双周反转。
///
/// 保存按钮会先写课程与规则，再按学期锚点展开课程实例。
/// 展开只补缺：已经存在的实例（包括用户标的停课 / 调课）一个字段都不会被动。
struct CourseEditorView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    private let editingCourse: CourseRecord?
    private let onSaved: () -> Void

    @State private var name: String
    @State private var teacher: String
    @State private var location: String
    @State private var term: String
    @State private var colorHex: String
    @State private var followUpEnabled: Bool
    @State private var followUpDelayMinutes: Int
    @State private var rules: [EditableRule]

    @State private var expandAfterSave = true
    @State private var anchorIsSet = false
    @State private var anchorMonday = Date()

    @State private var errorMessage: String?
    @State private var notes: [String] = []

    init(course: CourseRecord?, rules: [CourseScheduleRule], onSaved: @escaping () -> Void) {
        self.editingCourse = course
        self.onSaved = onSaved
        _name = State(initialValue: course?.name ?? "")
        _teacher = State(initialValue: course?.teacher ?? "")
        _location = State(initialValue: course?.location ?? "")
        _term = State(initialValue: course?.term ?? "")
        _colorHex = State(initialValue: course?.color ?? ScheduleWritePlanner.colorPalette[0])
        _followUpEnabled = State(initialValue: course?.followUpEnabled ?? false)
        _followUpDelayMinutes = State(initialValue: course?.followUpDelayMinutes ?? 5)
        let prepared = rules.map { EditableRule(rule: $0, timeZone: .current) }
        _rules = State(initialValue: prepared.isEmpty ? [EditableRule.new(timeZone: .current)] : prepared)
    }

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                if editingCourse == nil {
                    termSection
                }
                rulesSection
                followUpSection

                if !notes.isEmpty {
                    Section {
                        ForEach(notes, id: \.self) { note in
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
            .navigationTitle(editingCourse == nil ? "添加课程" : "编辑课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .task {
                loadExistingAnchor()
            }
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section {
            TextField("课程名，例如：操作系统", text: $name)

            TextField("老师（可留空）", text: $teacher)
            TextField("地点（可留空）", text: $location)

            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                    .font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ScheduleWritePlanner.colorPalette, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color.dayCue(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if hex == colorHex {
                                            Circle().strokeBorder(Color.primary, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择颜色 \(hex)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("基本信息")
        } footer: {
            Text("颜色只用来在周视图里区分课程，不代表重要程度。")
                .font(.caption)
        }
    }

    // MARK: - 学期锚点

    private var termSection: some View {
        Section {
            Toggle("设置学期第 1 周周一", isOn: $anchorIsSet)
            if anchorIsSet {
                DatePicker("第 1 周周一", selection: $anchorMonday, displayedComponents: .date)
            } else if let anchor = container.store.courseTermAnchor() {
                LabeledContent("当前学期锚点", value: anchor.firstWeekMondayLocalDate)
            } else {
                Text("还没有设置。单双周必须靠它计算，缺它时不会生成课程实例。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("学期")
        } footer: {
            Text("锚点必须是第 1 周的周一。锚错一天，整学期的单双周都会反转。")
                .font(.caption)
        }
    }

    // MARK: - 每周规则

    private var rulesSection: some View {
        Section {
            ForEach($rules) { $rule in
                VStack(alignment: .leading, spacing: 10) {
                    Picker("星期", selection: $rule.weekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(ScheduleOCRMapping.weekdayName(weekday)).tag(weekday)
                        }
                    }

                    Stepper("开始节次：第 \(rule.sectionStart) 节", value: $rule.sectionStart, in: 1...20)
                    Stepper("结束节次：第 \(rule.sectionEnd) 节", value: $rule.sectionEnd, in: 1...20)

                    Picker("单双周", selection: $rule.weekParity) {
                        ForEach(WeekParity.allCases, id: \.self) { parity in
                            Text(parity.displayName).tag(parity)
                        }
                    }

                    Stepper("起始周：第 \(rule.weekStart) 周", value: $rule.weekStart, in: 1...30)
                    Stepper("结束周：第 \(rule.weekEnd) 周", value: $rule.weekEnd, in: 1...30)

                    HStack {
                        Text("上课时间")
                        Spacer()
                        Text("\(rule.startTimeLocal) – \(rule.endTimeLocal)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Button("按默认作息表填时间") {
                        applyDefaultTimetable(to: $rule)
                    }
                    .font(.subheadline)

                    Toggle("限定生效日期", isOn: $rule.effectiveRangeEnabled)
                    if rule.effectiveRangeEnabled {
                        DatePicker("从", selection: $rule.effectiveFrom, displayedComponents: .date)
                        DatePicker("到", selection: $rule.effectiveTo, displayedComponents: .date)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                rules.remove(atOffsets: offsets)
            }

            Button {
                rules.append(EditableRule.new(timeZone: container.currentTimeZone))
            } label: {
                Label("添加一条每周规则", systemImage: "plus")
            }
        } header: {
            Text("每周规则")
        } footer: {
            Text("节次时间是纸面作息，只用于排版与排通知。删除规则不会删除已经生成的课程实例，停课与调课会保留。")
                .font(.caption)
        }
    }

    // MARK: - 课后追问

    private var followUpSection: some View {
        Section {
            Toggle("这门课安排课后追问", isOn: $followUpEnabled)
            if followUpEnabled {
                Stepper("预计下课后 \(followUpDelayMinutes) 分钟", value: $followUpDelayMinutes, in: 0...240, step: 5)
                Toggle("保存后按当前学期展开课程实例", isOn: $expandAfterSave)
            }
        } header: {
            Text("课后追问")
        } footer: {
            Text("追问时间是「预计下课时间 + 延迟」，它会**提前排成本地通知**，到点不会运行后台 AI。预计下课不等于实际下课，也不代表你出席了这节课。")
                .font(.caption)
        }
    }

    // MARK: - 动作

    private func loadExistingAnchor() {
        guard let anchor = container.store.courseTermAnchor() else { return }
        anchorIsSet = true
        // 用课表锚点自己的时区解析，避免用户跨时区后锚点整体偏移一天。
        let timeZone = TimeZone(identifier: anchor.timeZoneIdentifier) ?? container.currentTimeZone
        if let date = RFC3339.date(fromLocal: anchor.firstWeekMondayLocalDate, timeZone: timeZone) {
            anchorMonday = date
        }
    }

    private func applyDefaultTimetable(to rule: Binding<EditableRule>) {
        if let start = CourseSectionTimetable.time(forSection: rule.wrappedValue.sectionStart) {
            rule.wrappedValue.startTimeLocal = start.startTime
        }
        if let end = CourseSectionTimetable.time(forSection: rule.wrappedValue.sectionEnd) {
            rule.wrappedValue.endTimeLocal = end.endTime
        }
    }

    private func save() {
        notes = []
        errorMessage = nil

        let store = container.store
        let timeZone = container.currentTimeZone
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "课程名不能为空。"
            return
        }
        guard !rules.isEmpty else {
            errorMessage = "至少要有一条每周规则，否则课表里不会出现这节课。"
            return
        }

        let now = Date()
        let nowString = RFC3339.utcString(from: now)
        let courseId = editingCourse?.id ?? ScheduleWritePlanner.courseId(forName: trimmedName)

        let course = CourseRecord(
            id: courseId,
            name: trimmedName,
            teacher: teacher.trimmingCharacters(in: .whitespaces).isEmpty ? nil : teacher,
            location: location.trimmingCharacters(in: .whitespaces).isEmpty ? nil : location,
            term: term.trimmingCharacters(in: .whitespaces).isEmpty ? nil : term,
            color: colorHex,
            followUpEnabled: followUpEnabled,
            followUpDelayMinutes: FollowUpScheduler.clampDelay(followUpDelayMinutes),
            createdAt: editingCourse?.createdAt ?? nowString,
            updatedAt: nowString
        )

        let preparedRules: [CourseScheduleRule] = rules.map { editable in
            // 已有规则保留原 ID（created_at 不变）；新增规则用确定性 ID，重复保存不会长出重复行。
            let ruleId = editable.ruleId ?? ScheduleWritePlanner.ruleId(
                courseId: courseId,
                weekday: editable.weekday,
                sectionStart: editable.sectionStart,
                sectionEnd: editable.sectionEnd,
                weekParity: editable.weekParity,
                weekStart: editable.weekStart,
                weekEnd: editable.weekEnd
            )
            return CourseScheduleRule(
                id: ruleId,
                courseId: courseId,
                weekday: editable.weekday,
                sectionStart: editable.sectionStart,
                sectionEnd: editable.sectionEnd,
                startTimeLocal: editable.startTimeLocal,
                endTimeLocal: editable.endTimeLocal,
                weekParity: editable.weekParity,
                weekStart: editable.weekStart,
                weekEnd: editable.weekEnd,
                effectiveFrom: editable.effectiveRangeEnabled
                    ? RFC3339.localDateString(from: editable.effectiveFrom, timeZone: timeZone)
                    : nil,
                effectiveTo: editable.effectiveRangeEnabled
                    ? RFC3339.localDateString(from: editable.effectiveTo, timeZone: timeZone)
                    : nil,
                createdAt: nowString,
                updatedAt: nowString
            )
        }

        do {
            _ = try store.saveCourseWithRules(course, rules: preparedRules)
            notes.append("课程与每周规则已保存。")

            var anchor: CourseTermAnchor?
            if anchorIsSet {
                let built = CourseTermAnchor(
                    firstWeekMondayLocalDate: RFC3339.localDateString(from: anchorMonday, timeZone: timeZone),
                    timeZoneIdentifier: timeZone.identifier,
                    term: course.term
                )
                try store.setCourseTermAnchor(built)
                anchor = built
                notes.append("学期第 1 周周一已设为 \(built.firstWeekMondayLocalDate)。")
            } else {
                anchor = store.courseTermAnchor()
            }

            if followUpEnabled && expandAfterSave, let anchor {
                try expand(course: course, rules: preparedRules, anchor: anchor, timeZone: timeZone, now: now)
            } else if followUpEnabled && !expandAfterSave {
                notes.append("这次没有展开课程实例，课后追问暂时不会产生。")
            } else if followUpEnabled && anchor == nil {
                notes.append("还没有学期第 1 周周一，暂时不会生成课程实例，也就不会排课后追问。")
            }

            onSaved()
        } catch {
            errorMessage = "保存失败：\(error)"
        }
    }

    private func expand(
        course: CourseRecord,
        rules: [CourseScheduleRule],
        anchor: CourseTermAnchor,
        timeZone: TimeZone,
        now: Date
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let firstMonday = CourseInstanceExpander.startOfLocalDay(
                localDate: anchor.firstWeekMondayLocalDate,
                timeZone: timeZone
            ),
              let end = calendar.date(byAdding: .day, value: 20 * 7, to: firstMonday) else {
            notes.append("学期锚点无法解析，没有展开课程实例。")
            return
        }

        // 区间右端开：第 20 周周日 23:59:59 为止。
        let outcome = try container.store.expandAndPersistCourse(
            courseId: course.id,
            rules: rules,
            anchor: anchor,
            rangeStart: firstMonday,
            rangeEnd: end.addingTimeInterval(-1),
            timeZone: timeZone,
            now: now
        )
        notes.append("已生成 \(outcome.created.count) 个课程实例；\(outcome.preserved.count) 个已存在的实例保持原样（停课 / 调课不会被覆盖）。")
        notes.append(contentsOf: outcome.warnings)
    }
}

// MARK: - 可编辑的规则

/// 编辑器里的规则草稿。
///
/// ruleId 与 localId 分开：localId 只用于 SwiftUI 的列表身份，
/// ruleId 才是库里那一行。分开之后，「改一条已有规则」不会因为 ID 变化而丢掉 created_at。
private struct EditableRule: Identifiable, Equatable {

    let localId: String
    var ruleId: String?
    var weekday: Int
    var sectionStart: Int
    var sectionEnd: Int
    var weekParity: WeekParity
    var weekStart: Int
    var weekEnd: Int
    var startTimeLocal: String
    var endTimeLocal: String
    var effectiveRangeEnabled: Bool
    var effectiveFrom: Date
    var effectiveTo: Date

    var id: String { localId }

    init(rule: CourseScheduleRule, timeZone: TimeZone) {
        self.localId = DayCueID.new()
        self.ruleId = rule.id
        self.weekday = rule.weekday
        self.sectionStart = rule.sectionStart
        self.sectionEnd = rule.sectionEnd
        self.weekParity = rule.weekParity
        self.weekStart = rule.weekStart
        self.weekEnd = rule.weekEnd
        self.startTimeLocal = rule.startTimeLocal
        self.endTimeLocal = rule.endTimeLocal

        if let from = rule.effectiveFrom, let date = RFC3339.date(fromLocal: from, timeZone: timeZone) {
            self.effectiveRangeEnabled = true
            self.effectiveFrom = date
        } else {
            self.effectiveRangeEnabled = false
            self.effectiveFrom = Date()
        }
        if let to = rule.effectiveTo, let date = RFC3339.date(fromLocal: to, timeZone: timeZone) {
            self.effectiveTo = date
        } else {
            self.effectiveTo = Date()
        }
    }

    /// 新规则：默认周一第 1-2 节、每周、1-16 周，时间是标准作息表里的 1-2 节。
    static func new(timeZone: TimeZone) -> EditableRule {
        EditableRule(
            localId: DayCueID.new(),
            ruleId: nil,
            weekday: 1,
            sectionStart: 1,
            sectionEnd: 2,
            weekParity: .all,
            weekStart: 1,
            weekEnd: 16,
            startTimeLocal: CourseSectionTimetable.time(forSection: 1)?.startTime ?? "08:00",
            endTimeLocal: CourseSectionTimetable.time(forSection: 2)?.endTime ?? "09:40",
            effectiveRangeEnabled: false,
            effectiveFrom: Date(),
            effectiveTo: Date()
        )
    }
}
