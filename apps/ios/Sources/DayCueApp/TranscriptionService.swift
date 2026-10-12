import Foundation
import Speech
import DayCueCore

/// 转写结果。engineName 只用于向用户说明这段文字来自哪里，不参与业务判断。
struct TranscriptionOutcome {
    let text: String
    let mode: ExtractionMode
    let engineName: String
}

enum TranscriptionError: LocalizedError, Equatable {
    case notAuthorized
    case notAvailable(String)
    case noSpeechDetected
    case engineFailed(String)
    case audioUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "尚未授权语音识别。可以在系统设置里开启，或改用后端转写。"
        case let .notAvailable(reason):
            return "系统语音识别不可用：\(reason)"
        case .noSpeechDetected:
            return "没有识别到语音内容。录音已保留，可以重录或手动输入文字。"
        case let .engineFailed(message):
            return "语音识别失败：\(message)"
        case let .audioUnreadable(message):
            return "音频文件无法读取：\(message)"
        }
    }

    /// 系统引擎不可用/未授权时，调用方据此切换到后端转写。
    var suggestsBackendFallback: Bool {
        switch self {
        case .notAuthorized, .notAvailable:
            return true
        case .noSpeechDetected, .engineFailed, .audioUnreadable:
            return false
        }
    }
}

/// 转写抽象。
///
/// 关键约束：实现必须在失败时抛出明确的错误，绝不能返回编造的文本。
/// 上层拿到错误就展示「已保留录音 + 失败原因」，而不是给用户一段假文字。
protocol TranscriptionService {
    var engineName: String { get }
    func transcribe(audioURL: URL, timezone: String) async throws -> TranscriptionOutcome
}

/// 系统 Speech 框架实现。端侧识别不出网也能用，但依赖设备与语言支持情况。
struct SystemSpeechTranscriber: TranscriptionService {

    let engineName = "系统语音识别"
    private let localeIdentifier: String

    init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = localeIdentifier
    }

    func transcribe(audioURL: URL, timezone: String) async throws -> TranscriptionOutcome {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.audioUnreadable("文件不存在")
        }

        let status = await requestAuthorization()
        guard status == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw TranscriptionError.notAvailable("当前设备不支持 \(localeIdentifier) 识别")
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.notAvailable("识别服务暂时不可用（可能未联网或受限）")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // 只有在设备声明支持时才强制端侧识别，否则会被系统直接拒绝。
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let text = try await recognize(recognizer: recognizer, request: request)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.noSpeechDetected }
        return TranscriptionOutcome(text: trimmed, mode: .live, engineName: engineName)
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 用 continuation 包住 recognitionTask，并保证只 resume 一次。
    /// 回调可能先给 error 再给 final result（或反之），重复 resume 会让进程崩溃。
    private func recognize(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> String {
        let box = ResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if box.claim() { continuation.resume(throwing: TranscriptionError.engineFailed(error.localizedDescription)) }
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    if box.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                }
            }
        }
    }
}

/// 一次性闸门。放在类里而不是局部 var，是因为闭包会在任务回调线程上执行。
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// 后端转写实现。POST /v1/transcriptions。
struct BackendTranscriber: TranscriptionService {

    let engineName = "后端转写"
    private let client: DayCueAPIClient
    private let language: String?

    init(client: DayCueAPIClient, language: String? = "zh-CN") {
        self.client = client
        self.language = language
    }

    func transcribe(audioURL: URL, timezone: String) async throws -> TranscriptionOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: audioURL)
        } catch {
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }
        guard !data.isEmpty else {
            throw TranscriptionError.audioUnreadable("音频文件是空的")
        }

        let response = try await client.transcribe(audioData: data, language: language, timezone: timezone)
        let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 后端返回空文本时按「没识别到」处理，不要把它当成成功写进记录里。
        guard !trimmed.isEmpty else { throw TranscriptionError.noSpeechDetected }
        return TranscriptionOutcome(text: trimmed, mode: response.mode, engineName: engineName)
    }
}

/// 组合转写：优先系统识别，不可用/未授权时退回后端。
/// 两级都失败时向上抛错，由 UI 提示「已保留录音」。
struct CompositeTranscriber: TranscriptionService {

    let engineName = "系统优先 / 后端兜底"
    private let primary: TranscriptionService
    private let fallback: TranscriptionService

    init(primary: TranscriptionService, fallback: TranscriptionService) {
        self.primary = primary
        self.fallback = fallback
    }

    func transcribe(audioURL: URL, timezone: String) async throws -> TranscriptionOutcome {
        do {
            return try await primary.transcribe(audioURL: audioURL, timezone: timezone)
        } catch let error as TranscriptionError where error.suggestsBackendFallback {
            return try await fallback.transcribe(audioURL: audioURL, timezone: timezone)
        }
    }
}
