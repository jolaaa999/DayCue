import Foundation
import UIKit
import AVFoundation
import Speech
import EventKit
import UserNotifications
import DayCueCore

/// 权限状态。抽成自己的枚举是因为四类权限的系统原枚举各不相同，
/// 设置页需要一份统一口径来渲染「当前状态 + 去系统设置」。
enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
    case unknown

    var displayName: String {
        switch self {
        case .notDetermined: return "尚未询问"
        case .granted: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .unknown: return "未知"
        }
    }

    var isGranted: Bool { self == .granted }

    /// 只有被拒绝/受限时才提示去系统设置；未询问时应改用应用内申请按钮。
    var shouldOfferSystemSettings: Bool {
        self == .denied || self == .restricted
    }
}

struct PermissionSnapshot: Equatable {
    var reminders: PermissionStatus = .unknown
    var microphone: PermissionStatus = .unknown
    var speech: PermissionStatus = .unknown
    var notifications: PermissionStatus = .unknown

    var remindersGranted: Bool { reminders.isGranted }
}

/// 权限状态的唯一读取处。
enum PermissionCenter {

    static func reminders() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .writeOnly:
            // 只写权限拿不到清单、也无法在写入前查重，对本应用等价于不可用。
            return .denied
        @unknown default:
            return .unknown
        }
    }

    static func microphone() -> PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func speech() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func notifications() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .granted
        case .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func snapshot() async -> PermissionSnapshot {
        PermissionSnapshot(
            reminders: reminders(),
            microphone: microphone(),
            speech: speech(),
            notifications: await notifications()
        )
    }

    /// 打开本应用在系统设置里的页面。iOS 没有"直达某一项权限"的公开 API，
    /// 所以只能打开应用设置页，文案上不承诺能直接跳到开关。
    ///
    /// 刻意不加 @MainActor：它会被当成普通闭包传给 PermissionRow，
    /// 这里自己切到主线程即可，避免调用方被隔离约束卡住。
    static func openSystemSettings() {
        Task { @MainActor in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }
}
