import Foundation
import UserNotifications
import DayCueCore

/// 本地通知。
///
/// 边界很清楚：**只负责 App 内部的到点提醒**。
/// 如果同一条任务的到点提醒已经交给苹果提醒事项，就绝不再安排本地通知，
/// 否则用户会收到两次提醒（设计文档 9.1）。
@MainActor
final class NotificationService: ObservableObject {

    static let identifierPrefix = "daycue.task.reminder."

    @Published private(set) var lastError: String?

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 为任务安排本地提醒。
    ///
    /// 返回 false 表示"没有安排"（权限没开、没有提醒时刻、或已交给苹果提醒事项）。
    /// 调用方必须把 false 当成正常结果，不能显示成"已设置提醒"。
    @discardableResult
    func scheduleReminder(for task: TaskRecord) async -> Bool {
        // 苹果提醒事项已经在管这条任务的到点提醒，App 不再重复发。
        guard task.externalWriteState != .written else { return false }
        guard let components = reminderComponents(for: task) else { return false }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        if let detail = task.detail, !detail.isEmpty {
            content.body = detail
        } else {
            content.body = TaskTimeDisplay.scheduleSummary(for: task)
        }
        content.sound = .default
        content.userInfo = ["task_id": task.id]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + task.id,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func cancelReminder(taskId: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.identifierPrefix + taskId])
    }

    /// 提醒时刻落到"用户当时所在时区"的日历分量上。
    /// 这里用 remind_local（墙上时间）而不是 remind_utc：用户设的是"晚上八点响"，
    /// 跨时区旅行后应该还是当地晚上八点。
    private func reminderComponents(for task: TaskRecord) -> DateComponents? {
        guard let local = task.remindLocal else { return nil }
        guard let date = RFC3339.date(fromLocal: local, timeZone: TimeZone(identifier: task.timezone) ?? .current) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: task.timezone) ?? .current
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}
