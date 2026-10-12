import Foundation
import SwiftUI
import Combine
import UIKit
import EventKit
import CoreLocation
import Network
import DayCueCore

// 云同步在 App 层的装配与触发。
//
// 这一层只做三件事：
//   1. 把真实的权限状态翻译成设备能力（需要 EventKit / CoreLocation / 通知中心）；
//   2. 在正确的时机调用 Core 的重放器（前台、网络恢复、手动、本地有新变更）；
//   3. 把冲突交给 ReconciliationView 用的 ReconciliationPlan。
// 所有同步语义都在 DayCueCore 里，这里不含任何重试/游标/冲突决策逻辑。

/// 本机身份。非 @MainActor 的普通类型：协议要求是非隔离的，
/// 而 UIDevice 的名字在 init 时（主线程上）读一次并存下来即可。
final class LiveSyncDeviceIdentity: SyncDeviceIdentityProviding {

    let deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    var platform: SyncDevicePlatform { .ios }

    /// 目前 App 还没有注册远程通知，拿不到 APNs 令牌。
    /// 如实返回 nil：不编造令牌，也不能因为「没有令牌」就上报不支持通知。
    func pushToken() async -> String? { nil }
}

/// 真实能力探测。
///
/// 「未知」与「不可用」严格区分：尚未询问权限时是未知，不能当成不可用，
/// 否则服务端会以为这台设备永远收不到推送而放弃推送。
final class LiveDeviceCapabilityReporter: DeviceCapabilityReporting {

    func currentCapabilities() async -> DeviceCapabilities {
        let notifications = Self.map(await PermissionCenter.notifications())
        let speech = Self.map(PermissionCenter.speech())
        let (calendar, location) = await MainActor.run { (Self.calendarWrite(), Self.preciseLocation()) }
        return DeviceCapabilities(
            notifications: notifications,
            preciseLocation: location,
            calendarWrite: calendar,
            speechTranscription: speech
        )
    }

    static func map(_ status: PermissionStatus) -> Bool? {
        switch status {
        case .granted: return true
        case .denied, .restricted: return false
        case .notDetermined, .unknown: return nil
        }
    }

    static func calendarWrite() -> Bool? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly: return true
        case .denied, .restricted: return false
        case .notDetermined: return nil
        @unknown default: return nil
        }
    }

    static func preciseLocation() -> Bool? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            // 用户可能只给了「大致位置」，那就不是精确定位。
            return manager.accuracyAuthorization == .fullAccuracy
        case .denied, .restricted: return false
        case .notDetermined: return nil
        @unknown default: return nil
        }
    }
}

/// 应用级云同步门面。
///
/// 调用时机（都由本类自己或视图显式触发）：
///   - start()            视图出现时；注册前台通知与网络监听
///   - syncNow()          用户手动点「立即同步」
///   - handleForeground() App 进入前台
///   - handleNetworkRestored() 网络从不可用变成可用
///   - noteLocalChange()  任写路径写完本地数据之后（2 秒防抖）
@MainActor
final class CloudSyncService: ObservableObject {

    @Published private(set) var signInState: CloudSyncSignInState = .notSignedIn
    @Published private(set) var statusMessage: String = "未登录，云同步未启用"
    @Published private(set) var lastResult: CloudSyncRunResult?
    @Published private(set) var conflictPlan: ReconciliationPlan?
    @Published private(set) var conflictCount: Int = 0
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var deviceCapabilitySummary: String = DeviceCapabilities.unknown.displaySummary

    private let store: DayCueStore
    private let settings: AppSettings
    private let replayer: CloudSyncReplayer
    private let resolver: CloudConflictResolver
    private let capabilityReporter: LiveDeviceCapabilityReporter

    private var networkMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var localChangeTask: Task<Void, Never>?

    init(
        store: DayCueStore,
        settings: AppSettings,
        scheduler: CloudSyncScheduling = TaskCloudSyncScheduler(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.resolver = CloudConflictResolver(store: store)
        self.capabilityReporter = LiveDeviceCapabilityReporter()

        // 与 AppContainer 里 DayCueAPIClient 相同的取值方式：
        // 地址与令牌都从 AppSettings 现读，设置页改完立即生效。
        let client = SyncClient(
            baseURLProvider: { settings.apiBaseURL },
            tokenProvider: {
                let token = settings.bearerToken
                return token.isEmpty ? nil : token
            }
        )
        let devices = DeviceRegistrationService(
            store: store,
            client: client,
            identity: LiveSyncDeviceIdentity(deviceName: UIDevice.current.name),
            capabilities: capabilityReporter
        )
        self.replayer = CloudSyncReplayer(
            store: store,
            client: client,
            tokenProvider: {
                let token = settings.bearerToken
                return token.isEmpty ? nil : token
            },
            clock: clock,
            scheduler: scheduler,
            devices: devices
        )
        self.signInState = settings.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notSignedIn : .signedIn
        refreshConflicts()
    }

    // MARK: - 生命周期

    /// 视图出现时调用一次。重复调用会被忽略。
    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleForeground() }
        })
        startNetworkMonitor()
        Task { await refreshDeviceCapabilitySummary() }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        networkMonitor?.cancel()
        networkMonitor = nil
        localChangeTask?.cancel()
        localChangeTask = nil
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        var lastSatisfied = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            // 只在「不可用 -> 可用」时同步，避免网络抖动时反复触发。
            if satisfied, !lastSatisfied {
                Task { @MainActor in await self?.handleNetworkRestored() }
            }
            lastSatisfied = satisfied
        }
        monitor.start(queue: DispatchQueue(label: "com.daycue.cloudsync.network"))
        networkMonitor = monitor
    }

    // MARK: - 触发入口

    func syncNow() async {
        await run(trigger: .manual)
    }

    func handleForeground() async {
        await run(trigger: .appForeground)
    }

    func handleNetworkRestored() async {
        await run(trigger: .networkRestored)
    }

    /// 任写路径写完本地数据之后调用。2 秒防抖：连续编辑只推一次合并后的结果。
    func noteLocalChange() {
        localChangeTask?.cancel()
        localChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.run(trigger: .localChange)
        }
    }

    // MARK: - 冲突

    /// 由 ReconciliationView 的 submit 回调逐字段调用。
    func resolve(_ resolution: ReconciliationResolution) async -> String? {
        do {
            let outcome = try resolver.record(resolution, at: Date())
            refreshConflicts()
            switch outcome {
            case let .stillWaiting(remaining):
                return "已记录你的选择，还有 \(remaining) 个字段待裁决。"
            case .unknownConflict:
                return "这条冲突已经处理过了。"
            case .appliedKeptLocal, .appliedAcceptedServer, .appliedDeletedLocal:
                await run(trigger: .localChange)
                return "已按你的选择保存，并加入同步队列。"
            }
        } catch {
            return "保存冲突裁决失败：\(error)"
        }
    }

    func refreshConflicts() {
        let conflicts = (try? store.syncConflicts()) ?? []
        conflictCount = conflicts.count
        conflictPlan = conflicts.isEmpty
            ? nil
            : SyncConflictPresenter.plan(conflicts: conflicts, generatedAt: DayCueClock.nowUTCString())
    }

    func refreshDeviceCapabilitySummary() async {
        deviceCapabilitySummary = (await capabilityReporter.currentCapabilities()).displaySummary
    }

    // MARK: - 内部

    private func run(trigger: CloudSyncTrigger) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let result = await replayer.replay(trigger, at: Date())
        lastResult = result
        signInState = await replayer.currentSignInState()
        refreshConflicts()

        if !result.didRun {
            // 未登录或已有同步在跑：如实说明，不显示成「同步失败」。
            statusMessage = result.message
            return
        }
        statusMessage = result.message
    }
}
