import XCTest
@testable import DayCueCore

/// 故障注入「只触发一次」这条不变量的测试。
///
/// 为什么值得单独测：注入点写错成「只读不消费」时，App 会在启动恢复的
/// 重试里反复退出，症状是「装上就再也打不开」——那是最难排查的一类问题。
final class OneShotSwitchTests: XCTestCase {

    func testArmedTriggersOnceThenStaysConsumed() {
        var latch = OneShotSwitch(isArmed: true)
        XCTAssertTrue(latch.consumeIfArmed(), "装填状态下第一次应当触发")
        XCTAssertFalse(latch.isArmed, "触发后必须已消费，否则重启会再次退出")
        XCTAssertFalse(latch.consumeIfArmed(), "第二次不得再触发")
    }

    func testDisarmedNeverTriggers() {
        var latch = OneShotSwitch(isArmed: false)
        for _ in 0..<5 {
            XCTAssertFalse(latch.consumeIfArmed(), "未装填时任何一次都不应触发")
        }
    }

    func testRearmAllowsSecondTrigger() {
        var latch = OneShotSwitch(isArmed: true)
        XCTAssertTrue(latch.consumeIfArmed())
        latch.rearm()
        XCTAssertTrue(latch.isArmed)
        XCTAssertTrue(latch.consumeIfArmed(), "重新装填后应可再次触发")
        XCTAssertFalse(latch.consumeIfArmed())
    }

    func testConsumeIsIdempotentAfterFirstTrigger() {
        var latch = OneShotSwitch(isArmed: true)
        let triggers = (0..<10).filter { _ in latch.consumeIfArmed() }.count
        XCTAssertEqual(triggers, 1, "无论读多少次，只有第一次触发")
    }
}
