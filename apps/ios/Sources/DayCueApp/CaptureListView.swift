import SwiftUI
import DayCueCore

/// 原始记录列表。
///
/// 与「记录」（CaptureView，负责录入）分开：这里只负责翻看已经落在本机的记录，
/// 让用户能确认「我说的话、我拍的照片到底存下来了没有、解析到了哪一步」。
struct CaptureListView: View {

    @EnvironmentObject private var container: AppContainer

    @State private var captures: [CaptureRecord] = []
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

            if captures.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "还没有记录",
                        message: "在「记录」里说一句话、录一段音或拍张照片。原文、转写、OCR 文本和媒体文件都会保存在本机。"
                    )
                }
            } else {
                Section {
                    ForEach(captures) { capture in
                        NavigationLink {
                            CaptureDetailView(captureId: capture.id)
                        } label: {
                            CaptureRow(capture: capture)
                        }
                    }
                } footer: {
                    Text("共 \(captures.count) 条，按录入时间从新到旧。原始记录保存在本机，不联网也能查看。")
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("原始记录")
        // 从详情页返回时重新读库：刚解析过或刚编辑过的记录状态需要立刻反映到列表上。
        .onAppear { reload() }
    }

    private func reload() {
        do {
            captures = try container.store.captures()
            loadError = nil
        } catch {
            captures = []
            loadError = "读取本机记录失败：\(error)"
        }
    }
}

/// 单条原始记录的行：类型图标、摘要、状态、时间。
private struct CaptureRow: View {

    let capture: CaptureRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: CaptureDisplay.systemImageName(for: capture.kind))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(capture.kind.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    CaptureStatusPill(status: capture.status)
                    if capture.userEdited {
                        Text("已编辑")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.14), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                }

                Text(CaptureDisplay.summaryText(capture))
                    .font(.subheadline)
                    .lineLimit(2)

                Text(CaptureDisplay.timeText(capture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("\(capture.kind.displayName)记录，状态 \(capture.status.displayName)")
    }
}
