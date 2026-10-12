import SwiftUI
import PhotosUI
import UIKit
import DayCueCore

/// 记录页。
///
/// 三个入口：文字、录音、拍照/选图。
/// 状态机的可见顺序固定为：已保存到本机 -> 解析中 -> 解析结果预览。
struct CaptureView: View {

    @EnvironmentObject private var container: AppContainer
    @StateObject private var model = CaptureViewModel()
    @State private var pickedItem: PhotosPickerItem?

    var body: some View {
        List {
            if let status = model.statusMessage {
                Section {
                    Label(status, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("没有完成", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            if model.lastCaptureId != nil {
                                Button("稍后重试") {
                                    Task { await model.retryParsing() }
                                }
                                .buttonStyle(.borderless)
                                Button("手动创建任务") {
                                    model.showManualCreate = true
                                }
                                .buttonStyle(.borderless)
                            }
                            Button("知道了") { model.clearError() }
                                .buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }

            textSection
            audioSection
            imageSection

            if let note = model.transcriptionNote {
                Section {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task {
            model.attach(container)
        }
        .onChange(of: pickedItem) { _, newValue in
            guard newValue != nil else { return }
            Task { await model.handlePickedPhoto(newValue) }
        }
        .sheet(item: $model.reviewContext) { context in
            ReviewView(context: context) { note in
                model.reviewDidFinish(note: note)
            }
        }
        .sheet(isPresented: $model.showManualCreate) {
            ManualTaskSheet(captureId: model.lastCaptureId) { note in
                model.statusMessage = note
            }
        }
    }

    // MARK: - 文字

    private var textSection: some View {
        Section {
            TextField("例如：周五之前交实验报告", text: $model.textInput, axis: .vertical)
                .lineLimit(3...6)
            Button {
                Task { await model.submitText() }
            } label: {
                Label("保存这条文字记录", systemImage: "square.and.arrow.down")
            }
            .disabled(model.textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
        } header: {
            Text("文字")
        } footer: {
            Text("先保存在本机，再送去解析。解析失败也不会丢记录。")
                .font(.caption)
        }
    }

    // MARK: - 录音

    private var audioSection: some View {
        Section {
            HStack(spacing: 16) {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(model.isRecording ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isRecording ? "停止录音" : "开始录音")

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isRecording ? "正在录音 \(CaptureViewModel.durationText(model.recordedElapsed))" : "点击开始录音")
                        .font(.subheadline)
                    if !model.isRecording && model.hasRecording {
                        Text("已录制 \(CaptureViewModel.durationText(model.recordedElapsed))，可以提交或删除重录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.isRecording {
                        Text("最长 10 分钟。录音只在本机，直到你提交。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if model.hasRecording && !model.isRecording {
                HStack(spacing: 12) {
                    Button("提交录音") {
                        Task { await model.submitRecording() }
                    }
                    .disabled(model.isWorking)
                    Button("删除重录", role: .destructive) {
                        model.discardRecording()
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        } header: {
            Text("录音")
        } footer: {
            Text("必须显式开始和停止。音频先写入本机，转写失败也会保留文件。")
                .font(.caption)
        }
    }

    // MARK: - 图片

    private var imageSection: some View {
        Section {
            PhotosPicker(
                selection: $pickedItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label(model.pickedImage == nil ? "拍照 / 选图" : "换一张图", systemImage: "photo.on.rectangle")
            }

            if let image = model.pickedImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }

            if model.pickedImage != nil {
                TextField("识别出的文字（可以直接修改）", text: $model.ocrText, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: model.ocrText) { _, _ in
                        model.markOCRTextEdited()
                    }
                if let note = model.ocrNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.submitImage() }
                } label: {
                    Label("保存并解析这张图片", systemImage: "text.viewfinder")
                }
                .disabled(model.isWorking)
            }
        } header: {
            Text("拍照 / 选图")
        } footer: {
            Text("图片识别在本机完成，识别结果必须由你确认。识别不到文字时不会编造内容。")
                .font(.caption)
        }
    }
}
