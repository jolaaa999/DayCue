import Foundation
import XCTest
@testable import DayCueCore

/// 并发写入闸门。
///
/// 这些用例针对的是一类真实缺陷：外部写入会在 await 处让出执行权，
/// 两次并发调用可能都认为"外面还没有这条提醒"，从而各写一条。
final class InFlightWriteGuardTests: XCTestCase {

    func testSecondBeginForSameKeyIsRejected() async {
        let guardrail = InFlightWriteGuard()
        let first = await guardrail.begin("task_1")
        let second = await guardrail.begin("task_1")

        XCTAssertTrue(first)
        XCTAssertFalse(second, "同一个任务同时只允许一个执行者写入")
        XCTAssertEqual(await guardrail.count, 1)
    }

    func testDifferentKeysDoNotBlockEachOther() async {
        let guardrail = InFlightWriteGuard()
        XCTAssertTrue(await guardrail.begin("task_1"))
        XCTAssertTrue(await guardrail.begin("task_2"), "不同任务的写入不应该互相阻塞")
        XCTAssertEqual(await guardrail.count, 2)
    }

    func testEndReleasesKeyForLaterRetry() async {
        let guardrail = InFlightWriteGuard()
        XCTAssertTrue(await guardrail.begin("task_1"))
        await guardrail.end("task_1")

        XCTAssertFalse(await guardrail.isInFlight("task_1"))
        // 失败后重试必须能重新进入，否则任务会被永久锁死。
        XCTAssertTrue(await guardrail.begin("task_1"))
    }

    func testEndOnUnknownKeyIsHarmless() async {
        let guardrail = InFlightWriteGuard()
        await guardrail.end("never_started")
        XCTAssertEqual(await guardrail.count, 0)
    }

    /// 真正并发地抢同一个 key：必须**恰好一个**成功。
    /// 这条用例是本题的核心——如果闸门失效，就会有两个执行者同时去创建外部提醒。
    func testConcurrentBeginsAllowExactlyOneWinner() async {
        let guardrail = InFlightWriteGuard()
        let attempts = 64

        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<attempts {
                group.addTask { await guardrail.begin("task_same") }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }

        XCTAssertEqual(winners, 1, "\(attempts) 次并发抢占必须只有一个赢家")
    }

    /// 释放之后再次并发抢占，同样只能有一个赢家（模拟重试场景反复发生）。
    func testRepeatedRoundTripsStayExclusive() async {
        let guardrail = InFlightWriteGuard()
        for round in 0..<8 {
            let winners = await withTaskGroup(of: Bool.self) { group -> Int in
                for _ in 0..<16 {
                    group.addTask { await guardrail.begin("task_round_\(round)") }
                }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            XCTAssertEqual(winners, 1, "第 \(round) 轮并发抢占出现了多个赢家")
            await guardrail.end("task_round_\(round)")
        }
        XCTAssertEqual(await guardrail.count, 0, "所有 key 都必须被释放，否则后续重试会被永久阻塞")
    }
}
