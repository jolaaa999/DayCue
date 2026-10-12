import Foundation

/// 同一实体的外部写入互斥闸门。
///
/// 为什么需要它：`applyExternalWrite` 会在写入前查重（`await lookupReminder(forTaskId:)`）处让出主 actor，
/// 两次并发调用（用户连点「确认」或「重试写入」）可能都在查询时看不到对方，
/// 于是各自创建一条外部提醒。数据库层的幂等键只能保证「同一个 key 只有一行 outbox」，
/// 它拦不住「同一时刻两个执行者都决定去写」。
///
/// 因此这里把「写」做成临界区：同一个 taskId 同时只允许一个执行者进入，
/// 后来者在界面上得到「正在写入，请稍候」而不是第二次系统写入。
///
/// 用 actor 而不是普通 Set：调用方可能是不同 actor，互斥必须由类型保证，而不是靠约定。
public actor InFlightWriteGuard {

    private var keys: Set<String> = []

    public init() {}

    /// 尝试占用。返回 false 表示同一个 key 已经有执行者在写，调用方必须放弃本次写入。
    public func begin(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.insert(key)
        return true
    }

    /// 释放。必须在写入流程的**所有**出口调用，否则该任务会被永久卡住。
    public func end(_ key: String) {
        keys.remove(key)
    }

    public func isInFlight(_ key: String) -> Bool {
        keys.contains(key)
    }

    /// 当前占用中的 key 数量。仅用于测试与诊断。
    public var count: Int { keys.count }
}
