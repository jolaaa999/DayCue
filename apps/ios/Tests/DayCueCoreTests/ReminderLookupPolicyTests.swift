import Foundation
import XCTest
@testable import DayCueCore

/// 查重结论的分类。
///
/// 这是"重试不产生重复提醒"的判定核心：只有 notFound 才允许继续创建。
final class ReminderLookupPolicyTests: XCTestCase {

    func testFoundInIncompleteScope() {
        let outcome = ReminderLookupPolicy.classify(
            authorized: true,
            incomplete: .ok(match: "ext_1"),
            completed: .ok(match: nil)
        )
        XCTAssertEqual(outcome, .found)
        XCTAssertFalse(outcome.allowsCreatingNew)
    }

    /// 用户可能在苹果侧把提醒勾成已完成。只看未完成项就会"找不到"然后重建一条。
    func testFoundInCompletedScopeOnly() {
        let outcome = ReminderLookupPolicy.classify(
            authorized: true,
            incomplete: .ok(match: nil),
            completed: .ok(match: "ext_done")
        )
        XCTAssertEqual(outcome, .found, "已完成项也必须纳入查重范围")
    }

    func testNotFoundOnlyWhenBothScopesSucceededAndEmpty() {
        let outcome = ReminderLookupPolicy.classify(
            authorized: true,
            incomplete: .ok(match: nil),
            completed: .ok(match: nil)
        )
        XCTAssertEqual(outcome, .notFound)
        XCTAssertTrue(outcome.allowsCreatingNew)
        XCTAssertFalse(outcome.requiresUserAttention)
    }

    func testNoAuthorizationNeverAllowsCreating() {
        let outcome = ReminderLookupPolicy.classify(
            authorized: false,
            incomplete: .ok(match: nil),
            completed: .ok(match: nil)
        )
        XCTAssertEqual(outcome, .notAuthorized)
        XCTAssertFalse(outcome.allowsCreatingNew)
        XCTAssertTrue(outcome.requiresUserAttention)
    }

    func testBothScopesFailedIsQueryFailed() {
        let outcome = ReminderLookupPolicy.classify(
            authorized: true,
            incomplete: .failed,
            completed: .failed
        )
        XCTAssertEqual(outcome, .queryFailed)
        XCTAssertFalse(outcome.allowsCreatingNew, "查询失败绝不能当成没找到")
        XCTAssertTrue(outcome.requiresUserAttention)
    }

    func testOneScopeFailedIsIncompleteScope() {
        for (incomplete, completed) in [
            (ReminderLookupPolicy.Fetch.ok(match: nil), ReminderLookupPolicy.Fetch.failed),
            (ReminderLookupPolicy.Fetch.failed, ReminderLookupPolicy.Fetch.ok(match: nil))
        ] {
            let outcome = ReminderLookupPolicy.classify(
                authorized: true,
                incomplete: incomplete,
                completed: completed
            )
            XCTAssertEqual(outcome, .incompleteScope, "只查了一部分就不能断言不存在")
            XCTAssertFalse(outcome.allowsCreatingNew)
        }
    }

    /// 命中优先于"另一段查询失败"：已经确定外部存在，就不该再创建。
    func testMatchWinsOverOtherScopeFailure() {
        let outcome = ReminderLookupPolicy.classify(
            authorized: true,
            incomplete: .ok(match: "ext_hit"),
            completed: .failed
        )
        XCTAssertEqual(outcome, .found)
        XCTAssertFalse(outcome.allowsCreatingNew)
    }

    /// 枚举出全部结论，确保只有 notFound 是"可以继续创建"。
    func testOnlyNotFoundAllowsCreating() {
        let creatable = ReminderLookupOutcome.allCases.filter { $0.allowsCreatingNew }
        XCTAssertEqual(creatable, [.notFound])
    }
}
