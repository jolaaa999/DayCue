import Foundation
import XCTest
@testable import DayCueCore

/// 状态机测试：外部写入状态只能按合法路径迁移。
/// 重点是「已经写入成功之后又收到失败回执」不能退回 pending —— 那会导致重复创建外部提醒。
final class ExternalWriteStateMachineTests: XCTestCase {

    func testHappyPathFromNotRequestedToWritten() {
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .notRequested, to: .pending), .pending)
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .pending, to: .written), .written)
    }

    func testPermissionDeniedGoesToWaitingForPermissionNotFailed() {
        // 用户只是没授权，任务依然在 App 里；这不是"写入失败"。
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .notRequested, to: .waitingForPermission), .waitingForPermission)
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .waitingForPermission, to: .pending), .pending)
    }

    func testWrittenStateCanBecomeNeedsReconciliationAfterFailureReceipt() {
        // 这是设计文档 9.2 的核心要求：写入后崩溃/回执丢失，只能转对账，不能回到 pending。
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .written, to: .needsReconciliation), .needsReconciliation)
        XCTAssertNil(ExternalWriteStateMachine.transition(from: .written, to: .pending))
    }

    func testUnknownMustBeReconciledBeforeBeingTrusted() {
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .pending, to: .unknown), .unknown)
        XCTAssertTrue(ExternalWriteState.unknown.isSyncIssue)
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .unknown, to: .written), .written)
        // 对账之后可以直接修正为失败，这也是合法路径。
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .unknown, to: .failed), .failed)
    }

    func testTerminalFailureCanBeRetried() {
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .failed, to: .pending), .pending)
        XCTAssertEqual(ExternalWriteStateMachine.transition(from: .failed, to: .needsReconciliation), .needsReconciliation)
    }

    func testSelfTransitionIsAllowedAndIdempotent() {
        for state in ExternalWriteState.allCases {
            XCTAssertTrue(ExternalWriteStateMachine.canTransition(from: state, to: state))
            XCTAssertEqual(ExternalWriteStateMachine.transition(from: state, to: state), state)
        }
    }

    func testIllegalJumpsAreRejected() {
        XCTAssertNil(ExternalWriteStateMachine.transition(from: .notRequested, to: .written))
        XCTAssertNil(ExternalWriteStateMachine.transition(from: .waitingForPermission, to: .written))
        XCTAssertNil(ExternalWriteStateMachine.transition(from: .notRequested, to: .needsReconciliation))
    }

    func testSyncIssueClassificationMatchesSpecification() {
        XCTAssertTrue(ExternalWriteState.failed.isSyncIssue)
        XCTAssertTrue(ExternalWriteState.unknown.isSyncIssue)
        XCTAssertTrue(ExternalWriteState.needsReconciliation.isSyncIssue)
        XCTAssertFalse(ExternalWriteState.written.isSyncIssue)
        XCTAssertFalse(ExternalWriteState.pending.isSyncIssue)
        XCTAssertFalse(ExternalWriteState.waitingForPermission.isSyncIssue)
        XCTAssertFalse(ExternalWriteState.notRequested.isSyncIssue)
    }

    func testDisplayStatesAreTheFourUserFacingTexts() {
        // 今天页只允许出现这四类文案（其余状态并入「待对账」）。
        XCTAssertEqual(ExternalWriteState.notRequested.displayName, "仅保存在 App")
        XCTAssertEqual(ExternalWriteState.waitingForPermission.displayName, "等待写入苹果提醒事项")
        XCTAssertEqual(ExternalWriteState.pending.displayName, "等待写入苹果提醒事项")
        XCTAssertEqual(ExternalWriteState.written.displayName, "已写入苹果提醒事项")
        XCTAssertEqual(ExternalWriteState.failed.displayName, "写入失败")
    }

    func testStoreRejectsIllegalTransitionAndKeepsPreviousState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daycue-state-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try DayCueStore(baseDirectory: directory)
        try store.insertTask(TaskRecord(
            id: "task_state",
            title: "复习 PV",
            externalWriteState: .written,
            createdAt: "",
            updatedAt: ""
        ))

        // written -> pending 非法，方法返回 nil 且数据库里的状态保持不变。
        XCTAssertNil(try store.setTaskExternalWriteState(id: "task_state", to: .pending))
        XCTAssertEqual(try store.task(id: "task_state")?.externalWriteState, .written)

        // written -> needs_reconciliation 合法。
        XCTAssertEqual(try store.setTaskExternalWriteState(id: "task_state", to: .needsReconciliation), .needsReconciliation)
        XCTAssertEqual(try store.task(id: "task_state")?.externalWriteState, .needsReconciliation)

        // 而且它应该出现在今天页的同步异常分区里。
        let issues = try store.syncIssueTasks()
        XCTAssertEqual(issues.map { $0.id }, ["task_state"])
    }
}
