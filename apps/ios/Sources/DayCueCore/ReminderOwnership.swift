import Foundation

// 提醒归属。
//
// 一条任务的到点提醒只能有一个执行方：要么是苹果提醒事项里的 EKAlarm，
// 要么是 App 的本地通知。两边都排 = 用户收到两次提醒；
// 切换执行方时不先取消旧的 = 同样两次。这个文件把这条规则做成纯函数，
// 让界面和写入链都不需要各自再判断一遍。

/// 提醒执行方。
public enum ReminderExecutor: String, Codable, CaseIterable, Sendable {
    /// 不安排任何提醒（已完成、已取消，或只有截止日没有提醒时刻）。
    case none
    /// 苹果提醒事项的 EKAlarm。
    case appleReminders = "apple_reminders"
    /// App 的本地通知。
    case localNotification = "local_notification"

    public var displayName: String {
        switch self {
        case .none: return "不安排提醒"
        case .appleReminders: return "苹果提醒事项"
        case .localNotification: return "App 本地通知"
        }
    }
}

/// 当前已经排出去的提醒。
///
/// 之所以要显式记录「排过没有」，是因为「不需要提醒」和「需要取消已有提醒」
/// 是两种完全不同的动作：漏掉后者就会留下一个再也不会被覆盖的陈旧通知。
public struct ReminderSchedulingState: Equatable, Sendable {
    public let hasLocalNotificationScheduled: Bool
    public let hasExternalAlarm: Bool

    public init(
        hasLocalNotificationScheduled: Bool = false,
        hasExternalAlarm: Bool = false
    ) {
        self.hasLocalNotificationScheduled = hasLocalNotificationScheduled
        self.hasExternalAlarm = hasExternalAlarm
    }

    public static let none = ReminderSchedulingState()
}

/// 需要取消的已排提醒。
///
/// 这里只描述「取消什么」，不带具体的系统 API 与标识符前缀：
/// 本地通知的 identifier 前缀定义在 DayCueApp 的 NotificationService 里，
/// 在核心层复制一份字符串迟早会两边不一致。由调用方负责把描述翻译成真实调用。
public enum ReminderCancellation: Equatable, Sendable {
    case localNotification(taskId: String)
    case externalAlarm(taskId: String, externalId: String?)

    public var taskId: String {
        switch self {
        case let .localNotification(taskId): return taskId
        case let .externalAlarm(taskId, _): return taskId
        }
    }

    public var displayName: String {
        switch self {
        case .localNotification: return "取消 App 本地通知"
        case .externalAlarm: return "取消苹果提醒事项里的提醒"
        }
    }
}

/// 一条任务的提醒归属判定结果。
public struct ReminderOwnershipDecision: Equatable, Sendable {
    public let taskId: String
    /// 谁应该负责这条任务的到点提醒。
    public let executor: ReminderExecutor
    /// 必须被取消的已排提醒；顺序固定为「先本地、后外部」，便于幂等重放。
    public let cancellations: [ReminderCancellation]
    /// 是否需要为当前执行方安排提醒。
    public let shouldSchedule: Bool
    public let note: String

    public init(
        taskId: String,
        executor: ReminderExecutor,
        cancellations: [ReminderCancellation],
        shouldSchedule: Bool,
        note: String
    ) {
        self.taskId = taskId
        self.executor = executor
        self.cancellations = cancellations
        self.shouldSchedule = shouldSchedule
        self.note = note
    }

    /// 是否发生了执行方切换（有旧通知要清理）。
    public var switchedExecutor: Bool { !cancellations.isEmpty }
}

public enum ReminderOwnership {

    /// 提醒归属判定。
    ///
    /// 判定顺序不能颠倒：
    /// 1. 任务不再待办 → 谁都不排，并且两侧都要取消。
    /// 2. 没有提醒时刻（日期型截止日）→ 谁都不排，但仍然要取消可能存在的旧通知。
    /// 3. 已确认写入苹果提醒事项 → 由 EKAlarm 负责，取消本地通知。
    /// 4. 其余状态（未请求 / 等授权 / 写入中 / 失败 / 状态未知）→ App 本地通知兜底。
    ///
    /// 第 4 条沿用了现有写入链的约定：external_write_state != written 时按「外部还没接管」处理。
    public static func decide(
        taskId: String,
        externalWriteState: ExternalWriteState,
        status: TaskStatus,
        hasRemindTime: Bool,
        externalId: String?,
        scheduling: ReminderSchedulingState
    ) -> ReminderOwnershipDecision {
        let executor: ReminderExecutor
        let note: String

        if status != .open {
            executor = .none
            note = "任务已完成或已取消，两侧的提醒都要取消。"
        } else if !hasRemindTime {
            executor = .none
            note = "这条任务没有提醒时刻（只有截止日），两侧都不排提醒。"
        } else if externalWriteState == .written {
            executor = .appleReminders
            note = "已确认写入苹果提醒事项，由 EKAlarm 负责到点提醒。"
        } else {
            executor = .localNotification
            note = "尚未确认写入苹果提醒事项（\(externalWriteState.displayName)），由 App 本地通知兜底。"
        }

        // 切换执行方必须先取消旧的。取消列表按「本地在前、外部在后」固定顺序产出。
        var cancellations: [ReminderCancellation] = []
        if scheduling.hasLocalNotificationScheduled, executor != .localNotification {
            cancellations.append(.localNotification(taskId: taskId))
        }
        if scheduling.hasExternalAlarm, executor != .appleReminders {
            cancellations.append(.externalAlarm(taskId: taskId, externalId: externalId))
        }

        return ReminderOwnershipDecision(
            taskId: taskId,
            executor: executor,
            cancellations: cancellations,
            shouldSchedule: executor != .none,
            note: note
        )
    }

    /// 从任务记录直接判定。externalId 来自 external_binding。
    public static func decide(
        for task: TaskRecord,
        externalId: String?,
        scheduling: ReminderSchedulingState
    ) -> ReminderOwnershipDecision {
        decide(
            taskId: task.id,
            externalWriteState: task.externalWriteState,
            status: task.status,
            hasRemindTime: hasRemindTime(task),
            externalId: externalId,
            scheduling: scheduling
        )
    }

    /// 任务是否设置了提醒时刻。
    /// 只认 remind_local：remind_utc 是同一个时刻的另一种表示，单独有值不算数。
    public static func hasRemindTime(_ task: TaskRecord) -> Bool {
        guard let remind = task.remindLocal else { return false }
        return !remind.isEmpty
    }
}
