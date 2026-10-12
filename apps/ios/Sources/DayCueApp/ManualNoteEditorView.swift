import SwiftUI
import DayCueCore

/// 手动新建笔记。
///
/// 存在的意义：笔记列表过去只展示、不提供新建入口，用户想手记一条就只能先录一段音、
/// 等解析。这里补上入口，但**不破坏「来源必须可追溯」**：
/// 落库时 originKind 固定 .manual，且不写任何 originCaptureId / originItemId
/// 去假装它来自某条记录。界面上「来源」会如实显示「手动创建」。
struct ManualNoteEditorView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var titleDraft = ""
    @State private var bodyDraft = ""
    @State private var tagsDraft = ""
    @State private var courseHintDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
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
                }

                Section {
                    TextField("每行一个标签", text: $tagsDraft, axis: .vertical)
                } header: {
                    Text("标签")
                } footer: {
                    Text("标签可以换行或逗号分隔；保存时会自动去掉空项与重复项。")
                        .font(.caption)
                }

                Section {
                    TextField("可选，例如课程名", text: $courseHintDraft)
                } header: {
                    Text("课程提示")
                }

                Section {
                    LabeledContent("来源", value: NoteOriginKind.manual.displayName)
                } footer: {
                    Text("手动创建的笔记来源就写「手动创建」，不会伪装成解析结果；之后一次也能在列表里看到这个标识。")
                        .font(.caption)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("新建笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    /// 标题与正文至少有一个非空才允许保存。
    /// 与 NoteWriteCoordinator 的 emptyContent 规则一致，界面上先拦一道只是为了让按钮状态可见。
    private var canSave: Bool {
        !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        do {
            _ = try container.noteWrite.createManualNote(
                title: titleDraft,
                body: bodyDraft,
                tags: NoteTagCodec.parseInput(tagsDraft),
                courseHint: courseHintDraft
            )
            // 写入成功才关闭。失败时会留在本页并把错误显示出来，
            // 不让用户以为「点了保存就存好了」。
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error)"
        }
    }
}
