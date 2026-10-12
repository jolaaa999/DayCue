import Foundation

/// 一次性开关。
///
/// 为什么需要它：故障注入必须**先消费再触发**。
/// 如果只是「读一下开关然后就退出」，进程重启后开关仍然开着，
/// 启动恢复里的重试会再次命中同一个注入点，于是反复退出、App 永远打不开。
/// 把「消费」这一步单独建模，是为了让这条不变量能被单元测试证明
/// （注入点本身在 App target，依赖 EventKit，测不到）。
public struct OneShotSwitch: Equatable, Sendable {

    /// 是否处于「已装填」状态。消费过之后必然为 false。
    public private(set) var isArmed: Bool

    public init(isArmed: Bool) {
        self.isArmed = isArmed
    }

    /// 消费并返回本次是否应当触发。返回 true 之后 `isArmed` 一定为 false。
    ///
    /// 调用方必须在执行副作用（写日志、退出进程）**之前**先把新的
    /// `isArmed` 持久化，否则重启后仍会再次触发。
    public mutating func consumeIfArmed() -> Bool {
        guard isArmed else { return false }
        isArmed = false
        return true
    }

    /// 重新装填，供人工再次复现同一个中断窗口。
    public mutating func rearm() {
        isArmed = true
    }
}
