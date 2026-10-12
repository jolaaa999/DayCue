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
    /// 长期记忆的写入链路。
    /// 只暴露协调器而不是让视图直接调 store：记忆的候选/确认/检索
    /// 有一套必须按顺序走的规则（先查类别开关、推断不得自动成为事实），
    /// 绕过它就会出现"关了记录还是写进去了"这类问题。
    let memoryIngest: MemoryIngestCoordinator
    /// 位置事件与主动通知。
    /// 事件源在适配层（CoreLocation），求值与预算在 Core，这里只做编排与持有。
    let proactiveGeo: ProactiveGeoCoordinator
    /// 课后追问的通知安排。与 proactiveGeo 共用同一个通知调度器实例，
    /// 否则两边各自取消"自己那批"通知时看不出对方的存在，会互相漏掉。
    let followUpNotifications: FollowUpNotificationCoordinator
    /// 云同步门面。
    /// 写路径与视图必须拿到同一个实例：它内部持有网络监听、前台观察者和
    /// 防抖入队任务，多个实例之间互相看不见，会出现"改了却没入队"。
    let cloudSync: CloudSyncService
    /// 用户发起的笔记写入编排（新建 / 编辑 / 删除）。
    /// 视图不直接调 store：写成功之后必须通知云同步，把「写」与「写完通知」
    /// 绑在同一个类型里，才不会漏掉某一条入口。
    let noteWrite: NoteWriteCoordinator

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
        // 默认用确定性规则抽取，不接任何模型：本机没有供应商凭据时
        // 宁可只产出有原文依据的候选，也不要生成看起来像记忆的假内容。
        // 接入真实模型时把 provider 换掉即可，链路本身不用改。
        self.memoryIngest = MemoryIngestCoordinator(
            store: store,
            extraction: MemoryExtraction(provider: DefaultRuleBasedExtractor())
        )
        // 两个协调器必须共用同一个 scheduler：通知的取消是按标识前缀做的，
        // 两个实例各自持有一套内部状态时，一方取消不到另一方排的通知。
        let proactiveNotifier = LocalNotificationScheduler()
        self.proactiveGeo = ProactiveGeoCoordinator(store: store, notifier: proactiveNotifier)
        self.followUpNotifications = FollowUpNotificationCoordinator(
            store: store,
            notifier: proactiveNotifier
        )
        // 云同步：后端地址与令牌都从 settings 现读，设置页改完立即生效。
        let cloudSync = CloudSyncService(store: store, settings: settings)
        self.cloudSync = cloudSync
        // 笔记写入的云同步出口。适配器内部跳一次 @MainActor（noteLocalChange 是 @MainActor 的），
        // Core 侧的 NoteWriteCoordinator 因此保持非隔离、可被 macOS 上的单元测试直接调用。
        self.noteWrite = NoteWriteCoordinator(
            store: store,
            reporter: CloudSyncNoteChangeNotifier(cloudSync: cloudSync)
        )

        // 接线：写服务与对账协调器都不持有 CloudSyncService，
        // 只通过回调把「本地有新变更」交出去，装配细节留在这里。
        // 必须在 cloudSync 初始化之后再接线，否则闭包捕获不到实例。
        // 用 weak 捕获局部变量 cloudSync（而不是 self）：
        //   1. 避免 AppContainer -> writer -> 闭包 -> AppContainer 的循环引用；
        //   2. 这两处出口的生命周期比同步服务长，强引用会无谓延长它的存活时间。
        self.writer.onLocalWrite = { [weak cloudSync] in
            cloudSync?.noteLocalChange()
        }
        ReconciliationCoordinator.onLocalWrite = { [weak cloudSync] in
            cloudSync?.noteLocalChange()
        }

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
