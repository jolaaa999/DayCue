import SwiftUI
import DayCueCore

/// 记忆详情。
///
/// 四件事：改说法、确认候选、看历史修订、删除。
/// 「确认候选」必须由用户点，代码里没有任何路径能把推断直接变成事实。
struct MemoryDetailView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let memoryId: String

    @State private var memory: MemoryItem?
    @State private var statementDraft = ""
    @State private var revisions: [MemoryRevisionRecord] = []
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let memory {
                statusSection(memory)
                editorSection(memory)
                sourceSection(memory)
                historySection
                dangerSection
            } else if loadError == nil {
                Section {
                    EmptyStateView(
                        systemImage: "brain",
                        title: "这条记忆已经不在了",
                        message: "它可能已经被删除。返回列表可以看到仍然保存在本机的其它记忆。"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记忆详情")
        .navigationBarTitleDisplayMode(.inline)
        // 只在首次进入时装载：从设置页返回时不重载，避免未保存的编辑被静默丢弃。
        .task {
            if memory == nil { load() }
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后它不会再出现在记忆列表和检索结果里，倒排索引也会一并清掉。你的原始记录和笔记不受影响。")
        }
    }

    // MARK: - 状态

    private func statusSection(_ memory: MemoryItem) -> some View {
        Section {
            HStack(spacing: 8) {
                MemorySourceBadge(kind: memory.sourceKind)
                MemoryStatusBadge(status: memory.status)
                Spacer()
                Text("第 \(max(memory.revision, 1)) 版")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if memory.sourceKind == .inferred {
                Label("这是从你的记录里推断出来的，只有你确认之后才会被当成事实使用。", systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if memory.status == .conflict {
                Label("它和同类别里另一条记忆互相矛盾。DayCue 不会替你选，请你决定保留哪一条。", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if memory.status != .confirmed {
                Button("确认这条记忆是事实") {
                    updateStatus(.confirmed, successText: "已确认。以后它会作为事实出现在检索结果里。")
                }
            }

            if memory.status != .retired {
                Button("标记为已失效") {
                    updateStatus(.retired, successText: "已标记为失效。它不会再被当成当前有效的说法。")
                }
            }
        } header: {
            Text("状态")
        } footer: {
            Text("「已确认」= 可以当事实用；「候选」= 推断出来等你决定；「有冲突」= 和同类别的另一条说法矛盾；「已失效」= 已经不作数但历史保留。")
                .font(.caption)
        }
    }

    // MARK: - 编辑

    /// 这里会连续产出两个 Section，所以必须标 @ViewBuilder。
    @ViewBuilder
    private func editorSection(_ memory: MemoryItem) -> some View {
        Section {
            TextEditor(text: $statementDraft)
                .frame(minHeight: 100)
                .font(.body)
        } header: {
            Text("说法")
        } footer: {
            Text("保存会写入一条新的历史修订，旧说法不会被覆盖——「以前是怎么说的」本身也是有用的信息。")
                .font(.caption)
        }

        Section {
            Button("保存新的说法") { save(memory) }
                .disabled(!hasChanges(memory))
        }
    }

    // MARK: - 来源

    private func sourceSection(_ memory: MemoryItem) -> some View {
        Section {
            LabeledContent("来源", value: memory.sourceKind.displayName)
            if let confidence = memory.confidence {
                LabeledContent("置信度", value: String(format: "%.2f", confidence))
            }
            if let sourceRef = memory.sourceRef, !sourceRef.isEmpty {
                LabeledContent("来源引用", value: sourceRef)
            }
            LabeledContent("创建时间", value: RecordDisplay.utcText(memory.createdAt))
            LabeledContent("最近修改", value: RecordDisplay.utcText(memory.updatedAt))
            if let from = memory.effectiveFrom, !from.isEmpty {
                LabeledContent("生效自", value: RecordDisplay.utcText(from))
            }
            if let to = memory.effectiveTo, !to.isEmpty {
                LabeledContent("有效到", value: RecordDisplay.utcText(to))
            }
        } header: {
            Text("来源与有效期")
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        Section {
            if revisions.isEmpty {
                Text("还没有历史修订。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(revisions) { revision in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("第 \(revision.revision) 版")
                                .font(.caption.weight(.semibold))
                            MemorySourceBadge(kind: revision.sourceKind)
                            Spacer()
                            Text(RecordDisplay.utcText(revision.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(revision.statement)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("历史修订")
        } footer: {
            Text("每一版都保留原样，删除记忆也不会删掉这些修订记录。")
                .font(.caption)
        }
    }

    // MARK: - 删除

    private var dangerSection: some View {
        Section {
            Button("删除这条记忆", role: .destructive) { confirmingDelete = true }
        } footer: {
            Text("删除是软删除：不再出现在列表与检索里，倒排索引会同时清空。原始记录和笔记不受影响，记忆的历史修订仍然保留在本机。")
                .font(.caption)
        }
    }

    // MARK: - 数据

    private func load() {
        do {
            guard let loaded = try container.store.memory(id: memoryId) else {
                // 查询成功但没有这一行 = 已被删除，与读库失败是两件事，
                // 所以这里不设 loadError，让界面显示「已不存在」。
                memory = nil
                revisions = []
                loadError = nil
                return
            }
            memory = loaded
            statementDraft = loaded.statement
            revisions = try container.store.revisions(memoryId: memoryId)
            loadError = nil
        } catch {
            memory = nil
            revisions = []
            loadError = "读取这条记忆失败：\(error)"
        }
    }

    private func hasChanges(_ memory: MemoryItem) -> Bool {
        statementDraft.trimmingCharacters(in: .whitespacesAndNewlines) != memory.statement
    }

    private func save(_ memory: MemoryItem) {
        let trimmed = statementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            actionMessage = "说法不能是空的。"
            return
        }
        do {
            _ = try container.store.updateMemoryStatement(id: memory.id, statement: trimmed, at: Date())
            load()
            actionMessage = "已保存为新的一版。旧说法仍然可以在下面查到。"
        } catch {
            actionMessage = "保存失败：\(error)"
        }
    }

    private func updateStatus(_ status: MemoryStatus, successText: String) {
        do {
            try container.store.setMemoryStatus(id: memoryId, status: status, at: Date())
            load()
            actionMessage = successText
        } catch {
            actionMessage = "更新状态失败：\(error)"
        }
    }

    private func performDelete() {
        do {
            try container.store.softDeleteMemory(id: memoryId, at: Date())
            dismiss()
        } catch {
            actionMessage = "删除失败：\(error)"
        }
    }
}
