import Foundation
import Combine
import DayCueCore

/// 课后追问通知的编排者。
///
/// 追问时间由 FollowUpScheduler 算（已存在），这里只接两件事：
/// 1. 安排前检查：给 FollowUpNotificationPlanner 传账本 + 预算配置，抑制的绝不安排；
/// 2. 设置变化后重算：把所有旧的追问通知取消，再按新预算重新安排。
///
/// 刻意不安排「到点运行后台 AI」：通知是提前排好的本地通知，
/// 预算与静默必须在这一刻就判完。
///
/// 谁调用它：AppContainer（需要主会话加一行）在启动/回前台时，
/// 以及 ProactiveSettingsView 保存设置之后（需要主会话加一行调用）。
@MainActor
final class FollowUpNotificationCoordinator: ObservableObject {

    private let store: DayCueStore
    private let notifier: LocalNotificationScheduler

    @Published private(set) var lastSummary: String?

    init(store: DayCueStore, notifier: LocalNotificationScheduler = LocalNotificationScheduler()) {
        self.store = store
        self.notifier = notifier
    }

    /// 按当前设置重新计算并取消旧请求。
    func reapplyFromSettings(at now: Date = Date()) async {
        let timeZone = TimeZone.current
        let config = ProactiveBudgetConfigCodec.decode(store.setting(ProactiveSettingsKey.config))

        let followUps = (try? store.followUps(limit: 2000)) ?? []
        let courses = (try? store.courses(includeDeleted: true, limit: 500)) ?? []
        var coursesById: [String: CourseRecord] = [:]
        for course in courses { coursesById[course.id] = course }

        // 账本往前多取一天：跨零点的冷却需要看到昨晚发出的记录。
        let dayStart = ProactiveBudget.startOfLocalDay(for: now, timeZone: timeZone)
            ?? now.addingTimeInterval(-86400)
        let ledger = (try? store.proactiveLedger(since: dayStart.addingTimeInterval(-86400), limit: 2000)) ?? []

        // 只看追问自己的通知。用更长的前缀，避免把地点提醒误当成「旧追问请求」取消掉。
        let followUpPrefix = ProactiveNotificationIdentifier.identifier(
            forDedupeKey: FollowUpNotificationPlanner.dedupeKeyPrefix
        )
        let pending = await notifier.pendingIdentifiers(withPrefix: followUpPrefix)

        let plan = FollowUpNotificationPlanner.plan(
            followUps: followUps,
            coursesById: coursesById,
            ledger: ledger,
            config: config,
            timeZone: timeZone,
            now: now,
            currentlyScheduledIdentifiers: pending
        )

        let runner = FollowUpNotificationRunner(store: store, notifier: notifier)
        do {
            let outcome = try await runner.apply(plan, at: now)
            var summary = "课后追问通知：新安排 \(outcome.scheduledCount) 条，取消 \(outcome.cancelledCount) 条旧请求，抑制 \(outcome.suppressedCount) 条。"
            if let warning = plan.warnings.first {
                summary += " 注意：\(warning)"
            }
            lastSummary = summary
        } catch {
            lastSummary = "重新安排课后追问通知失败：\(error)"
        }
    }
}
