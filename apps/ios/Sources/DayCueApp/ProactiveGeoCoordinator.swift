import Foundation
import Combine
import DayCueCore

/// 地点主动提醒的编排者。
///
/// 它把三样东西接起来，自己不做任何判断（判断都在 DayCueCore 的纯逻辑里）：
///   系统位置事件 -> LocationEventSource -> GeoTriggerRunner（规则求值 + 预算 + 通知安排）
///
/// 生命周期职责（任务要求的三条都在这里）：
/// 1. 启动时恢复已保存的地点监控注册（start -> refreshRegistrations）；
/// 2. 权限变化后重新评估注册状态（系统回调 / 回前台都走 refreshRegistrations）；
/// 3. 规则增删改后取消旧注册并重新注册（applyRuleChanges）。
///
/// 明确不混的两条路径：用户自己设置的到点提醒（任务提醒走 NotificationService、
/// 课程/任务写苹果提醒事项走 ReminderService）**不经过**这里，也不受主动预算限制。
///
/// 谁创建它：AppContainer（需要主会话加一行属性与初始化）；谁调用它：
/// DayCueApp 的 .task / scenePhase 回调，以及地点规则保存/删除后的界面动作。
@MainActor
final class ProactiveGeoCoordinator: ObservableObject {

    let store: DayCueStore
    private let source: any LocationEventSource
    private let notifier: LocalNotificationScheduler
    private let receiptService: ProactiveReceiptService

    /// 当前定位能力。界面据此如实展示「这条规则现在不会触发，原因是 X」。
    @Published private(set) var capability: LocationCapability = .notDetermined
    /// 每条地点规则的可触发状态。
    @Published private(set) var ruleReadiness: [GeoRuleReadiness] = []
    /// 最近被丢弃的位置观测（陈旧、精度差、位置不可用），最多保留 20 条。
    @Published private(set) var recentDiscards: [LocationEventDiscard] = []
    @Published private(set) var lastSummary: String?

    init(
        store: DayCueStore,
        source: any LocationEventSource = CoreLocationEventSource(),
        notifier: LocalNotificationScheduler = LocalNotificationScheduler()
    ) {
        self.store = store
        self.source = source
        self.notifier = notifier
        self.receiptService = ProactiveReceiptService(store: store)
    }

    // MARK: - 生命周期

    /// 启动：接线 + 申请权限 + 恢复已保存的注册。
    func start() async {
        source.onSemanticEvent = { [weak self] event in
            Task { @MainActor in await self?.handle(event: event) }
        }
        source.onDiscardedEvent = { [weak self] discard in
            Task { @MainActor in self?.recordDiscard(discard) }
        }
        source.onCapabilityChange = { [weak self] capability in
            Task { @MainActor in await self?.handleCapabilityChange(capability) }
        }

        // 通知交互回执全部回到这里，再写回账本状态。
        // 注册在 LocalNotificationScheduler 的 static 出口上：通知中心 delegate 是进程级的。
        LocalNotificationScheduler.onReceipt = { [weak self] receipt in
            Task { @MainActor in self?.handleReceipt(receipt) }
        }
        notifier.installDelegate()

        source.requestAuthorizationIfNeeded()
        await refreshRegistrations()
    }

    /// 权限或系统设置变化后重新评估：该注册的注册，该取消的取消。
    func handleCapabilityChange(_ capability: LocationCapability) async {
        self.capability = capability
        await refreshRegistrations()
    }

    /// 规则修改或删除后调用。取消旧注册、按最新规则重新注册，绝不留下野注册。
    func applyRuleChanges() async {
        await refreshRegistrations()
    }

    /// 申请后台定位权限。用户不给也没关系，能力会停在 .foregroundOnly 并如实上报。
    func requestBackgroundAuthorization() {
        source.requestBackgroundAuthorizationIfNeeded()
    }

    // MARK: - 注册对账

    func refreshRegistrations() async {
        capability = source.refreshCapability()
        let now = Date()

        let rules = (try? store.geoRules(includeDeleted: false, limit: 500)) ?? []
        let places = (try? store.places(includeDeleted: false, limit: 500)) ?? []
        var placesById: [String: PlaceRecord] = [:]
        for place in places { placesById[place.id] = place }

        let plan = GeoRegistrationPlanner.plan(
            rules: rules,
            placesById: placesById,
            capability: capability,
            currentlyMonitoredPlaceIds: source.monitoredPlaceIds,
            now: now
        )

        // 先取消再注册：顺序反了的话，被取消的地点可能正好是刚注册的那个。
        source.stopMonitoring(placeIds: plan.placeIdsToStopMonitoring)
        source.startMonitoring(places: plan.placesToStartMonitoring)

        ruleReadiness = plan.readiness
        if let reason = capability.unavailableReason {
            lastSummary = "地点规则当前不会触发：\(reason)"
        }
    }

    // MARK: - 事件处理

    private func handle(event: LocationSemanticEvent) async {
        let now = Date()
        let config = ProactiveBudgetConfigCodec.decode(store.setting(ProactiveSettingsKey.config))
        let runner = GeoTriggerRunner(store: store, notifier: notifier)

        do {
            let outcome = try await runner.handle(
                event: event,
                config: config,
                timeZone: .current,
                now: now
            )
            if outcome.results.isEmpty {
                let reason = outcome.skips.first?.reason
                lastSummary = reason.map { "本次位置事件没有产生提醒：\($0)" }
                    ?? "本次位置事件没有产生提醒。"
            } else {
                lastSummary = outcome.results
                    .map { "\($0.state.displayName)：\($0.reason)" }
                    .joined(separator: "\n")
            }
        } catch {
            lastSummary = "处理位置事件失败：\(error)"
        }
    }

    private func recordDiscard(_ discard: LocationEventDiscard) {
        recentDiscards.append(discard)
        if recentDiscards.count > 20 {
            recentDiscards.removeFirst(recentDiscards.count - 20)
        }
    }

    private func handleReceipt(_ receipt: ProactiveInteractionReceipt) {
        do {
            let outcome = try receiptService.apply(receipt)
            lastSummary = outcome.reason ?? "通知回执已记录：\(outcome.state.displayName)"
        } catch {
            lastSummary = "通知回执写入失败：\(error)"
        }
    }

    // MARK: - 工厂

    /// 与 AppContainer 共用同一个 store 与通知安排器。
    static func live(
        store: DayCueStore,
        notifier: LocalNotificationScheduler = LocalNotificationScheduler()
    ) -> ProactiveGeoCoordinator {
        ProactiveGeoCoordinator(store: store, notifier: notifier)
    }
}
