import SwiftUI
import DayCueCore

/// 记忆设置。
///
/// 两件事：按类别停止记录、一键清除。
/// 「停止记录」只影响之后的新记忆，已经保存的不会被顺手删掉——那是两个不同的动作，
/// 混在一起会让用户不敢碰开关。
struct MemorySettingsView: View {

    @EnvironmentObject private var container: AppContainer

    @State private var snapshot: [MemoryCategory: Bool] = [:]
    @State private var totalCount = 0
    @State private var loadError: String?
    @State private var actionMessage: String?
    @State private var confirmingClear = false

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

            Section {
                ForEach(MemoryCategory.allCases, id: \.rawValue) { category in
                    Toggle(category.displayName, isOn: binding(for: category))
                }
            } header: {
                Text("按类别记录")
            } footer: {
                Text("关掉某一类之后，DayCue 不会再为这一类保存新的记忆。已经保存的不会被删除；想清掉请用下面的「清除全部记忆」。")
                    .font(.caption)
            }

            Section {
                LabeledContent("当前已保存", value: "\(totalCount) 条")
                Button("清除全部记忆", role: .destructive) { confirmingClear = true }
            } header: {
                Text("清除")
            } footer: {
                Text("清除只是把记忆标成删除并清空本机检索索引，不会删除你的原始记录、录音和笔记。这个操作无法撤销。")
                    .font(.caption)
            }

            Section {
                Text("DayCue 的长期记忆只保存在本机。推断出来的内容一律先作为「候选」，只有你确认之后才会被当成事实。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("说明")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记忆设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .confirmationDialog(
            "清除全部记忆？",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("清除全部记忆", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有记忆都会被标记为删除，本机关键词索引也会清空。原始记录和笔记不会受影响。这个操作无法撤销。")
        }
    }

    // MARK: - 数据

    private func binding(for category: MemoryCategory) -> Binding<Bool> {
        Binding(
            get: { snapshot[category] ?? true },
            set: { newValue in
                snapshot[category] = newValue
                do {
                    try container.store.setRecordingEnabled(category: category, enabled: newValue, at: Date())
                    actionMessage = newValue
                        ? "已开始记录「\(category.displayName)」。"
                        : "已停止记录「\(category.displayName)」。已有记忆不会被删除。"
                } catch {
                    actionMessage = "保存设置失败：\(error)"
                }
            }
        )
    }

    private func reload() {
        do {
            snapshot = try container.store.recordingControlSnapshot()
            totalCount = try container.store.memoryCount()
            loadError = nil
        } catch {
            snapshot = [:]
            totalCount = 0
            loadError = "读取记忆设置失败：\(error)"
        }
    }

    private func clearAll() {
        do {
            let removed = try container.store.clearAllMemories(at: Date())
            reload()
            actionMessage = "已清除 \(removed) 条记忆，本机索引也一并清空。"
        } catch {
            actionMessage = "清除失败：\(error)"
        }
    }
}
