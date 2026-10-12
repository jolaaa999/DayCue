import Foundation
import SwiftUI
import Speech
import DayCueCore

@MainActor
final class SettingsViewModel: ObservableObject {

    @Published private(set) var reminderLists: [ReminderList] = []
    @Published private(set) var databasePath = ""
    @Published private(set) var databaseSizeDescription = ""
    @Published var showWipeConfirmation = false
    @Published var banner: String?
    @Published private(set) var isRequestingReminders = false
    @Published private(set) var isTestingConnection = false
    @Published private(set) var connectionResult: String?

    private var container: AppContainer?

    func attach(_ container: AppContainer) {
        guard self.container == nil else { return }
        self.container = container
        reload()
    }

    func reload() {
        guard let container else { return }
        databasePath = container.store.databasePath
        databaseSizeDescription = Self.byteText(container.store.storageSizeInBytes())
        reminderLists = container.reminders.reminderLists()
    }

    // MARK: - 权限

    func requestReminderAccess() async {
        guard let container else { return }
        isRequestingReminders = true
        defer { isRequestingReminders = false }

        let granted = await container.reminders.requestAccess()
        await container.refreshPermissions()
        reload()
        banner = granted
            ? "已获得提醒事项完整访问权限。"
            : "没有获得提醒事项权限。任务仍会保存在 App 里，状态显示为「等待写入苹果提醒事项」。"
    }

    func requestMicrophoneAccess() async {
        guard let container else { return }
        let granted = await container.recorder.requestPermission()
        await container.refreshPermissions()
        banner = granted ? "已获得麦克风权限。" : "未获得麦克风权限，无法录音。"
    }

    func requestSpeechAccess() async {
        guard let container else { return }
        // 语音识别的授权申请单独走这里：设置页需要在"还没有录音"的情况下也能触发系统弹窗。
        let status = await SpeechAuthorization.request()
        await container.refreshPermissions()
        switch status {
        case .authorized:
            banner = "已获得语音识别权限。"
        case .denied:
            banner = "语音识别被拒绝。仍可使用后端转写，或手动输入文字。"
        case .restricted:
            banner = "语音识别受系统限制，无法使用。"
        case .notDetermined:
            banner = "语音识别权限尚未确定。"
        @unknown default:
            banner = "语音识别权限状态未知。"
        }
    }

    func requestNotificationAccess() async {
        guard let container else { return }
        let granted = await container.notifications.requestAuthorization()
        await container.refreshPermissions()
        banner = granted ? "已获得通知权限。" : "未获得通知权限。到点提醒不会显示。"
    }

    // MARK: - 连接测试

    func testConnection() async {
        guard let container else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let body = try await container.apiClient.health()
            let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
            connectionResult = snippet.isEmpty ? "连接正常。" : "连接正常：\(snippet.prefix(200))"
        } catch let error as DayCueAPIError {
            connectionResult = error.userFacingMessage
        } catch {
            connectionResult = "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 数据管理

    func wipeAllData() {
        guard let container else { return }
        do {
            try container.store.wipeAllData()
            // 清空后设置项也一起没了，重新写回当前内存里的偏好，避免界面与实际不一致。
            container.settings.repersistAfterWipe()
            reload()
            banner = "已清空本地数据。"
        } catch {
            banner = "清空失败：\(error.localizedDescription)"
        }
    }

    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// 语音识别授权的最小包装。
///
/// 单独放在这里而不是放在 SystemSpeechTranscriber 里，是因为设置页要在"还没有录音"的情况下
/// 也能触发系统授权弹窗；转写器上的方法需要音频文件才走得到。
enum SpeechAuthorization {
    static func request() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
