import Foundation
import XCTest
@testable import DayCueCore

// 外部快照「两段式查询」的范围映射测试。
//
// 刻意不 import EventKit：真正的适配器在 DayCueApp 里，进不了 DayCueCoreTests。
// 但适配器判定范围时调用的就是 ReminderSnapshotQuery.make / classifyScope，
// 所以这里锁定的正是它在用的那段纯逻辑。
//
// 一旦有人把「查询失败」当成「这些条目不存在」，这些用例必须红 ——
// 那条路径的下一步就是删掉用户的东西。
//
// 注：这部分逻辑已经存在纯函数入口，所以没有为此新增或修改任何核心层文件。

/// 构造一条外部条目快照。只填本文件断言需要的字段。
private func scopeExternal(
    taskId: String?,
    externalId: String,
    isCompleted: Bool = false
) -> ExternalReminderSnapshot {
    ExternalReminderSnapshot(
        taskId: taskId,
        externalId: externalId,
        listId: "list_A",
        listTitle: "提醒",
        title: "买牛奶",
        detail: nil,
        isCompleted: isCompleted,
        dueKind: .none,
        dueLocal: nil,
        remindLocal: nil,
        lastModified: "2026-10-12T10:00:00Z"
    )
}

/// 构造一条已绑定的本地任务快照。
private func scopeLocal(
    taskId: String = "task_1",
    externalId: String? = "ext_1",
    isDeleted: Bool = false
) -> LocalReminderSnapshot {
    LocalReminderSnapshot(
        taskId: taskId,
        title: "买牛奶",
        detail: nil,
        status: .open,
        dueKind: .none,
        dueLocal: nil,
        remindLocal: nil,
        listId: "list_A",
        externalId: externalId,
        isDeleted: isDeleted
    )
}

/// 与上面本地快照内容一致的上次基线，用来制造「曾经同步过」这个前提。
private func scopeBaseline(taskId: String = "task_1") -> ReconciliationBaseline {
    ReconciliationBaseline(
        entityId: taskId,
        provider: ReconciliationEngine.defaultProvider,
        state: ReminderComparableState(
            title: "买牛奶",
            detail: nil,
            status: .open,
            dueKind: .none,
            dueLocal: nil,
            remindLocal: nil,
            listId: "list_A"
        ),
        capturedAt: "2026-10-11T10:00:00Z"
    )
}

final class ExternalSnapshotScopeTests: XCTestCase {

    // MARK: - 两段查询 -> 可信范围

    func testBothSegmentsSucceedIsComplete() {
        let scope = ReminderSnapshotQuery.classifyScope(
            authorized: true,
            incompleteSucceeded: true,
            completedSucceeded: true
        )
        XCTAssertEqual(scope, .complete)
        XCTAssertTrue(scope.allowsDeletionPropagation, "只有两段都成功才允许传播删除")
    }

    /// 一段成功一段失败：无论缺的是哪一段，都只能算「不完整」。
    func testOneSegmentFailedIsAlwaysIncomplete() {
        let combinations: [(Bool, Bool)] = [(true, false), (false, true)]
        for (incompleteSucceeded, completedSucceeded) in combinations {
            let scope = ReminderSnapshotQuery.classifyScope(
                authorized: true,
                incompleteSucceeded: incompleteSucceeded,
                completedSucceeded: completedSucceeded
            )
            XCTAssertEqual(scope, .incomplete(.incompleteScope), "只查成一段就不能算完整")
            XCTAssertFalse(scope.allowsDeletionPropagation, "范围不完整时绝不允许任何删除")
        }
    }

    func testBothSegmentsFailedIsQueryFailed() {
        let scope = ReminderSnapshotQuery.classifyScope(
            authorized: true,
            incompleteSucceeded: false,
            completedSucceeded: false
        )
        XCTAssertEqual(scope, .incomplete(.queryFailed))
        XCTAssertFalse(scope.allowsDeletionPropagation)
    }

    /// 没权限时哪怕两段都「返回成功」也不能算完整：读不到不等于不存在。
    func testMissingAuthorizationIsNeverComplete() {
        let scope = ReminderSnapshotQuery.classifyScope(
            authorized: false,
            incompleteSucceeded: true,
            completedSucceeded: true
        )
        XCTAssertEqual(scope, .incomplete(.notAuthorized))
        XCTAssertFalse(scope.allowsDeletionPropagation)
    }

    // MARK: - 失败语义不许被当成「条目不存在」

    /// 一段成功、一段失败：失败段即使带了条目也不能进入结果，
    /// 否则下游会把「没查成」当成「这条确实存在」。
    func testFailedSegmentItemsNeverLeakIntoResult() {
        let fetch = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: ReminderSnapshotSegment(
                succeeded: false,
                items: [scopeExternal(taskId: "task_leak", externalId: "ext_leak")]
            ),
            completed: .ok([scopeExternal(taskId: "task_ok", externalId: "ext_ok", isCompleted: true)])
        )
        XCTAssertEqual(fetch.scope, .incomplete(.incompleteScope))
        XCTAssertEqual(fetch.items.map(\.externalId), ["ext_ok"], "失败段的条目必须被丢掉")
    }

    func testBothSegmentsSucceededKeepsEveryItem() {
        let fetch = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: .ok([scopeExternal(taskId: "task_open", externalId: "ext_open")]),
            completed: .ok([scopeExternal(taskId: "task_done", externalId: "ext_done", isCompleted: true)])
        )
        XCTAssertEqual(fetch.scope, .complete)
        XCTAssertEqual(Set(fetch.items.map(\.externalId)), ["ext_open", "ext_done"])
    }

    /// 两段都成功返回空，才是可信的「确实没有」。
    /// 这也正是适配器要把「回调收到 nil」翻译成 ReminderSnapshotSegment.failed 的原因：
    /// 空数组与失败必须表达成两种不同的东西。
    func testEmptySuccessfulSegmentIsNotAFailure() {
        let fetch = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: .ok([]),
            completed: .ok([])
        )
        XCTAssertEqual(fetch.scope, .complete)
        XCTAssertTrue(fetch.items.isEmpty)
        XCTAssertTrue(fetch.scope.allowsDeletionPropagation)
    }

    // MARK: - 端到端：查询失败绝不产出删除

    /// 最关键的一条：一条已绑定的任务，外部条目因为「某一段没查成」而没出现在快照里，
    /// 引擎必须给 noop，绝不能产出 markExternalDeleted。
    func testFailedSegmentNeverTurnsIntoExternalDeletion() {
        let fetch = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: .failed,
            completed: .ok([])
        )
        let plan = ReconciliationEngine.reconcile(
            local: [scopeLocal()],
            external: fetch,
            previous: [scopeBaseline()]
        )
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")], "查询失败不能变成删除决策")
        XCTAssertFalse(plan.hasDeletionPropagation)
        XCTAssertTrue(
            plan.anomalies.contains { anomaly in
                if case .skippedDueToIncompleteScope = anomaly { return true }
                return false
            },
            "被跳过的记录必须显式告诉用户，否则界面会显示成「没有冲突」"
        )
    }

    /// 对照组：两段都成功、外部确实没有这条时，才允许产出删除决策；
    /// 而且它依然是需要用户确认的删除，绝不自动应用。
    func testCompleteScopeMissingItemRequiresConfirmation() {
        let fetch = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: .ok([]),
            completed: .ok([])
        )
        let plan = ReconciliationEngine.reconcile(
            local: [scopeLocal()],
            external: fetch,
            previous: [scopeBaseline()]
        )
        // 先解包再匹配：这样写不依赖「可选模式」的简写，含义更直白。
        guard let firstDecision = plan.decisions.first,
              case let .markExternalDeleted(entityId, externalId, requiresUserConfirmation) = firstDecision else {
            return XCTFail("完整范围下外部确实消失，应产出 markExternalDeleted，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(entityId, "task_1")
        XCTAssertEqual(externalId, "ext_1")
        XCTAssertTrue(requiresUserConfirmation, "外部删除永远要用户确认")
        XCTAssertFalse(plan.decisions[0].canApplyAutomatically, "确认类决策绝不允许自动应用")
        XCTAssertTrue(plan.isComplete)
    }
}
