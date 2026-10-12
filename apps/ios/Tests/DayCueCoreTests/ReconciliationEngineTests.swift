import Foundation
import XCTest
@testable import DayCueCore

// 三方比较的测试夹具。
//
// 全部是纯值构造，不碰数据库：引擎本身是纯函数，这样才可以在没有 EventKit 的环境里验证。

private func baseState(
    title: String = "交实验报告",
    detail: String? = nil,
    status: TaskStatus = .open,
    dueKind: DueKind = .none,
    dueLocal: String? = nil,
    remindLocal: String? = nil,
    listId: String? = "list_A"
) -> ReminderComparableState {
    ReminderComparableState(
        title: title,
        detail: detail,
        status: status,
        dueKind: dueKind,
        dueLocal: dueLocal,
        remindLocal: remindLocal,
        listId: listId
    )
}

private func localSnapshot(
    id: String = "task_1",
    title: String = "交实验报告",
    detail: String? = nil,
    status: TaskStatus = .open,
    dueKind: DueKind = .none,
    dueLocal: String? = nil,
    remindLocal: String? = nil,
    listId: String? = "list_A",
    externalId: String? = "ext_1",
    isDeleted: Bool = false
) -> LocalReminderSnapshot {
    LocalReminderSnapshot(
        taskId: id,
        title: title,
        detail: detail,
        status: status,
        dueKind: dueKind,
        dueLocal: dueLocal,
        remindLocal: remindLocal,
        listId: listId,
        externalId: externalId,
        isDeleted: isDeleted
    )
}

private func externalSnapshot(
    taskId: String? = "task_1",
    externalId: String = "ext_1",
    listId: String? = "list_A",
    title: String = "交实验报告",
    detail: String? = nil,
    isCompleted: Bool = false,
    dueKind: DueKind = .none,
    dueLocal: String? = nil,
    remindLocal: String? = nil,
    lastModified: String? = "2026-10-12T10:00:00Z"
) -> ExternalReminderSnapshot {
    ExternalReminderSnapshot(
        taskId: taskId,
        externalId: externalId,
        listId: listId,
        listTitle: nil,
        title: title,
        detail: detail,
        isCompleted: isCompleted,
        dueKind: dueKind,
        dueLocal: dueLocal,
        remindLocal: remindLocal,
        lastModified: lastModified
    )
}

private func baseline(
    id: String = "task_1",
    state: ReminderComparableState,
    provider: String = "apple_reminders"
) -> ReconciliationBaseline {
    ReconciliationBaseline(entityId: id, provider: provider, state: state, capturedAt: "2026-10-12T10:00:00Z")
}

private func containsAdopt(_ plan: ReconciliationPlan) -> Bool {
    plan.decisions.contains { if case .adoptExternal = $0 { return true }; return false }
}

private func containsPush(_ plan: ReconciliationPlan) -> Bool {
    plan.decisions.contains { if case .pushLocal = $0 { return true }; return false }
}

final class ReconciliationEngineTests: XCTestCase {

    // MARK: - 三方一致

    func testThreeWayConsistentIsAllNoop() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot()],
            external: .complete([externalSnapshot()]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.isComplete)
        XCTAssertFalse(plan.hasDeletionPropagation)
    }

    /// 幂等的真实含义：把第一轮的决策应用下去之后，第二轮必须全部 noop。
    func testSecondRunIsAllNoopAfterApplyingExternalDecisions() {
        let start = baseState()
        let external = externalSnapshot(title: "交实验报告（苹果改）")

        let first = ReconciliationEngine.reconcile(
            local: [localSnapshot()],
            external: .complete([external]),
            previous: [baseline(state: start)]
        )
        XCTAssertEqual(first.decisions.count, 1)

        var resolved = start
        for decision in first.decisions {
            guard case let .adoptExternal(_, differences) = decision else { continue }
            for difference in differences {
                resolved = resolved.applying(difference, from: .external)
            }
        }

        let localAfter = LocalReminderSnapshot(
            taskId: "task_1",
            title: resolved.title,
            detail: resolved.detail,
            status: resolved.status,
            dueKind: resolved.dueKind,
            dueLocal: resolved.dueLocal,
            remindLocal: resolved.remindLocal,
            listId: resolved.listId,
            externalId: "ext_1"
        )
        let second = ReconciliationEngine.reconcile(
            local: [localAfter],
            external: .complete([external]),
            previous: [baseline(state: ReminderComparableState(external: external))]
        )
        XCTAssertEqual(second.decisions, [.noop(entityId: "task_1")])
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - 外部完成

    func testExternalCompletionIsAdoptedAndLocalNoLongerTodo() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(status: .open)],
            external: .complete([externalSnapshot(isCompleted: true)]),
            previous: [baseline(state: baseState(status: .open))]
        )
        XCTAssertEqual(plan.decisions.count, 1)
        guard case let .adoptExternal(entityId, differences) = plan.decisions.first? else {
            return XCTFail("外部完成应产出 adoptExternal，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(entityId, "task_1")
        XCTAssertEqual(differences.map(\.field), [.status])
        XCTAssertEqual(differences[0].preferredSource, .external)
        XCTAssertEqual(differences[0].localValue, TaskStatus.open.rawValue)
        XCTAssertEqual(differences[0].externalValue, TaskStatus.done.rawValue)
        XCTAssertFalse(containsPush(plan), "外部已完成时不允许再把本地状态推回外部")
    }

    // MARK: - 外部删除

    func testExternalDeletionIsReportedAndNeverRecreates() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(externalId: "ext_1")],
            external: .complete([]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertEqual(plan.decisions, [.markExternalDeleted(
            entityId: "task_1",
            externalId: "ext_1",
            requiresUserConfirmation: true
        )])
        XCTAssertTrue(plan.hasDeletionPropagation)
        XCTAssertEqual(plan.deletionDecisionCount, 1)
        XCTAssertEqual(plan.requiresUserConfirmationCount, 1)
        // 删除外部条目不可逆，绝不允许自动应用。
        XCTAssertTrue(plan.decisions[0].requiresUserConfirmation)
        XCTAssertFalse(plan.decisions[0].canApplyAutomatically)
        // 外部已删时绝不能反过来重建外部对象。
        XCTAssertFalse(containsPush(plan))
        XCTAssertFalse(containsAdopt(plan))
    }

    /// 用户手改备注、把 DayCue 标识行弄没了时，外部条目会"看起来消失了"。
    /// 这种删除必须等用户确认，并且要留下"标识行丢失"的异常供人工核对。
    func testExternalItemLosingIdentifierStillRequiresConfirmationBeforeDeletion() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(externalId: "ext_1")],
            // externalId 还在，但备注里已经没有 DayCue 任务 ID。
            external: .complete([externalSnapshot(taskId: nil, externalId: "ext_1")]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertEqual(plan.decisions, [.markExternalDeleted(
            entityId: "task_1",
            externalId: "ext_1",
            requiresUserConfirmation: true
        )])
        XCTAssertTrue(plan.decisions[0].requiresUserConfirmation)
        XCTAssertFalse(plan.decisions[0].canApplyAutomatically)
        guard case let .externalItemLostDayCueIdentifier(taskId, externalId)? = plan.anomalies.first else {
            return XCTFail("应记录标识行丢失，实际是 \(plan.anomalies)")
        }
        XCTAssertEqual(taskId, "task_1")
        XCTAssertEqual(externalId, "ext_1")
        // 本轮不存在任何可直接应用的删除。
        XCTAssertTrue(plan.decisions.allSatisfy { !$0.canApplyAutomatically })
    }

    func testLocalDeletionPropagatesOnlyWhenScopeComplete() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(isDeleted: true)],
            external: .complete([externalSnapshot()]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertEqual(plan.decisions, [.markLocalDeleted(entityId: "task_1", externalId: "ext_1")])
        XCTAssertTrue(plan.isComplete)
    }

    // MARK: - 移动清单

    func testExternalMoveToAnotherListUpdatesOwnershipWithoutRecreating() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(listId: "list_A")],
            external: .complete([externalSnapshot(listId: "list_B")]),
            previous: [baseline(state: baseState(listId: "list_A"))]
        )
        guard case let .adoptExternal(entityId, differences) = plan.decisions.first? else {
            return XCTFail("移动清单应产出 adoptExternal，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(entityId, "task_1")
        XCTAssertEqual(differences.map(\.field), [.list])
        XCTAssertEqual(differences[0].previousValue, "list_A")
        XCTAssertEqual(differences[0].localValue, "list_A")
        XCTAssertEqual(differences[0].externalValue, "list_B")
        XCTAssertEqual(differences[0].preferredSource, .external)
        // 只是改归属，不是重建：不允许出现把本地整条推过去（那会被执行方当成新建）。
        XCTAssertFalse(containsPush(plan))
    }

    // MARK: - 冲突

    func testSameFieldChangedOnBothSidesBecomesConflictAndIsNotAutoResolved() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(title: "交实验报告（本地改）")],
            external: .complete([externalSnapshot(title: "交实验报告（苹果改）")]),
            previous: [baseline(state: baseState())]
        )
        guard case let .markConflict(entityId, differences) = plan.decisions.first? else {
            return XCTFail("同字段双改必须产出 markConflict，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(entityId, "task_1")
        let conflicting = differences.filter(\.isConflict)
        XCTAssertEqual(conflicting.map(\.field), [.title])
        XCTAssertNil(conflicting[0].preferredSource, "冲突字段不允许由引擎指定用哪一边")
        XCTAssertNil(conflicting[0].preferredValue)
        XCTAssertEqual(conflicting[0].localValue, "交实验报告（本地改）")
        XCTAssertEqual(conflicting[0].externalValue, "交实验报告（苹果改）")
        XCTAssertEqual(plan.conflictedEntityCount, 1)
        XCTAssertEqual(plan.conflictedFieldCount, 1)
        // 冲突那一轮不允许顺带产出替用户做决定的 adopt / push。
        XCTAssertFalse(containsAdopt(plan))
        XCTAssertFalse(containsPush(plan))
    }

    func testMissingBaselineWithDifferentContentIsConflict() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(title: "本地标题")],
            external: .complete([externalSnapshot(title: "外部标题")]),
            previous: []
        )
        guard case let .markConflict(_, differences) = plan.decisions.first? else {
            return XCTFail("没有基线时无法归因，必须当冲突，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(differences.map(\.field), [.title])
        XCTAssertTrue(differences.allSatisfy(\.isConflict))
        XCTAssertNil(differences[0].preferredSource)
    }

    func testMissingBaselineWithIdenticalContentIsNoop() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot()],
            external: .complete([externalSnapshot()]),
            previous: []
        )
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
    }

    // MARK: - 单方修改

    func testLocalOnlyChangePushesLocal() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(title: "交实验报告（本地改）")],
            external: .complete([externalSnapshot()]),
            previous: [baseline(state: baseState())]
        )
        guard case let .pushLocal(entityId, differences) = plan.decisions.first? else {
            return XCTFail("本地单方修改应产出 pushLocal，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(entityId, "task_1")
        XCTAssertEqual(differences.map(\.field), [.title])
        XCTAssertEqual(differences[0].preferredSource, .local)
        XCTAssertEqual(differences[0].preferredValue, "交实验报告（本地改）")
        XCTAssertFalse(containsAdopt(plan))
    }

    func testExternalOnlyChangeAdoptsExternal() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(dueKind: .date, dueLocal: "2026-10-16")],
            external: .complete([externalSnapshot(dueKind: .date, dueLocal: "2026-10-20")]),
            previous: [baseline(state: baseState(dueKind: .date, dueLocal: "2026-10-16"))]
        )
        guard case let .adoptExternal(_, differences) = plan.decisions.first? else {
            return XCTFail("外部单方修改应产出 adoptExternal，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(differences.map(\.field), [.due])
        XCTAssertEqual(differences[0].preferredSource, .external)
        XCTAssertEqual(differences[0].previousValue, "date|2026-10-16")
        XCTAssertEqual(differences[0].externalValue, "date|2026-10-20")
        XCTAssertFalse(containsPush(plan))
    }

    func testEmptyStringAndNilDetailAreTheSameValue() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(detail: nil)],
            external: .complete([externalSnapshot(detail: "")]),
            previous: [baseline(state: baseState(detail: nil))]
        )
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
    }

    // MARK: - 查询失败

    func testIncompleteQueryMarksPlanIncompleteAndForbidsDeletion() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot()],
            external: .incomplete(.queryFailed),
            previous: [baseline(state: baseState())]
        )
        XCTAssertFalse(plan.isComplete)
        XCTAssertFalse(plan.hasDeletionPropagation)
        XCTAssertFalse(plan.decisions.contains(where: \.isDeletionPropagation))
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
        // 被跳过的已绑定记录必须显式记录，否则界面会显示"没有冲突"。
        XCTAssertTrue(plan.anomalies.contains { if case .skippedDueToIncompleteScope = $0 { return true }; return false })
    }

    func testIncompleteQueryAlsoForbidsLocalDeletionPropagation() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(isDeleted: true)],
            external: .incomplete(.incompleteScope, partialItems: [externalSnapshot()]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertFalse(plan.isComplete)
        XCTAssertFalse(plan.decisions.contains(where: \.isDeletionPropagation))
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
    }

    /// 范围不完整时，已绑定记录即使看到了外部改动也不许 adopt / push：
    /// 拿残缺数据覆盖本地，比"晚一轮再同步"严重得多。
    func testIncompleteScopeSkipsBoundRecordWithoutAdoptOrPush() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(title: "交实验报告（本地改）")],
            external: .incomplete(.incompleteScope, partialItems: [externalSnapshot(title: "交实验报告（苹果改）")]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
        XCTAssertFalse(containsAdopt(plan))
        XCTAssertFalse(containsPush(plan))
        XCTAssertEqual(plan.anomalies.count, 1)
    }

    /// 范围不完整时也不能凭空把外部条目导入成本地任务。
    func testIncompleteScopeNeverAdoptsNewExternalItem() {
        let plan = ReconciliationEngine.reconcile(
            local: [],
            external: .incomplete(.queryFailed, partialItems: [
                externalSnapshot(taskId: "task_9", externalId: "ext_9", title: "苹果里新建的任务")
            ]),
            previous: []
        )
        XCTAssertFalse(containsAdopt(plan))
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_9")])
    }

    /// 完全没有外部绑定的本地记录不参与"本轮被跳过"的告警：它本来就不依赖外部查询范围。
    func testIncompleteScopeDoesNotFlagUnboundRecord() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(externalId: nil)],
            external: .incomplete(.queryFailed),
            previous: []
        )
        XCTAssertEqual(plan.decisions, [.noop(entityId: "task_1")])
        XCTAssertTrue(plan.anomalies.isEmpty)
    }

    func testScopeClassificationOnlyCompleteWhenBothSegmentsSucceed() {
        XCTAssertEqual(
            ReminderSnapshotQuery.classifyScope(authorized: true, incompleteSucceeded: true, completedSucceeded: true),
            .complete
        )
        XCTAssertEqual(
            ReminderSnapshotQuery.classifyScope(authorized: false, incompleteSucceeded: true, completedSucceeded: true),
            .incomplete(.notAuthorized)
        )
        XCTAssertEqual(
            ReminderSnapshotQuery.classifyScope(authorized: true, incompleteSucceeded: false, completedSucceeded: false),
            .incomplete(.queryFailed)
        )
        XCTAssertEqual(
            ReminderSnapshotQuery.classifyScope(authorized: true, incompleteSucceeded: true, completedSucceeded: false),
            .incomplete(.incompleteScope)
        )
        XCTAssertEqual(
            ReminderSnapshotQuery.classifyScope(authorized: true, incompleteSucceeded: false, completedSucceeded: true),
            .incomplete(.incompleteScope)
        )
        XCTAssertTrue(ReminderSnapshotScope.complete.allowsDeletionPropagation)
        XCTAssertFalse(ReminderSnapshotScope.incomplete(.queryFailed).allowsDeletionPropagation)
        XCTAssertTrue(ReminderSnapshotScope.incomplete(.notAuthorized).userFacingMessage.contains("未做任何删除"))
    }

    func testIncompleteFetchKeepsOnlySucceededSegment() {
        let partial = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: .ok([externalSnapshot()]),
            completed: .failed
        )
        XCTAssertEqual(partial.scope, .incomplete(.incompleteScope))
        XCTAssertEqual(partial.items.count, 1)

        let full = ReminderSnapshotQuery.make(
            authorized: true,
            incomplete: .ok([externalSnapshot(externalId: "ext_open")]),
            completed: .ok([externalSnapshot(externalId: "ext_done", isCompleted: true)])
        )
        XCTAssertEqual(full.scope, .complete)
        XCTAssertEqual(full.items.count, 2)
        XCTAssertEqual(full.items.filter(\.isCompleted).count, 1)
    }

    // MARK: - 外部范围与外部新增

    func testExternalItemsWithoutDayCueIdentifierAreIgnored() {
        let plan = ReconciliationEngine.reconcile(
            local: [],
            external: .complete([externalSnapshot(taskId: nil, externalId: "user_own")]),
            previous: []
        )
        XCTAssertTrue(plan.decisions.isEmpty)
    }

    func testNewExternalItemIsAdoptedIntoLocal() {
        let plan = ReconciliationEngine.reconcile(
            local: [],
            external: .complete([externalSnapshot(taskId: "task_9", externalId: "ext_9", title: "苹果里新建的任务")]),
            previous: []
        )
        guard case let .adoptExternal(entityId, differences) = plan.decisions.first? else {
            return XCTFail("外部新增应产出 adoptExternal，实际是 \(plan.decisions)")
        }
        XCTAssertEqual(entityId, "task_9")
        XCTAssertTrue(differences.allSatisfy { $0.preferredSource == .external && !$0.isConflict })
        XCTAssertTrue(differences.contains { $0.field == .title && $0.externalValue == "苹果里新建的任务" })
    }

    func testDuplicateExternalItemsAreSurfacedAsAnomaly() {
        let plan = ReconciliationEngine.reconcile(
            local: [localSnapshot(externalId: "ext_1")],
            external: .complete([
                externalSnapshot(externalId: "ext_1"),
                externalSnapshot(externalId: "ext_2")
            ]),
            previous: [baseline(state: baseState())]
        )
        XCTAssertEqual(plan.anomalies.count, 1)
        guard case let .duplicateExternalItems(taskId, items) = plan.anomalies[0] else {
            return XCTFail("应记录重复外部条目，实际是 \(plan.anomalies)")
        }
        XCTAssertEqual(taskId, "task_1")
        XCTAssertEqual(items.map(\.externalId), ["ext_1", "ext_2"])
        // 每条都要带上最后修改时间，用户才有线索判断该删哪一条。
        XCTAssertTrue(items.allSatisfy { $0.lastModified == "2026-10-12T10:00:00Z" })
    }

    // MARK: - notes 解析

    func testUserDetailStripsDayCueBookkeepingLines() {
        XCTAssertNil(ExternalReminderNoteField.userDetail(fromNotes: nil))
        XCTAssertNil(ExternalReminderNoteField.userDetail(fromNotes: "DayCue 任务 ID: task_1"))
        let notes = "周五之前\nDayCue 任务 ID: task_1\ndaycue://task/task_1"
        XCTAssertEqual(ExternalReminderNoteField.userDetail(fromNotes: notes), "周五之前")
        XCTAssertEqual(ExternalReminderNoteField.taskId(fromNotes: notes), "task_1")
    }
}

final class SyncSnapshotStoreTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-sync-tests-" + UUID().uuidString
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = try DayCueStore(baseDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testSnapshotWriteStoresContentHashAndSkipsUnchanged() throws {
        let state = baseState()
        let firstCapturedAt = "2026-10-12T10:00:00Z"
        XCTAssertTrue(try store.writeReconciliationBaseline(state, entityId: "task_1", capturedAt: firstCapturedAt))

        let snapshot = try XCTUnwrap(try store.syncSnapshot(
            entityType: "task",
            entityId: "task_1",
            provider: "apple_reminders"
        ))
        XCTAssertEqual(snapshot.contentHash, SHA256Hex.digest(snapshot.payloadJSON))
        XCTAssertEqual(snapshot.capturedAt, firstCapturedAt)

        // 内容没变：必须跳过写入，而且不能刷新 captured_at。
        XCTAssertTrue(try store.shouldSkipWrite(
            entityType: "task",
            entityId: "task_1",
            payloadHash: snapshot.contentHash
        ))
        XCTAssertFalse(try store.writeReconciliationBaseline(
            state,
            entityId: "task_1",
            capturedAt: "2026-10-12T11:00:00Z"
        ))
        let unchanged = try XCTUnwrap(try store.syncSnapshot(
            entityType: "task",
            entityId: "task_1",
            provider: "apple_reminders"
        ))
        XCTAssertEqual(unchanged.capturedAt, firstCapturedAt, "内容没变时不得刷新 captured_at")

        // 内容变了才会真正写入。
        var changed = state
        changed.title = "交实验报告（改）"
        XCTAssertTrue(try store.writeReconciliationBaseline(
            changed,
            entityId: "task_1",
            capturedAt: "2026-10-12T11:00:00Z"
        ))
        XCTAssertEqual(try store.reconciliationBaselines().first?.state.title, "交实验报告（改）")
    }

    func testReconciliationBaselineRoundTripKeepsEveryField() throws {
        let state = baseState(
            detail: "周五之前",
            dueKind: .date,
            dueLocal: "2026-10-16",
            remindLocal: "2026-10-15T20:00:00",
            listId: "list_A"
        )
        XCTAssertTrue(try store.writeReconciliationBaseline(
            state,
            entityId: "task_1",
            capturedAt: "2026-10-12T10:00:00Z"
        ))

        let baselines = try store.reconciliationBaselines()
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(baselines[0].entityId, "task_1")
        XCTAssertEqual(baselines[0].provider, "apple_reminders")
        XCTAssertEqual(baselines[0].capturedAt, "2026-10-12T10:00:00Z")
        XCTAssertEqual(baselines[0].state, state)
    }

    func testDeleteSyncSnapshotRemovesBaselineAndAllowsRewrite() throws {
        XCTAssertTrue(try store.writeReconciliationBaseline(baseState(), entityId: "task_1"))
        XCTAssertFalse(try store.reconciliationBaselines().isEmpty)

        try store.deleteSyncSnapshot(entityType: "task", entityId: "task_1", provider: "apple_reminders")
        XCTAssertNil(try store.syncSnapshot(entityType: "task", entityId: "task_1", provider: "apple_reminders"))
        XCTAssertTrue(try store.reconciliationBaselines().isEmpty)

        // 删除之后重新写必须成功：否则删了绑定就再也写不回基线了。
        XCTAssertTrue(try store.writeReconciliationBaseline(baseState(), entityId: "task_1"))
    }

    func testSyncCursorRoundTrip() throws {
        try store.setSyncCursor(scope: "apple_reminders.incremental", cursor: "cursor_1")
        XCTAssertEqual(try store.syncCursor(scope: "apple_reminders.incremental"), "cursor_1")

        try store.setSyncCursor(scope: "apple_reminders.incremental", cursor: "cursor_2")
        XCTAssertEqual(try store.syncCursor(scope: "apple_reminders.incremental"), "cursor_2")
        XCTAssertEqual(try store.allSyncCursors().count, 1)

        try store.deleteSyncCursor(scope: "apple_reminders.incremental")
        XCTAssertNil(try store.syncCursor(scope: "apple_reminders.incremental"))
    }

    func testSyncTombstoneRoundTrip() throws {
        try store.upsertSyncTombstone(SyncTombstoneRecord(
            entityType: "task",
            entityId: "task_1",
            deletedAt: "2026-10-12T10:00:00Z",
            remoteVersion: 3
        ))
        var tombstone = try XCTUnwrap(try store.syncTombstone(entityType: "task", entityId: "task_1"))
        XCTAssertEqual(tombstone.deletedAt, "2026-10-12T10:00:00Z")
        XCTAssertEqual(tombstone.remoteVersion, 3)

        // 同一个主键再写一次是更新，不是插入第二行。
        try store.upsertSyncTombstone(SyncTombstoneRecord(
            entityType: "task",
            entityId: "task_1",
            deletedAt: "2026-10-12T12:00:00Z",
            remoteVersion: nil
        ))
        tombstone = try XCTUnwrap(try store.syncTombstone(entityType: "task", entityId: "task_1"))
        XCTAssertEqual(tombstone.deletedAt, "2026-10-12T12:00:00Z")
        XCTAssertNil(tombstone.remoteVersion)
        XCTAssertEqual(try store.syncTombstones(entityType: "task").count, 1)

        try store.clearSyncTombstones()
        XCTAssertTrue(try store.syncTombstones().isEmpty)
    }
}
