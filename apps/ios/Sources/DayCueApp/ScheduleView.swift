import SwiftUI
import DayCueCore

/// 课表页：一周的「星期 × 节次」视图。
///
/// 格子里的时间是**纸面作息**：预计结束时间只用于排版和提前排本地通知，
/// 它不等于实际下课，也不代表出席。这条限制必须出现在界面上，
/// 否则用户会把课表块当成「已经上过这节课」。
///
/// 导航由外层负责：本视图不自带 NavigationStack，既可以 push 也可以放进 sheet。
struct ScheduleView: View {

    @EnvironmentObject private var container: AppContainer
    @StateObject private var model = ScheduleViewModel()

    var body: some View {
        List {
            weekHeaderSection
            gridSection
            floatingSection
            conflictSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("课表")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.moveWeek(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("上一周")

                Button("本周") {
                    model.moveWeekToNow()
                }
                .font(.subheadline)

                Button {
                    model.moveWeek(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("下一周")

                Menu {
                    Button {
                        model.showCourseEditor = true
                    } label: {
                        Label("手动添加课程", systemImage: "plus")
                    }
                    Button {
                        model.showImport = true
                    } label: {
                        Label("导入课表（图片 / ICS）", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        model.showFollowUps = true
                    } label: {
                        Label("课后追问", systemImage: "bubble.left.and.text.bubble.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
            }
        }
        .task {
            model.attach(container)
            model.reload()
        }
        .refreshable {
            model.reload()
        }
        .sheet(isPresented: $model.showCourseEditor) {
            CourseEditorView(course: nil, rules: []) {
                model.reload()
            }
        }
        .sheet(isPresented: $model.showImport) {
            ScheduleImportView {
                model.reload()
            }
        }
        .sheet(isPresented: $model.showFollowUps) {
            FollowUpView()
        }
        .sheet(item: $model.selectedInstance) { instance in
            CourseInstanceDetailView(instance: instance) {
                model.reload()
            }
        }
    }

    // MARK: - 周标题

    private var weekHeaderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.weekTitle)
                    .font(.headline)
                Text(model.weekDateRangeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            ForEach(model.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Text("格子里的时间是课表预计时间，只用来提前排本地通知。预计下课不等于实际下课，也不代表你出席了这节课。")
                .font(.caption)
        }
    }

    // MARK: - 周视图

    @ViewBuilder
    private var gridSection: some View {
        if model.hasAnyCourse {
            Section {
                ScheduleGrid(
                    layout: model.layout,
                    sectionCount: ScheduleViewModel.sectionCount,
                    rowHeight: ScheduleViewModel.rowHeight,
                    dayColumnWidth: ScheduleViewModel.dayColumnWidth,
                    sectionLabel: { model.sectionLabel($0) },
                    onSelect: { model.selectedInstance = $0 }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: {
                Text("本周课表")
            }
        } else {
            Section {
                EmptyStateView(
                    systemImage: "calendar",
                    title: "这学期还没有课表",
                    message: "点右上角「…」里的「手动添加课程」，或用「导入课表」把课表照片和 ICS 文件变成课程。导入的内容必须由你逐条确认后才会写入。"
                )
            }
        }
    }

    // MARK: - 落不进作息的课

    @ViewBuilder
    private var floatingSection: some View {
        if !model.layout.floatingCells.isEmpty {
            Section {
                ForEach(model.layout.floatingCells) { cell in
                    Button {
                        model.selectedInstance = cell.instance
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cell.courseName)
                                .font(.subheadline.weight(.medium))
                            Text("\(dayText(cell)) \(cell.startClock)–\(cell.endClock)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("这个时间落在默认作息表之外，所以没有画进格子。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("作息外的课")
            }
        }
    }

    // MARK: - 时间冲突

    @ViewBuilder
    private var conflictSection: some View {
        if !model.layout.conflictingCells.isEmpty {
            Section {
                ForEach(model.layout.conflictingCells) { cell in
                    Button {
                        model.selectedInstance = cell.instance
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cell.courseName)
                                .font(.subheadline.weight(.medium))
                            Text("\(dayText(cell)) \(cell.startClock)–\(cell.endClock)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("时间冲突")
            } footer: {
                Text("这些课与同一时段的其他课重叠，没有画进格子。上课时间以老师通知为准。")
                    .font(.caption)
            }
        }
    }
}

private extension ScheduleView {
    /// 星期文案。星期无法确定时如实说「星期未知」，不猜一个。
    func dayText(_ cell: ScheduleCell) -> String {
        guard let weekday = cell.weekday else { return "星期未知" }
        return ScheduleOCRMapping.weekdayName(weekday)
    }
}

// MARK: - 单个格子

/// 课表里的一个课程块。颜色只用于区分课程，不代表任何优先级。
private struct CourseBlockCell: View {

    let block: ScheduleWeekLayout.Block
    let sectionLabel: (Int, Int) -> String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.cell.courseName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(sectionLabel(block.startRow, block.startRow + block.rowSpan - 1))
                    .font(.caption2)
                if let location = block.cell.location, !location.isEmpty {
                    Text(location)
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if block.cell.isCancelled {
                    Text("停课")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                Color.dayCue(hex: block.cell.colorHex).opacity(block.cell.isCancelled ? 0.12 : 0.22),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.dayCue(hex: block.cell.colorHex).opacity(block.cell.isCancelled ? 0.3 : 0.7),
                        lineWidth: 1
                    )
            }
            .padding(2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(block.cell.courseName)，\(sectionLabel(block.startRow, block.startRow + block.rowSpan - 1))")
    }
}

// MARK: - 周网格

private struct ScheduleGrid: View {

    let layout: ScheduleWeekLayout
    let sectionCount: Int
    let rowHeight: CGFloat
    let dayColumnWidth: CGFloat
    let sectionLabel: (Int) -> String
    let onSelect: (CourseInstanceRecord) -> Void

    var body: some View {
        // 纵向由外层 List 滚动，这里只做横向滚动：
        // 嵌套两层滚动视图在小屏上很容易出现「内容被裁掉」的假象，能不做就不做。
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                headerRow
                gridRows
            }
        }
        .frame(height: headerHeight + CGFloat(sectionCount) * rowHeight)
    }

    private var headerHeight: CGFloat { 26 }

    private var blockIndex: [String: ScheduleWeekLayout.Block] {
        var index: [String: ScheduleWeekLayout.Block] = [:]
        for block in layout.blocks {
            index["\(block.weekday)-\(block.startRow)"] = block
        }
        return index
    }

    private var coveredIndex: Set<String> {
        var covered = Set<String>()
        for block in layout.blocks {
            for row in block.startRow..<(block.startRow + block.rowSpan) {
                covered.insert("\(block.weekday)-\(row)")
            }
        }
        return covered
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("节")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: headerHeight)
            ForEach(1...7, id: \.self) { weekday in
                Text(ScheduleOCRMapping.weekdayName(weekday))
                    .font(.caption.weight(.semibold))
                    .frame(width: dayColumnWidth, height: headerHeight)
            }
        }
    }

    private var gridRows: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 0) {
                ForEach(1...sectionCount, id: \.self) { row in
                    Text(sectionLabel(row))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: rowHeight)
                }
            }

            ForEach(1...7, id: \.self) { weekday in
                VStack(spacing: 0) {
                    ForEach(1...sectionCount, id: \.self) { row in
                        if let block = blockIndex["\(weekday)-\(row)"] {
                            CourseBlockCell(
                                block: block,
                                sectionLabel: { start, end in
                                    start == end ? "第 \(start) 节" : "第 \(start)-\(end) 节"
                                },
                                onTap: { onSelect(block.cell.instance) }
                            )
                            .frame(height: CGFloat(block.rowSpan) * rowHeight)
                        } else if coveredIndex.contains("\(weekday)-\(row)") {
                            // 被上面跨节的课盖住的行：留 0 高度，块的总高度才不会和行高错位。
                            Color.clear.frame(height: 0)
                        } else {
                            Color.secondary.opacity(0.06)
                                .frame(height: rowHeight - 4)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(.vertical, 2)
                        }
                    }
                }
                .frame(width: dayColumnWidth)
            }
        }
    }
}

// MARK: - 单次课详情

/// 一次课的信息与操作。停课 / 恢复都直接落在 course_instance.status 上，
/// 重新展开课表时不会把用户的这个决定覆盖掉。
private struct CourseInstanceDetailView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let instance: CourseInstanceRecord
    let onChanged: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("课程", value: courseName)
                    LabeledContent("状态", value: instance.status.displayName)
                    LabeledContent("星期", value: weekday.map { ScheduleOCRMapping.weekdayName($0) } ?? "星期未知")
                    LabeledContent("时间", value: "\(startText) – \(endText)")
                    if let location = instance.location, !location.isEmpty {
                        LabeledContent("地点", value: location)
                    }
                    LabeledContent("来源", value: instance.origin.displayName)
                }

                if let note = instance.note, !note.isEmpty {
                    Section {
                        Text(note)
                            .font(.footnote)
                    } header: {
                        Text("备注")
                    }
                }

                Section {
                    if instance.status == .cancelled {
                        Button("恢复为正常") { setStatus(.scheduled) }
                    } else {
                        Button("标记为停课") { setStatus(.cancelled) }
                    }
                } footer: {
                    Text("这里的「预计结束时间」只用于提前排本地通知。它不等于实际下课，也不代表你出席了这节课，更不会被当成出勤记录。")
                        .font(.caption)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("课程详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var courseName: String {
        ((try? container.store.course(id: instance.courseId)) ?? nil)?.name ?? "未知课程"
    }

    private var weekday: Int? {
        CourseGridPlacement.weekday(of: instance, timeZone: container.currentTimeZone)
    }

    private var startText: String {
        CourseGridPlacement.startClock(of: instance, timeZone: container.currentTimeZone) ?? "时间未知"
    }

    private var endText: String {
        CourseGridPlacement.endClock(of: instance, timeZone: container.currentTimeZone) ?? "时间未知"
    }

    private func setStatus(_ status: CourseInstanceStatus) {
        do {
            try container.store.setInstanceStatus(id: instance.id, status: status)
            onChanged()
            dismiss()
        } catch {
            errorMessage = "修改失败：\(error)"
        }
    }
}

// MARK: - 视图模型

/// 一次课的排版结果。视图只读它，不再自己算时区。
struct ScheduleCell: Identifiable, Equatable {
    let id: String
    let instance: CourseInstanceRecord
    let courseName: String
    let colorHex: String?
    /// nil 表示这个实例的星期无法确定（时间串坏掉）。它会被列进「作息外」而不是硬塞到周一。
    let weekday: Int?
    let startClock: String
    let endClock: String
    let sectionRange: ClosedRange<Int>?
    let isCancelled: Bool
    let location: String?
    let note: String?
}

/// 把实例排进「星期 × 节次」格子的纯函数结果。
struct ScheduleWeekLayout: Equatable {

    struct Block: Identifiable, Equatable {
        let id: String
        let cell: ScheduleCell
        /// 已解析出的星期（1...7），画格子时不需要再判空。
        let weekday: Int
        let startRow: Int
        let rowSpan: Int
    }

    var blocks: [Block] = []
    /// 落不进任何节次的课（例如作息表对不上）。不硬塞位置，单独列出来。
    var floatingCells: [ScheduleCell] = []
    /// 与同一时段其它课重叠的课。不重叠着画，单独列出来。
    var conflictingCells: [ScheduleCell] = []

    /// 纯函数：给定一批实例，算出每个块的行号与跨行数。
    static func layout(cells: [ScheduleCell], sectionCount: Int) -> ScheduleWeekLayout {
        var result = ScheduleWeekLayout()

        // 星期无法确定的实例直接列为「作息外」：宁可让用户看到它，也不要画到错误的那一天。
        for cell in cells where cell.weekday == nil {
            result.floatingCells.append(cell)
        }

        for weekday in 1...7 {
            let dayCells = cells
                .filter { $0.weekday == weekday }
                .sorted { lhs, rhs in
                    let left = lhs.sectionRange?.lowerBound ?? Int.max
                    let right = rhs.sectionRange?.lowerBound ?? Int.max
                    if left != right { return left < right }
                    return lhs.id < rhs.id
                }

            var occupied = Set<Int>()
            for cell in dayCells {
                guard let range = cell.sectionRange else {
                    result.floatingCells.append(cell)
                    continue
                }
                let start = max(1, range.lowerBound)
                let end = min(sectionCount, range.upperBound)
                guard start <= end else {
                    result.floatingCells.append(cell)
                    continue
                }
                if (start...end).contains(where: { occupied.contains($0) }) {
                    result.conflictingCells.append(cell)
                    continue
                }
                for row in start...end { occupied.insert(row) }
                result.blocks.append(Block(
                    id: cell.id,
                    cell: cell,
                    weekday: weekday,
                    startRow: start,
                    rowSpan: end - start + 1
                ))
            }
        }

        return result
    }
}

@MainActor
final class ScheduleViewModel: ObservableObject {

    static let sectionCount = CourseSectionTimetable.standard.count
    static let rowHeight: CGFloat = 58
    static let dayColumnWidth: CGFloat = 108

    @Published private(set) var weekStart: Date = Date()
    @Published private(set) var weekEnd: Date = Date()
    @Published private(set) var layout = ScheduleWeekLayout()
    @Published private(set) var hasAnyCourse = false
    @Published private(set) var warnings: [String] = []
    @Published private(set) var anchor: CourseTermAnchor?
    @Published private(set) var weekIndex: Int?

    @Published var selectedInstance: CourseInstanceRecord?
    @Published var showCourseEditor = false
    @Published var showImport = false
    @Published var showFollowUps = false

    private var container: AppContainer?
    private var timeZone: TimeZone = .current

    func attach(_ container: AppContainer) {
        self.container = container
    }

    func moveWeek(by weeks: Int) {
        let calendar = Calendar.current
        if let moved = calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) {
            weekStart = moved
            reload()
        }
    }

    func moveWeekToNow() {
        weekStart = Date()
        reload()
    }

    /// 节次标签。作息表里定义的节次用它的起止时间，没定义的只显示节号。
    func sectionLabel(_ section: Int) -> String {
        guard let time = CourseSectionTimetable.time(forSection: section) else { return "\(section)" }
        return "\(section)\n\(time.startTime)"
    }

    func reload() {
        guard let container else { return }
        let store = container.store
        timeZone = container.currentTimeZone

        warnings = []
        anchor = store.courseTermAnchor()
        if anchor == nil {
            warnings.append("还没有设置学期第 1 周周一。单双周和节次排布都要靠它，请到课程编辑器里设置后再展开课表。")
        }

        let courses = (try? store.courses()) ?? []
        var coursesById: [String: CourseRecord] = [:]
        for course in courses { coursesById[course.id] = course }
        hasAnyCourse = !courses.isEmpty

        guard let range = CourseInstanceExpander.weekRange(containing: weekStart, timeZone: timeZone) else {
            layout = ScheduleWeekLayout()
            return
        }
        weekStart = range.start
        weekEnd = range.end

        if let anchor {
            weekIndex = CourseInstanceExpander.weekIndex(
                localDate: CourseInstanceExpander.localDateString(range.start, timeZone: timeZone),
                anchor: anchor,
                timeZone: timeZone
            )
        } else {
            weekIndex = nil
        }

        // 区间右端开：下周一 00:00 开始的课属于下一周。
        let loaded = (try? store.instances(from: range.start, to: range.end.addingTimeInterval(-1))) ?? []
        let cells = loaded.map { makeCell($0, coursesById: coursesById) }
        layout = ScheduleWeekLayout.layout(cells: cells, sectionCount: Self.sectionCount)
    }

    var weekTitle: String {
        if let weekIndex { return "第 \(weekIndex) 周" }
        return "未设置学期周次"
    }

    var weekDateRangeText: String {
        let start = RFC3339.localDateString(from: weekStart, timeZone: timeZone)
        let end = RFC3339.localDateString(from: weekEnd.addingTimeInterval(-1), timeZone: timeZone)
        return start + " 至 " + end
    }

    private func makeCell(_ instance: CourseInstanceRecord, coursesById: [String: CourseRecord]) -> ScheduleCell {
        let course = coursesById[instance.courseId]
        let weekday = CourseGridPlacement.weekday(of: instance, timeZone: timeZone)
        let startClock = CourseGridPlacement.startClock(of: instance, timeZone: timeZone) ?? ""
        let endClock = CourseGridPlacement.endClock(of: instance, timeZone: timeZone) ?? ""
        let sectionRange = CourseGridPlacement.sectionRange(startClock: startClock, endClock: endClock)
        return ScheduleCell(
            id: instance.id,
            instance: instance,
            courseName: course?.name ?? "未知课程",
            colorHex: course?.color,
            weekday: weekday,
            startClock: startClock.isEmpty ? "时间未知" : startClock,
            endClock: endClock.isEmpty ? "时间未知" : endClock,
            sectionRange: sectionRange,
            isCancelled: instance.status == .cancelled,
            location: instance.location ?? course?.location,
            note: instance.note
        )
    }
}

// MARK: - 颜色

extension Color {
    /// 把 "#RRGGBB" 解析成颜色。解析失败退回强调色：一个坏色值不该让课程块消失。
    ///
    /// 不是 private：课程编辑器的色板也要用同一套解析，色值口径只能有一处。
    static func dayCue(hex: String?) -> Color {
        guard let hex else { return .accentColor }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = Int(value, radix: 16) else { return .accentColor }
        let red = Double((number >> 16) & 0xFF) / 255
        let green = Double((number >> 8) & 0xFF) / 255
        let blue = Double(number & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}
