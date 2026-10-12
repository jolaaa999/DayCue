import SwiftUI
import UIKit
import DayCueCore

/// 原始记录详情。
///
/// 这个页面的核心职责是「可追溯」：把这条记录当时到底收到了什么（原文 / 转写 / OCR / 媒体）
/// 和解析到了哪一步全部摊开，再列出它产出了哪些笔记与任务。
/// 用户对解析结果有疑问时，必须能在这里自己核对，而不是只能相信一句「已解析」。
struct CaptureDetailView: View {

    @EnvironmentObject private var container: AppContainer

    let captureId: String

    @State private var capture: CaptureRecord?
    @State private var attachments: [AttachmentRecord] = []
    @State private var proposals: [ProposalRecord] = []
    @State private var notes: [NoteRecord] = []
    @State private var tasks: [TaskRecord] = []
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

            if let capture {
                overviewSection(capture)
                rawInputSection(capture)
                mediaSection(capture)
                extractionSection(capture)
                outcomeSection
            } else if loadError == nil {
                Section {
                    EmptyStateView(
                        systemImage: "tray.full",
                        title: "这条记录已不存在",
                        message: "它可能已经被删除。返回列表可以看到仍然保存在本机的其他记录。"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { if capture == nil { load() } }
    }

    // MARK: - 概览

    private func overviewSection(_ capture: CaptureRecord) -> some View {
        Section {
            LabeledContent("类型", value: capture.kind.displayName)
            HStack {
                Text("解析状态")
                Spacer()
                CaptureStatusPill(status: capture.status)
            }
            LabeledContent("录入时间", value: CaptureDisplay.timeText(capture))
            LabeledContent("录入时区", value: capture.recordedTimezone)
            if capture.userEdited {
                Label("你修改过这条记录的文本", systemImage: "pencil")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("概览")
        }
    }

    // MARK: - 原始输入

    private func rawInputSection(_ capture: CaptureRecord) -> some View {
        Section {
            if RecordDisplay.hasContent(capture.rawText) {
                textBlock(title: "原文", value: capture.rawText ?? "")
            }
            if RecordDisplay.hasContent(capture.transcript) {
                textBlock(title: "转写", value: capture.transcript ?? "")
            }
            if RecordDisplay.hasContent(capture.ocrText) {
                textBlock(title: "OCR 文本", value: capture.ocrText ?? "")
            }
            if !hasAnyText(capture) {
                Text("这条记录没有文本内容。它仍然保存在本机，可以稍后重新识别。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("原始输入")
        } footer: {
            Text("原文、转写与 OCR 分开保存，互不覆盖；你手工改过文本之后，晚到的识别结果不会再写回。")
                .font(.caption)
        }
    }

    private func hasAnyText(_ capture: CaptureRecord) -> Bool {
        RecordDisplay.hasContent(capture.rawText)
            || RecordDisplay.hasContent(capture.transcript)
            || RecordDisplay.hasContent(capture.ocrText)
    }

    private func textBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 媒体

    private func mediaSection(_ capture: CaptureRecord) -> some View {
        Section {
            if !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    mediaPreview(path: attachment.localPath, mediaType: attachment.mediaType)
                    Text("\(attachment.mediaType) · \(attachment.byteSize) 字节")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let mediaPath = capture.mediaPath, !mediaPath.isEmpty {
                mediaPreview(path: mediaPath, mediaType: nil)
            } else {
                Text("这条记录没有关联的媒体文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("媒体")
        } footer: {
            Text("媒体文件保存在本机 Application Support 目录。系统清理缓存时不会删除这里的文件。")
                .font(.caption)
        }
    }

    /// 图片就地显示缩略图，其它类型显示路径。
    ///
    /// 同步读文件在这里是刻意的：详情页只会打开一条记录，
    /// 换成异步加载反而会让「缩略图先空着再跳出来」这种廉价的不确定感出现在最关键的一屏上。
    @ViewBuilder
    private func mediaPreview(path: String, mediaType: String?) -> some View {
        if let image = UIImage(contentsOfFile: path) {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .accessibilityLabel("记录中的图片")
        } else {
            Label(path, systemImage: mediaIconName(mediaType))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func mediaIconName(_ mediaType: String?) -> String {
        guard let mediaType, !mediaType.isEmpty else { return "doc" }
        if mediaType.hasPrefix("audio") { return "waveform" }
        if mediaType.hasPrefix("image") { return "photo" }
        return "doc"
    }

    // MARK: - 解析状态

    private func extractionSection(_ capture: CaptureRecord) -> some View {
        Section {
            LabeledContent("解析状态", value: capture.status.displayName)

            if let latest = proposals.first {
                LabeledContent("候选状态", value: latest.status.displayName)
                LabeledContent("解析模式", value: latest.mode.displayName)
                LabeledContent("生成时间", value: RecordDisplay.utcText(latest.createdAt))

                DisclosureGroup("查看后端原始返回") {
                    Text(latest.payloadJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("这条记录还没有解析结果。回到「记录」页可以重新解析或手动创建任务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("解析状态")
        } footer: {
            Text("解析结果只是候选，没有确认之前不会写入苹果提醒事项。")
                .font(.caption)
        }
    }

    // MARK: - 产出

    private var outcomeSection: some View {
        Section {
            if notes.isEmpty && tasks.isEmpty {
                Text("这条记录还没有产出笔记或任务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(notes) { note in
                NavigationLink {
                    NoteDetailView(noteId: note.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title.isEmpty ? "（无标题笔记）" : note.title)
                            .font(.subheadline)
                        Text(NoteDisplay.summaryText(note, maxLength: 50))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline)
                    Text(TaskTimeDisplay.scheduleSummary(for: task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    WriteStatePill(state: task.externalWriteState, compact: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("这条记录产出了什么")
        } footer: {
            Text("已删除的笔记与任务不会出现在这里；它们的数据仍在本机。")
                .font(.caption)
        }
    }

    // MARK: - 数据

    private func load() {
        do {
            guard let loaded = try container.store.capture(id: captureId) else {
                // 查询成功但没有这一行 = 记录不存在，与读库失败是两件事，这里不设 loadError。
                capture = nil
                loadError = nil
                return
            }
            capture = loaded
            attachments = try container.store.attachments(captureId: captureId)
            proposals = try container.store.proposals(captureId: captureId)
            notes = try container.store.notes(originCaptureId: captureId)
            tasks = try container.store.tasks(originCaptureId: captureId)
            loadError = nil
        } catch {
            capture = nil
            loadError = "读取这条记录失败：\(error)"
        }
    }
}
