#if DEBUG
import Foundation

/// 仅 Debug 构建存在的故障注入点。
///
/// 为什么需要它：「EventKit 保存成功」与「本地绑定/回执落库」之间有一个真实窗口，
/// 进程在这个窗口里被杀，就会留下「外部已有一条、本地却以为没写」的状态。
/// 这个窗口只有几十毫秒，靠人工强杀几乎不可能稳定命中，
/// 所以需要一个显式开关把它变成可重复的测试。
///
/// 默认关闭；只在 Debug 构建下编译进包，Release 里根本不存在这个符号。
enum DebugWriteFaultInjection {

    /// UserDefaults 键。设置页的开关只写到这个键上。
    static let defaultsKey = "daycue.debug.faultAfterExternalSave"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// 在「外部已保存、本地尚未落库」处中断进程。
    ///
    /// 用 exit(0) 而不是 abort()：这里要验证的是崩溃窗口之后的恢复，
    /// 不是崩溃上报；干净退出能让测试者明确知道是注入点触发的。
    ///
    /// **必须先消费再退出。** 否则进程重启后开关仍然开着，
    /// 启动恢复的重试会再次走到这里，形成"每次启动都退出"的死循环。
    /// 因此顺序固定为：消费 → 落盘 → 写日志 → 退出。
    static func haltIfEnabled() {
        var latch = OneShotSwitch(isArmed: isEnabled)
        guard latch.consumeIfArmed() else { return }

        // 先把消费结果落盘：这一步是"只触发一次"在重启后依然成立的唯一依据。
        // exit(0) 可能来不及触发 UserDefaults 的周期性写回，所以显式 synchronize。
        isEnabled = latch.isArmed
        UserDefaults.standard.synchronize()

        let message = "[DayCue] 故障注入已触发并已消费（一次性）：外部提醒已写入，本地绑定与回执尚未落库，进程即将退出。\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(0)
    }
}
#endif
