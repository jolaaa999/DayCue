import Foundation
import XCTest
@testable import DayCueCore

/// 启动恢复：进程中断后停在 pending / unknown 的任务必须能被找回来。
///
/// 这里测试的是「能不能找出来、状态怎么迁移」，**不是** EventKit 真的写没写。
/// 系统侧的真实行为只能靠真机验收，见 docs/phase-1-device-acceptance.md。
final class StartupRecoveryTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daycue-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = try DayCueStore(baseDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    /// 造一条停在指定外部写入状态的任务。
    private func insertTask(id: String, state: ExternalWriteState) throws {
        var task = TaskRecord(id: id, title: "复习 PV", dueKind: .datetime)
        task.externalWriteState = state
        try store.insertTask(task)
    }

    func testPendingTasksAreFoundAfterInterruption() throws {
        try insertTask(id: "task_pending", state: .pending)
        try insertTask(id: "task_written", state: .written)

        let pending = try store.pendingExternalWriteTasks()
        XCTAssertEqual(pending.map(\.id), ["task_pending"], "只应找回停在 pending 的任务")
    }

    func testUnknownTasksAreFoundSeparatelyFromPending() throws {
        try insertTask(id: "task_unknown", state: .unknown)
        try insertTask(id: "task_pending", state: .pending)

        XCTAssertEqual(try store.unknownExternalWriteTasks().map(\.id), ["task_unknown"])
    }

    func testUnknownIsDowngradedToReconciliationNotFailure() throws {
        try insertTask(id: "task_unknown", state: .unknown)

        let marked = try store.markUnknownWritesForReconciliation()
        XCTAssertEqual(marked, 1)

        let task = try XCTUnwrap(try store.task(id: "task_unknown"))
        XCTAssertEqual(task.externalWriteState, .needsReconciliation,
                       "状态未知只能转对账，不能替用户断言写入失败")
        XCTAssertTrue(task.externalWriteState.isSyncIssue, "必须出现在同步异常分区里")
        XCTAssertNotEqual(task.externalWriteState, .failed)
    }

    func testMarkingUnknownIsIdempotent() throws {
        try insertTask(id: "task_unknown", state: .unknown)

        XCTAssertEqual(try store.markUnknownWritesForReconciliation(), 1)
        // 第二次已经没有 unknown 了，不应重复计数。
        XCTAssertEqual(try store.markUnknownWritesForReconciliation(), 0)
        XCTAssertEqual(try store.task(id: "task_unknown")?.externalWriteState, .needsReconciliation)
    }

    func testWrittenTasksAreNeverTouchedByRecovery() throws {
        try insertTask(id: "task_written", state: .written)

        XCTAssertEqual(try store.markUnknownWritesForReconciliation(), 0)
        XCTAssertEqual(try store.pendingExternalWriteTasks().count, 0)
        // 已写入的任务不能被任何恢复流程改成待处理，否则会重写并产生第二条提醒。
        XCTAssertEqual(try store.task(id: "task_written")?.externalWriteState, .written)
    }

    func testDeletedTasksAreNotResurrectedByRecovery() throws {
        try insertTask(id: "task_deleted", state: .unknown)
        try store.softDeleteTask(id: "task_deleted")

        XCTAssertTrue(try store.unknownExternalWriteTasks().isEmpty, "已删除的任务不应被恢复流程捡起来")
        XCTAssertEqual(try store.markUnknownWritesForReconciliation(), 0)
    }

    /// running 是「进程被杀在写入中途」的残留。它可以被重新排队，
    /// 但**只能由对账流程**调用，不能自动执行——因为它对应的系统写入结果未知。
    func testStaleRunningOutboxOperationsCanBeRequeued() throws {
        let record = OutboxOperationRecord(
            entityType: .task,
            entityId: "task_1",
            op: .createReminder,
            idempotencyKey: IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A"),
            state: .running,
            createdAt: "",
            updatedAt: ""
        )
        _ = try store.insertOutboxOperation(record)
        XCTAssertEqual(try store.countOutboxOperations(state: .running), 1)

        try store.requeueStaleOutboxOperations()
        XCTAssertEqual(try store.countOutboxOperations(state: .running), 0)
        XCTAssertEqual(try store.countOutboxOperations(state: .pending), 1)
    }

    /// 只有 pending（以及到期的 failed）才会被调度器取出；
    /// running 必须是例外，否则会把「结果未知」的写入再执行一遍。
    func testRunnableOutboxExcludesRunningButIncludesPending() throws {
        _ = try store.insertOutboxOperation(OutboxOperationRecord(
            entityType: .task, entityId: "t1", op: .createReminder,
            idempotencyKey: "k_pending", state: .pending, createdAt: "", updatedAt: ""
        ))
        _ = try store.insertOutboxOperation(OutboxOperationRecord(
            entityType: .task, entityId: "t2", op: .createReminder,
            idempotencyKey: "k_running", state: .running, createdAt: "", updatedAt: ""
        ))
        _ = try store.insertOutboxOperation(OutboxOperationRecord(
            entityType: .task, entityId: "t3", op: .createReminder,
            idempotencyKey: "k_succeeded", state: .succeeded, createdAt: "", updatedAt: ""
        ))

        let runnable = try store.runnableOutboxOperations()
        XCTAssertEqual(runnable.map(\.idempotencyKey), ["k_pending"])
    }
}
