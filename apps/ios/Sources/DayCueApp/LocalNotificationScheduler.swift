import Foundation
import UserNotifications
import DayCueCore

/// 主动提醒的通知安排器（UNUserNotificationCenter）。
///
/// 与 NotificationService 的分工必须说清楚：
/// - NotificationService 只管**用户明确设置的到点提醒**（任务），走独立策略，不受主动预算限制；
/// - 这里只管**主动提醒**（地点、课后追问），安排前必须已经过 ProactiveBudget。
/// 两条路径共用系统通知中心，但标识前缀不同（daycue.proactive. vs daycue.task.reminder.），
/// 所以各自取消时不会误删对方排的提醒。
final class LocalNotificationScheduler: NSObject, ProactiveNotificationScheduling {

    /// 交互回执的处理器。
    ///
    /// 必须是 static：系统的通知中心 delegate 是进程级的，如果做成实例属性，
    /// 第二个 LocalNotificationScheduler 实例一注册就会把前一个的回执出口覆盖掉，
    /// 表现是「部署了但回执永远不回来」。全局唯一出口才与 delegate 的进程级语义对齐。
    static var onReceipt: ((ProactiveInteractionReceipt) -> Void)?

    /// 注意 UNUserNotificationCenter.delegate 是 weak：必须由一个长期存活的对象持有，
    /// 否则会被立刻释放，通知点击回调永远不会来。
    private static let sharedDelegate = ProactiveNotificationDelegateHandler()

    func installDelegate() {
        Self.sharedDelegate.onReceipt = { receipt in
            Self.onReceipt?(receipt)
        }
        UNUserNotificationCenter.current().delegate = Self.sharedDelegate
    }

    func schedule(_ request: ProactiveNotificationRequest) async -> ProactiveNotificationScheduleResult {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return .notScheduled(reason: "通知权限没有打开，主动提醒不会发出。")
        }

        let interval = request.fireAt.timeIntervalSinceNow
        guard interval >= 1 else {
            // 时间已经过去就不要再补发：补发的提醒只会让人莫名其妙。
            return .notScheduled(reason: "这条提醒的时间已经过去，不再补发。")
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        if let body = request.body, !body.isEmpty {
            content.body = body
        }
        content.sound = .default
        content.userInfo = [
            "dedupe_key": request.dedupeKey,
            "kind": request.kind.rawValue
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let unRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )

        do {
            // 同一个 identifier 重复 add 是替换，不是新增，所以设置变化后重算不会排两条。
            try await UNUserNotificationCenter.current().add(unRequest)
            return .scheduled(identifier: request.identifier, at: request.fireAt)
        } catch {
            return .notScheduled(reason: "安排通知失败：\(error.localizedDescription)")
        }
    }

    func cancel(identifier: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        // 已经弹出来的也要清掉，否则用户会在通知中心里看到一条已经作废的提醒。
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// 当前还排着的主动通知标识。设置变化后重算时用它找出「野注册」。
    func pendingIdentifiers(withPrefix prefix: String) async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map { $0.identifier }.filter { $0.hasPrefix(prefix) })
    }
}

/// 通知交互的接收者。
///
/// 单独一个 NSObject 而不是让 LocalNotificationScheduler 兼任：delegate 是 weak，
/// 由 static 常量持有最稳；回执也只在这里做「系统动作 -> 语义」的翻译，不碰数据库。
final class ProactiveNotificationDelegateHandler: NSObject, UNUserNotificationCenterDelegate {

    var onReceipt: ((ProactiveInteractionReceipt) -> Void)?

    /// 前台也展示主动提醒。地点刚到达时 App 往往正开着，不展示就等于没提醒。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let receipt = Self.receipt(from: response) else { return }
        onReceipt?(receipt)
    }

    /// 把系统动作翻译成语义回执。now 显式传入，方便测试与调试复现。
    static func receipt(
        from response: UNNotificationResponse,
        now: Date = Date()
    ) -> ProactiveInteractionReceipt? {
        let userInfo = response.notification.request.content.userInfo
        guard let dedupeKey = userInfo["dedupe_key"] as? String, !dedupeKey.isEmpty else {
            // 不是主动提醒（例如任务到点提醒）就不该由这里处理。
            return nil
        }

        let interaction: ProactiveInteraction
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            interaction = .opened
        case UNNotificationDismissActionIdentifier:
            interaction = .dismissed
        default:
            interaction = .replied
        }

        let text = (response as? UNTextInputNotificationResponse)?.userText
        return ProactiveInteractionReceipt(
            dedupeKey: dedupeKey,
            interaction: interaction,
            at: now,
            userText: text
        )
    }
}
