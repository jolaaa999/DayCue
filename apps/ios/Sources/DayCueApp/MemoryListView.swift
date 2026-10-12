import SwiftUI
import DayCueCore

/// 长期记忆列表。
///
/// 两件事必须一眼看清，否则用户会把推断当成事实：
/// 1. 来源徽标（用户设置 / 用户说过 / 推断），其中「推断」用虚线边框 + 橙色，与其它两种明显不同。
/// 2. 状态徽标（候选 / 已确认 / 有冲突 / 已失效）。
struct MemoryListView: View {

    @EnvironmentObject private var container: AppContainer

    @State private var memories: [MemoryItem] = []
    @State private var facts: [MemorySearchHit] = []
    @State private var references: [MemorySearchHit] = []
    @State private var searchText = ""
    @State private var searchNotes: [String] = []
    @State private var isSearching = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !searchNotes.isEmpty {
                Section {
                    ForEach(searchNotes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if memories.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "brain",
                        title: emptyTitle,
                        message: emptyMessage
                    )
                }
            } else if isSearching {
                searchResultSections
            } else {
                categorySections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("长期记忆")
        .searchable(text: $searchText, prompt: "搜索你说过的事（本机关键词）")
        .onChange(of: searchText) { _, _ in reload() }
        // 用 onAppear 而不是 task：从详情页返回时要重新读库，
        // 否则刚确认或刚删掉的记忆会继续留在列表里。
        .onAppear { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MemorySettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("记忆设置")
            }
        }
    }

    // MARK: - 分区

    @ViewBuilder
    private var categorySections: some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.items) { item in
                    NavigationLink {
                        MemoryDetailView(memoryId: item.id)
                    } label: {
                        MemoryRow(item: item)
                    }
                }
            } header: {
                HStack {
                    Text(group.category.displayName)
                    Spacer()
                    Text("\(group.items.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if group.category.isSingleValued {
                    Text("「\(group.category.displayName)」在现实里只可能有一个当前值，出现第二种说法会被标成「有冲突」，等你决定。")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultSections: some View {
        if !facts.isEmpty {
            Section {
                ForEach(facts) { hit in
                    NavigationLink {
                        MemoryDetailView(memoryId: hit.id)
                    } label: {
                        MemoryRow(item: hit.item)
                    }
                }
            } header: {
                Text("能当事实用的（已确认）")
            } footer: {
                Text("这些是你确认过的内容。分数只表示和关键词的匹配程度，不代表重要程度。")
                    .font(.caption)
            }
        }

        if !references.isEmpty {
            Section {
                ForEach(references) { hit in
                    NavigationLink {
                        MemoryDetailView(memoryId: hit.id)
                    } label: {
                        MemoryRow(item: hit.item)
                    }
                }
            } header: {
                Text("仅供参考（候选 / 冲突 / 已失效）")
            } footer: {
                Text("这些**不能**当作事实使用。推断出来的候选需要你确认之后才算数。")
                    .font(.caption)
            }
        }
    }

    // MARK: - 数据

    private struct CategoryGroup: Identifiable {
        var category: MemoryCategory
        var items: [MemoryItem]
        var id: String { category.rawValue }
    }

    private var groups: [CategoryGroup] {
        MemoryCategory.allCases.compactMap { category in
            let items = memories.filter { $0.category == category }
            guard !items.isEmpty else { return nil }
            return CategoryGroup(category: category, items: items)
        }
    }

    private var emptyTitle: String {
        isSearching ? "没有匹配的记忆" : "还没有长期记忆"
    }

    private var emptyMessage: String {
        if isSearching {
            return "换个关键词试试。搜索完全在本机完成，不联网、也不上传任何内容。"
        }
        return "DayCue 不会自动把你说过的每句话都记成事实。等你在记录里确认过内容，或者自己在详情的记忆页里添加之后，才会出现在这里。"
    }

    private func reload() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if keyword.isEmpty {
                isSearching = false
                facts = []
                references = []
                searchNotes = []
                memories = try container.store.memories()
            } else {
                isSearching = true
                let engine = MemorySearchEngine(store: container.store)
                let result = try engine.search(MemorySearchQuery(
                    text: keyword,
                    now: Date(),
                    timeZone: container.currentTimeZone,
                    limit: 100
                ))
                facts = result.facts
                references = result.references
                searchNotes = result.notes
                memories = result.allHits.map(\.item)
            }
            loadError = nil
        } catch {
            // 读库失败时清空列表并说明，而不是显示旧数据让用户以为是当前内容。
            memories = []
            facts = []
            references = []
            searchNotes = []
            loadError = "读取本机记忆失败：\(error)"
        }
    }
}

/// 来源徽标。推断必须视觉可区分：虚线边框 + 橙色 + 问号。
struct MemorySourceBadge: View {

    let kind: MemorySourceKind

    var body: some View {
        HStack(spacing: 3) {
            if kind == .inferred {
                Image(systemName: "questionmark.circle")
            }
            Text(kind.displayName)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(badgeBackground)
        .accessibilityLabel(kind == .inferred ? "来源：推断，未确认" : "来源：" + kind.displayName)
    }

    @ViewBuilder
    private var badgeBackground: some View {
        if kind == .inferred {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(tint.opacity(0.14))
        }
    }

    private var tint: Color {
        switch kind {
        case .userSetting: return .blue
        case .userStatement: return .green
        case .inferred: return .orange
        }
    }
}

/// 状态徽标。
struct MemoryStatusBadge: View {

    let status: MemoryStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .confirmed: return .green
        case .candidate: return .orange
        case .conflict: return .red
        case .retired: return .gray
        }
    }
}

/// 单条记忆的行。
private struct MemoryRow: View {

    let item: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.statement)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                MemorySourceBadge(kind: item.sourceKind)
                MemoryStatusBadge(status: item.status)
                Spacer()
            }

            Text(effectiveText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var effectiveText: String {
        var parts: [String] = []
        if let from = item.effectiveFrom, !from.isEmpty {
            parts.append("生效自 " + RecordDisplay.utcText(from))
        }
        if let to = item.effectiveTo, !to.isEmpty {
            parts.append("有效到 " + RecordDisplay.utcText(to))
        }
        if parts.isEmpty {
            parts.append("长期有效")
        }
        parts.append("第 \(max(item.revision, 1)) 版")
        return parts.joined(separator: " · ")
    }
}
