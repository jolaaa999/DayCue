import Foundation
import AVFoundation
import UIKit

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case sessionFailed(String)
    case recorderFailed(String)
    case noRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "麦克风权限被拒绝，无法录音。可以到系统设置里开启。"
        case let .sessionFailed(message):
            return "音频会话无法启动：\(message)"
        case let .recorderFailed(message):
            return "录音失败：\(message)"
        case .noRecording:
            return "当前没有可提交的录音。"
        }
    }
}

/// 录音器。
///
/// 只负责"把声音写到本地文件"，不负责转写：录音不依赖识别成功。
/// 时长上限设成 10 分钟，避免用户误触后产生一个巨大的 m4a 而自己不知道。
@MainActor
final class AudioRecorderService: NSObject, ObservableObject {

    static let maximumDuration: TimeInterval = 600

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    /// 停止录音后的本地文件。UI 用它显示"已录制 xx 秒，可试听/重录"。
    @Published private(set) var recordedURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var workingURL: URL?

    /// 媒体目录由外部注入：容器可能因为默认目录不可写而退回到临时目录，
    /// 录音器不能自己去猜一个可能和本地库不一致的位置。
    private let mediaDirectory: URL

    init(mediaDirectory: URL) {
        self.mediaDirectory = mediaDirectory
        super.init()
    }

    // MARK: - 权限

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: - 录制

    func start() async throws {
        guard !isRecording else { return }

        guard hasPermission else {
            let granted = await requestPermission()
            guard granted else { throw AudioRecorderError.permissionDenied }
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // playAndRecord 而不是 record：停止后要能立刻试听，且保持与后续播放同一会话。
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw AudioRecorderError.sessionFailed(error.localizedDescription)
        }

        let url = try makeTemporaryURL()
        workingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = false
            guard recorder.record() else {
                throw AudioRecorderError.recorderFailed("录音器未能启动")
            }
            self.recorder = recorder
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.recorderFailed(error.localizedDescription)
        }

        isRecording = true
        elapsed = 0
        lastError = nil
        startTimer()
    }

    /// 停止并保留文件。返回落盘地址，nil 表示根本没有录到东西。
    @discardableResult
    func stop() -> URL? {
        guard let recorder else {
            isRecording = false
            return nil
        }
        recorder.stop()
        self.recorder = nil
        stopTimer()
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let url = recorder.url
        if FileManager.default.fileExists(atPath: url.path) {
            recordedURL = url
            return url
        }
        return nil
    }

    /// 删除重录。
    func discard() {
        stopTimer()
        if let recorder {
            recorder.stop()
            self.recorder = nil
        }
        isRecording = false
        if let url = recordedURL ?? workingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        workingURL = nil
        elapsed = 0
    }

    /// 提交后清掉缓存引用，避免下一次录音误用旧文件。
    func clearAfterSubmit() {
        recordedURL = nil
        workingURL = nil
        elapsed = 0
    }

    // MARK: - 内部

    private func makeTemporaryURL() throws -> URL {
        let directory = mediaDirectory.appendingPathComponent("pending", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AudioRecorderError.recorderFailed(error.localizedDescription)
        }
        return directory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
    }

    private func startTimer() {
        // 用 Timer 而不是 CADisplayLink：这里是 1 秒粒度的时长显示，不需要逐帧刷新。
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                if recorder.currentTime >= AudioRecorderService.maximumDuration {
                    self.stop()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioRecorderService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            if !flag {
                self.lastError = "录音被系统中断，已保留已录制的部分。"
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.lastError = error?.localizedDescription ?? "录音编码出错。"
        }
    }
}
