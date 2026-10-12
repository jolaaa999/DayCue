import Foundation
import XCTest
@testable import DayCueCore

/// 幂等键必须是确定性的：重复点按要命中同一条 outbox 记录，而不是创建第二条外部提醒。
final class IdempotencyKeyTests: XCTestCase {

    func testCreateReminderKeyIsDeterministicForSameInputs() {
        let first = IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A")
        let second = IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A")

        XCTAssertEqual(first, second)
        // 规格：SHA-256 十六进制前 32 位。
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testCreateReminderKeyDiffersWhenListChanges() {
        let listA = IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A")
        let listB = IdempotencyKey.createReminder(taskId: "task_1", listId: "list_B")

        XCTAssertNotEqual(listA, listB)
    }

    func testCreateReminderKeyMatchesSpecifiedAlgorithm() {
        // 直接按规格复算一遍，防止有人把前缀或分隔符改掉之后测试还"碰巧通过"。
        let material = "create_reminder:" + "task_1" + ":" + "list_A"
        let expected = String(SHA256Hex.digest(material).prefix(32))
        XCTAssertEqual(IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A"), expected)
    }

    func testDifferentTaskIdsProduceDifferentKeys() {
        let a = IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A")
        let b = IdempotencyKey.createReminder(taskId: "task_2", listId: "list_A")
        XCTAssertNotEqual(a, b)
    }

    func testExtractKeyChangesWithUserEditedContent() {
        let before = IdempotencyKey.extractCapture(captureId: "cap_1", contentFingerprint: SHA256Hex.digest("明晚八点复习"))
        let after = IdempotencyKey.extractCapture(captureId: "cap_1", contentFingerprint: SHA256Hex.digest("明晚九点复习"))
        XCTAssertNotEqual(before, after)
    }
}
