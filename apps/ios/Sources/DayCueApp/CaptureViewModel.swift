import Foundation
import SwiftUI
import Combine
import PhotosUI
import UIKit
import DayCueCore

/// 解析结果预览所需的上下文。
struct ReviewContext: Identifiable, Equatable {
    let id: String
    let captureId: String
    let mode: ExtractionMode
    let warnings: [String]
    var drafts: [ReviewDraft]
    /// 这份候选对应的输入版本。确认时再校验一次，避免用过期输入创建任务。
    let inputVersion: CaptureInputVersion
}

@MainActor
final class CaptureViewModel: ObservableObject {

    /// 捕获状态机。用户先看到"已保存到本机"，再看到"解析中"，最后才进入预览页。
    enum Phase: Equatable {
        case idle
        case savedLocally
        case parsing
        case ready
        case failed
    }

    @Published var textInput = ""
    @Published var ocrText = ""
    @Published private(set) var pickedImage: UIImage?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCaptureId: String?
    @Published private(set) var isWorking = false

    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var reviewContext: ReviewContext?
    @Published var showManualCreate = false
    @Published private(set) var transcriptionNote: String?
    @Published private(set) var ocrNote: String?

    private var container: AppContainer?
    private var cancellables = Set<AnyCancellable>()
    /// 用户是否亲手改过 OCR 文本。改过之后就不允许任何识别结果覆盖它。
    private var ocrEditedByUser = false

    /// 解析请求的序号。每次解析自增，迟到的旧响应据此被识别并丢弃。
    private var parseGeneration = 0

    func attach(_ container: AppContainer) {
        guard self.container == nil else { return }
        self.container = container
        // 把录音器的状态变化转发成本视图模型的 objectWillChange，
        // 这样界面上的时长读数会跟着走，而不需要把录音器再包一层重复状态。
        container.recorder.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var isRecording: Bool { container?.recorder.isRecording ?? false }
    var recordedElapsed: TimeInterval { container?.recorder.elapsed ?? 0 }
    var hasRecording: Bool { container?.recorder.recordedURL != nil }

    // MARK: - 文字

    func submitText() async {
        guard let container else { return }
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "请先输入内容。"
            return
        }
        let capture = CaptureRecord(
            kind: .text,
            rawText: text,
            recordedAt: DayCueClock.nowUTCString(),
            recordedTimezone: container.currentTimeZone.identifier
        )
        textInput = ""
        await persistAndParse(capture)
    }

    // MARK: - 录音

    func toggleRecording() async {
        guard let container else { return }
        if container.recorder.isRecording {
            _ = container.recorder.stop()
            statusMessage = "录音已保存在本机，可以试听后提交。"
            errorMessage = nil
        } else {
            do {
                errorMessage = nil
                statusMessage = nil
                try await container.recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func discardRecording() {
        container?.recorder.discard()
        statusMessage = nil
    }

    func submitRecording() async {
        guard let container else { return }
        guard let url = container.recorder.recordedURL else {
            errorMessage = "还没有录音。"
            return
        }

        var capture = CaptureRecord(
            kind: .audio,
            mediaPath: url.path,
            recordedAt: DayCueClock.nowUTCString(),
            recordedTimezone: container.currentTimeZone.identifier
        )

        // 先把音频搬进媒体目录并落库，再谈转写。任何后续失败都不能丢音频。
        do {
            let stored = try container.media.storeAudio(at: url, captureId: capture.id)
            capture.mediaPath = stored.url.path
            try container.store.insertCapture(capture)
            try container.store.insertAttachment(AttachmentRecord(
                captureId: capture.id,
                mediaType: stored.mediaType,
                localPath: stored.url.path,
                byteSize: stored.byteSize,
                sha256: stored.sha256,
                createdAt: DayCueClock.nowUTCString()
            ))
        } catch {
            errorMessage = "录音保存失败：\(error.localizedDescription)"
            return
        }

        container.recorder.clearAfterSubmit()
        lastCaptureId = capture.id
        phase = .savedLocally
        statusMessage = "已保存到本机，正在转写。"
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        // 转写
        do {
            let outcome = try await container.transcriber.transcribe(
                audioURL: URL(fileURLWithPath: capture.mediaPath ?? url.path),
                timezone: capture.recordedTimezone
            )
            // 用户没有改过文本时写入识别结果；改过则保留用户的版本。
            _ = try? container.store.applyExtractedText(id: capture.id, transcript: outcome.text)
            transcriptionNote = "转写来源：\(outcome.engineName)"
        } catch {
            try? container.store.updateCaptureStatus(id: capture.id, status: .failed)
            phase = .failed
            statusMessage = nil
            errorMessage = "录音已保存在本机。转写失败：\(error.localizedDescription)"
            return
        }

        await parse(captureId: capture.id)
    }

    // MARK: - 图片

    func handlePickedPhoto(_ item: PhotosPickerItem?) async {
        guard let container, let item else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "无法读取所选图片。"
                return
            }
            pickedImage = image
            ocrEditedByUser = false
            ocrText = ""
            ocrNote = nil
            do {
                let text = try await container.ocr.recognizeText(in: image)
                ocrText = text
                ocrNote = "识别结果可以直接修改；改动会以你的版本为准。"
            } catch {
                // 识别失败就是失败，不编造任何文字。
                ocrText = ""
                ocrNote = error.localizedDescription
            }
        } catch {
            errorMessage = "无法读取所选图片：\(error.localizedDescription)"
        }
    }

    func markOCRTextEdited() {
        ocrEditedByUser = true
    }

    func submitImage() async {
        guard let container, let image = pickedImage else {
            errorMessage = "请先选择一张图片。"
            return
        }
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "图片里没有可用文字。可以手动输入内容，或稍后重试识别。"
            return
        }

        var capture = CaptureRecord(
            kind: .image,
            ocrText: text,
            // 用户改过 OCR 文本时把 user_edited 置位，晚到的识别结果不能覆盖。
            userEdited: ocrEditedByUser,
            recordedAt: DayCueClock.nowUTCString(),
            recordedTimezone: container.currentTimeZone.identifier
        )

        do {
            let stored = try container.media.storeImage(image.resizedForUpload(), captureId: capture.id)
            capture.mediaPath = stored.url.path
            try container.store.insertCapture(capture)
            try container.store.insertAttachment(AttachmentRecord(
                captureId: capture.id,
                mediaType: stored.mediaType,
                localPath: stored.url.path,
                byteSize: stored.byteSize,
                sha256: stored.sha256,
                createdAt: DayCueClock.nowUTCString()
            ))
        } catch {
            errorMessage = "图片保存失败：\(error.localizedDescription)"
            return
        }

        pickedImage = nil
        ocrText = ""
        ocrNote = nil
        ocrEditedByUser = false
        await parse(captureId: capture.id)
    }

    // MARK: - 解析

    func retryParsing() async {
        guard let captureId = lastCaptureId else { return }
        await parse(captureId: captureId)
    }

    private func persistAndParse(_ capture: CaptureRecord) async {
        guard let container else { return }
        do {
            try container.store.insertCapture(capture)
        } catch {
            errorMessage = "保存到本机失败：\(error.localizedDescription)"
            return
        }
        await parse(captureId: capture.id)
    }

    private func parse(captureId: String) async {
        guard let container else { return }

        // 每次解析分配一个序号：慢的旧请求回来时会被识别为过期，不能覆盖新请求的结果。
        parseGeneration += 1
        let generation = parseGeneration

        lastCaptureId = captureId
        phase = .savedLocally
        statusMessage = "已保存到本机，正在解析。"
        errorMessage = nil
        isWorking = true
        // 只有最新那次解析才有权改忙碌状态，否则旧请求会把新请求的 loading 提前关掉。
        defer { if generation == parseGeneration { isWorking = false } }

        try? container.store.updateCaptureStatus(id: captureId, status: .extracting)
        phase = .parsing

        let request: ExtractionRequest
        let requestVersion: CaptureInputVersion
        do {
            guard let stored = try container.store.capture(id: captureId) else {
                errorMessage = "找不到刚保存的记录。"
                phase = .failed
                return
            }
            request = try ExtractionRequestBuilder.build(capture: stored)
            // 记下这次请求对应的输入版本，结果回来时用它判断是否还有效。
            requestVersion = CaptureInputVersion.make(from: stored)
        } catch {
            try? container.store.updateCaptureStatus(id: captureId, status: .failed)
            errorMessage = "这条记录没有可解析的文字，可以手动创建任务。"
            phase = .failed
            return
        }

        do {
            let result = try await container.apiClient.extract(request)

            // 结果到达后先判断新鲜度：输入变了、或已有更新的解析，就整体丢弃。
            // 关键是**不落库也不展示**——否则用户可能把过期候选确认成任务。
            let currentCapture = (try? container.store.capture(id: captureId)).flatMap { $0 }
            let freshness = ExtractionFreshnessPolicy.evaluate(
                request: requestVersion,
                current: currentCapture.map(CaptureInputVersion.make(from:)),
                generation: generation,
                latestGeneration: parseGeneration
            )
            switch freshness {
            case .current:
                break
            case .superseded:
                // 有更新的解析正在进行，界面状态由它负责，这里不要插手。
                return
            case .inputChanged:
                statusMessage = nil
                phase = .idle
                errorMessage = freshness.rejectionMessage
                return
            }

            let payload = result.rawJSON
            try container.store.insertProposal(ProposalRecord(
                captureId: captureId,
                schemaVersion: result.response.schemaVersion,
                payloadJSON: payload,
                mode: result.response.mode,
                createdAt: DayCueClock.nowUTCString()
            ))

            let drafts = ReviewDraft.from(response: result.response)
            let needsClarification = result.response.items.contains { $0.requiresClarification }
            try container.store.updateCaptureStatus(
                id: captureId,
                status: needsClarification ? .needsClarification : .extracted
            )

            statusMessage = nil
            phase = .ready

            let context = ReviewContext(
                id: captureId,
                captureId: captureId,
                mode: result.response.mode,
                warnings: result.response.warnings,
                drafts: drafts,
                inputVersion: requestVersion
            )

            if container.settings.autoCreateEnabled, !needsClarification {
                // 自动模式：只自动创建不需要澄清的 task，note 一律不写系统。
                await autoCreate(from: context)
            } else {
                reviewContext = context
            }
        } catch let error as DayCueAPIError {
            // 网络失败/超时/AI 报错/model_output_invalid 都走这里：
            // 记录已在本机，用户可以选择稍后重试或手动创建，绝不编造解析结果。
            try? container.store.updateCaptureStatus(id: captureId, status: .failed)
            statusMessage = nil
            phase = .failed
            errorMessage = error.userFacingMessage
        } catch {
            try? container.store.updateCaptureStatus(id: captureId, status: .failed)
            statusMessage = nil
            phase = .failed
            errorMessage = "解析失败：\(error.localizedDescription)。记录已保存在本机。"
        }
    }

    /// 自动创建只处理 task；occur 到需要澄清的候选一律退回预览页。
    private func autoCreate(from context: ReviewContext) async {
        guard let container else { return }
        var notes: [String] = []
        for draft in context.drafts where draft.kind == .task {
            let outcome = await container.writer.createTask(from: draft, captureId: context.captureId)
            if let note = outcome.note { notes.append(note) }
        }
        // 自动模式只是省掉「点一次确认」，不等于笔记可以不落库。
        // 不写的话，自动模式下用户的记录内容同样只留在提案 JSON 里。
        let recordedAt = (try? container.store.capture(id: context.captureId))?.recordedAt
        let noteOutcome = (try? container.store.applySelectedNoteDrafts(
            context.drafts,
            captureId: context.captureId,
            occurredAt: recordedAt
        )) ?? NoteUpsertOutcome()

        try? container.store.updateProposalStatus(captureId: context.captureId, status: .accepted)
        var parts = ["已按自动模式创建任务。"]
        if !noteOutcome.isEmpty { parts.append("笔记：" + noteOutcome.summaryText) }
        if !notes.isEmpty { parts.append(notes.joined(separator: " ")) }
        statusMessage = parts.joined(separator: " ")
        phase = .idle
    }

    func reviewDidFinish(note: String?) {
        invalidateInFlightParses()
        reviewContext = nil
        statusMessage = note
        phase = .idle
        lastCaptureId = nil
        transcriptionNote = nil
    }

    func dismissReview() {
        // 预览被关掉之后，在途的解析结果不能再把预览弹回来让用户误确认。
        invalidateInFlightParses()
        reviewContext = nil
        phase = .idle
    }

    /// 使所有在途的解析响应作废。
    private func invalidateInFlightParses() {
        parseGeneration += 1
    }

    func clearError() {
        errorMessage = nil
    }

    func reset() {
        invalidateInFlightParses()
        textInput = ""
        ocrText = ""
        pickedImage = nil
        ocrNote = nil
        transcriptionNote = nil
        statusMessage = nil
        errorMessage = nil
        phase = .idle
        lastCaptureId = nil
        ocrEditedByUser = false
    }

    static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
