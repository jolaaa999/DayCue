import SwiftUI
import DayCueCore

/// 笔记详情。
///
/// 三件事：看完整正文、编辑（并把 userEdited 置上）、软删除。
/// 「置 userEdited」不是可选的装饰：重试解析按这个标志决定是否覆盖正文，
/// 少置一次，用户刚改完的字下一次解析就没了。
///
/// 编辑与删除都不直接调 store，而是走 NoteWriteCoordinator：它在写入成功后
/// 统一通知云同步，手动笔记与 AI 笔记因此走同一条「写完就入队」的路径。
struct NoteDetailView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let noteId: String

    @State private var note: NoteRecord?
    @State private var titleDraft = ""
    @State private var bodyDraft = ""
    @State private var tagsDraft = ""
    @State private var loadError: String?
    @State private var actionMessage: String?
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let actionMessage {
                Section {
                    Text(actionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let note {
                editorSections(note)
            } else if loadError == nil {
                Section {
                    EmptyStateView(
                        systemImage: "note.text.badge.minus",
                        title: "这条笔记已不存在",
                        message: "它可能已经被删除。返回列表可以看到仍然保存在本机的其他笔记。"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("笔记详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 只在首次进入时装载：从来源记录页返回时不重载，
            // 否则未保存的编辑会被静默丢弃。
            if note == nil { load() }
        }
        .confirmationDialog(
            "删除这条笔记？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后它不会再出现在笔记列表和搜索结果里。本机仍保留这一行数据，方便日后对账。")
        }
    }

    // MARK: - 编辑区

    private func editorSections(_ note: NoteRecord) -> some View {
        Group {
            Section {
                TextField("标题", text: $titleDraft, axis: .vertical)
                    .font(.headline)
            } header: {
                Text("标题")
            }

            Section {
                TextEditor(text: $bodyDraft)
                    .frame(minHeight: 160)
                    .font(.body)
            } header: {
                Text("正文")
            } footer: {
                Text("保存后这条笔记会被标记为「已编辑」，之后的解析重试不会再覆盖它。")
                    .font(.caption)
            }

            Section {
                TextField("每行一个标签", text: $tagsDraft, axis: .vertical)
            } header: {
                Text("标签")
            } footer: {
                Text("标签可以换行或逗号分隔；保存时会自动去掉空项与重复项。")
                    .font(.caption)
            }

            sourceSection(note)

            Section {
                Button("保存修改") { save(note) }
                    .disabled(!hasChanges(note))
                Button("删除这条笔记", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("删除是软删除：不再出现在任何列表里，但数据仍在本机。")
                    .font(.caption)
            }
        }
    }

    private func sourceSection(_ note: NoteRecord) -> some View {
        Section {
            LabeledContent("来源", value: NoteDisplay.sourceText(note))

            // 来源可以跳转：用户看到一条记不清出处的笔记时，
            // 最快的确认方式就是回到那条原始记录读原文。
            if let captureId = note.originCaptureId {
                NavigationLink("查看原始记录") {
                    CaptureDetailView(captureId: captureId)
                }
            } else if note.originKind == .manual {
                // 手动创建的笔记没有来源记录可跳。把这件事说明白，
                // 比留一个点不动的空位更符合「来源可追溯」。
                Text("这条笔记是手动创建的，没有原始记录可跳转。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("创建时间", value: RecordDisplay.utcText(note.createdAt))

            if let occurredAt = note.occurredAt, !occurredAt.isEmpty {
                LabeledContent("发生时间", value: RecordDisplay.utcText(occurredAt))
            }

            if note.userEdited {
                Label("你编辑过这条笔记", systemImage: "pencil")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("来源")
        }
    }

    // MARK: - 数据

    private func load() {
        do {
            guard let loaded = try container.store.note(id: noteId) else {
                // 查询成功但没有这一行 = 已被删除/不存在，与读库失败是两件事，
                // 所以这里不设 loadError，让界面显示「已不存在」。
                note = nil
                loadError = nil
                return
            }
            note = loaded
            titleDraft = loaded.title
            bodyDraft = loaded.body
            tagsDraft = loaded.tags.joined(separator: "\n")
            loadError = nil
        } catch {
            note = nil
            loadError = "读取这条笔记失败：\(error)"
        }
    }

    /// 切分与归一化都交给 NoteTagCodec：输入框允许逗号只是为了打字方便，
    /// 存储格式（换行分隔）始终只有一个实现，视图里不重复写第二遍。
    private var parsedTags: [String] {
        NoteTagCodec.parseInput(tagsDraft)
    }

    private func hasChanges(_ note: NoteRecord) -> Bool {
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.title != trimmedTitle
            || note.body != bodyDraft
            || NoteTagCodec.normalize(note.tags) != parsedTags
    }

    private func save(_ existing: NoteRecord) {
        do {
            // 走 NoteWriteCoordinator：它在同一次写入里置好 userEdited、
            // 并且只在写成功之后通知云同步。之前这里只写库不通知，
            // 改过的笔记要等别处恰好有变更才会被推上去。
            let saved = try container.noteWrite.updateNoteContent(
                id: existing.id,
                title: titleDraft,
                body: bodyDraft,
                tags: parsedTags
            )
            note = saved
            titleDraft = saved.title
            bodyDraft = saved.body
            tagsDraft = saved.tags.joined(separator: "\n")
            actionMessage = "已保存。这条笔记不会再被解析重试覆盖。"
        } catch {
            actionMessage = "保存失败：\(error)"
        }
    }

    private func performDelete() {
        do {
            // 软删除与云同步通知都在协调器里：写失败会抛到这里，
            // 不会出现"宣称删掉了/入队了，其实没写成"。
            try container.noteWrite.deleteNote(id: noteId)
            dismiss()
        } catch {
            actionMessage = "删除失败：\(error)"
        }
    }
}
