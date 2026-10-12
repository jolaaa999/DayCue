import SwiftUI
import DayCueCore

/// 笔记列表：浏览、搜索，以及手动新建入口。
///
/// 「来源必须可追溯」（记录 / 课后回复 / 手动 / 记忆）这条原则没有被新建入口破坏：
/// 手动创建的笔记落库时 originKind 固定 .manual，且**不写** originCaptureId /
/// originItemId 去假装它来自某条记录。视图不直接调 store，而是走 NoteWriteCoordinator，
/// 由它保证「写成功之后才通知云同步」。
struct NoteListView: View {

    @EnvironmentObject private var container: AppContainer

    @State private var notes: [NoteRecord] = []
    @State private var searchText = ""
    @State private var loadError: String?
    @State private var showingEditor = false

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if notes.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "note.text",
                        title: emptyTitle,
                        message: emptyMessage
                    )
                }
            } else {
                Section {
                    ForEach(notes) { note in
                        NavigationLink {
                            NoteDetailView(noteId: note.id)
                        } label: {
                            NoteRow(note: note)
                        }
                    }
                } footer: {
                    Text("共 \(notes.count) 条。笔记保存在本机，不联网也能查看。")
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("笔记")
        .searchable(text: $searchText, prompt: "搜索标题、正文或标签")
        .onChange(of: searchText) { _, _ in reload() }
        // 用 onAppear 而不是 task：从详情页返回时要重新读库，
        // 否则刚删掉或刚改过的笔记会继续留在列表里。
        .onAppear { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingEditor = true
                } label: {
                    Label("新建笔记", systemImage: "square.and.pencil")
                }
            }
        }
        // 用 onDismiss 而不是依赖列表的 onAppear：表单收起时列表不一定会重新出现，
        // 新笔记就会"存了却看不到"。
        .sheet(isPresented: $showingEditor, onDismiss: { reload() }) {
            ManualNoteEditorView()
                .environmentObject(container)
        }
    }

    private var emptyTitle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "还没有笔记" : "没有匹配的笔记"
    }

    private var emptyMessage: String {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "笔记保存在本机。点右上角的手写图标可以手动新建一条；也可以在「记录」里说一句话、录一段音或拍张照片，确认后解析出的笔记同样会出现在这里。"
        }
        return "换个关键词试试。搜索会同时匹配标题、正文和标签。"
    }

    private func reload() {
        do {
            let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            // 写成 if/else 而不是三元表达式：三元右侧的 try 在 Swift 里是受限写法，
            // 不值得为少两行去赌一次编译。
            if keyword.isEmpty {
                notes = try container.store.notes()
            } else {
                notes = try container.store.notes(searchText: keyword)
            }
            loadError = nil
        } catch {
            // 读库失败时清空列表并显式说明，而不是显示上一次的旧数据让用户误以为那就是当前的库内容。
            notes = []
            loadError = "读取本机笔记失败：\(error)"
        }
    }
}

/// 单条笔记的行。
private struct NoteRow: View {

    let note: NoteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title.isEmpty ? "（无标题）" : note.title)
                .font(.body)
                .lineLimit(1)

            Text(NoteDisplay.summaryText(note))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(NoteDisplay.sourceText(note))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                if note.userEdited {
                    Text("已编辑")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Spacer()
            }

            Text(NoteDisplay.timeText(note))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
