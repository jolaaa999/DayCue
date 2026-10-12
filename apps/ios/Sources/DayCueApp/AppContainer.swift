import Foundation
import SwiftUI
import Combine
import DayCueCore

/// 应用级依赖容器。
///
/// 用 ObservableObject 而不是让每个视图各自 new 一个 store：
/// 本地库是单连接、单写者的，多处打开会直接触发锁冲突。
@MainActor
final class AppContainer: ObservableObject {

    let store: DayCueStore
    let settings: AppSettings
    let apiClient: DayCueAPIClient
    let reminders: ReminderService
    let recorder: AudioRecorderService
    let notifications: NotificationService
    let media: MediaStore
    let ocr = OCRService()
    let writer: TaskWriteService

    /// 本地库打不开时会退回临时目录，这里如实告诉用户，而不是假装正常。
    @Published private(set) var startupWarning: String?

    @Published var permissionSnapshot = PermissionSnapshot()

    private var cancellables = Set<AnyCancellable>()

    init(store: DayCueStore, startupWarning: String?) {
        let settings = AppSettings(store: store)
        let reminders = ReminderService()
        let notifications = NotificationService()
        let media = MediaStore(directory: store.mediaDirectory)

        self.store = store
        self.settings = settings
        self.reminders = reminders
        self.notifications = notifications
        self.media = media
        self.startupWarning = startupWarning
        self.recorder = AudioRecorderService(mediaDirectory: store.mediaDirectory)
        self.apiClient = DayCueAPIClient(
            baseURLProvider: { settings.apiBaseURL },
            tokenProvider: {
                let token = settings.bearerToken
                return token.isEmpty ? nil : token
            }
        )
        self.writer = TaskWriteService(
            store: store,
            settings: settings,
            reminders: reminders,
            notifications: notifications
        )

        // 把子服务的变更信号转发到容器。
        // 视图只观察容器这一个 EnvironmentObject；不转发的话，
        // 今天页就不会在 EKEventStoreChanged 之后重新求值 storeChangedSignal。
        reminders.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// 启动入口。Application Support 不可写时退回临时目录，保证用户至少能录音。
    static func live() -> AppContainer {
        do {
            let store = try StoreBootstrap.open()
            return AppContainer(store: store, startupWarning: nil)
        } catch {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DayCueFallback", isDirectory: true)
            if let fallbackStore = try? DayCueStore(baseDirectory: fallbackDirectory) {
                return AppContainer(
                    store: fallbackStore,
                    startupWarning: "本地数据库无法打开（\(error)），已临时使用临时目录。数据可能在系统清理时丢失。"
                )
            }
            // 连临时目录都写不了属于设备级故障，没有任何可用的降级路径。
            fatalError("无法创建本地数据库：\(error)")
        }
    }

    /// 当前时区（IANA）。捕获与解析都以它为准。
    var currentTimeZone: TimeZone { .current }

    func refreshPermissions() async {
        permissionSnapshot = await PermissionCenter.snapshot()
    }

    /// 供「记录」流程使用的转写服务。
    /// 系统识别优先（离线也能用），不可用时退回后端；两级都失败会抛出明确错误。
    var transcriber: TranscriptionService {
        CompositeTranscriber(
            primary: SystemSpeechTranscriber(),
            fallback: BackendTranscriber(client: apiClient)
        )
    }
}
