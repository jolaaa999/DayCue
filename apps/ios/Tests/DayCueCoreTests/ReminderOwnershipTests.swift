import Foundation
import XCTest
@testable import DayCueCore

private func makeTask(
    id: String = "task_1",
    status: TaskStatus = .open,
    externalWriteState: ExternalWriteState = .notRequested,
    remindLocal: String? = "2026-10-16T20:00:00"
) -> TaskRecord {
    TaskRecord(
        id: id,
        title: "交实验报告",
        status: status,
        dueKind: remindLocal == nil ? .date : .datetime,
        dueLocal: remindLocal == nil ? "2026-10-16" : nil,
        timezone: "Asia/Shanghai",
        remindLocal: remindLocal,
        externalWriteState: externalWriteState
    )
}

/// 提醒归属。
///
/// 这一组测试守的是「一条任务只有一个提醒执行方」：
/// 切换执行方必须取消旧的，任务完成必须两边都取消，没有提醒时刻就两边都不排。
final class ReminderOwnershipTests: XCTestCase {

    func testSwitchingFromLocalNotificationToExternalAlarmCancelsLocalFirst() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .written,
            status: .open,
            hasRemindTime: true,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: true, hasExternalAlarm: false)
        )
        XCTAssertEqual(decision.executor, .appleReminders)
        XCTAssertTrue(decision.shouldSchedule)
        XCTAssertEqual(decision.cancellations, [.localNotification(taskId: "task_1")])
        XCTAssertTrue(decision.switchedExecutor)
    }

    func testSwitchingBackFromExternalAlarmToLocalNotificationCancelsAlarm() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .failed,
            status: .open,
            hasRemindTime: true,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: false, hasExternalAlarm: true)
        )
        XCTAssertEqual(decision.executor, .localNotification)
        XCTAssertTrue(decision.shouldSchedule)
        XCTAssertEqual(decision.cancellations, [.externalAlarm(taskId: "task_1", externalId: "ext_1")])
    }

    func testUnknownWriteStateFallsBackToLocalNotificationAndCancelsAlarm() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .unknown,
            status: .open,
            hasRemindTime: true,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: false, hasExternalAlarm: true)
        )
        XCTAssertEqual(decision.executor, .localNotification)
        XCTAssertEqual(decision.cancellations, [.externalAlarm(taskId: "task_1", externalId: "ext_1")])
    }

    func testCompletionCancelsBothSides() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .written,
            status: .done,
            hasRemindTime: true,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: true, hasExternalAlarm: true)
        )
        XCTAssertEqual(decision.executor, .none)
        XCTAssertFalse(decision.shouldSchedule)
        // 顺序固定为「先本地、后外部」，便于幂等重放时比对。
        XCTAssertEqual(decision.cancellations, [
            .localNotification(taskId: "task_1"),
            .externalAlarm(taskId: "task_1", externalId: "ext_1")
        ])
    }

    func testCancelledTaskAlsoCancelsBothSides() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .written,
            status: .cancelled,
            hasRemindTime: true,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: true, hasExternalAlarm: false)
        )
        XCTAssertEqual(decision.executor, .none)
        XCTAssertFalse(decision.shouldSchedule)
        XCTAssertEqual(decision.cancellations, [.localNotification(taskId: "task_1")])
    }

    /// 日期型任务（只有截止日，没有提醒时刻）两侧都不排。
    func testDateOnlyTaskSchedulesNothing() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .written,
            status: .open,
            hasRemindTime: false,
            externalId: "ext_1",
            scheduling: .none
        )
        XCTAssertEqual(decision.executor, .none)
        XCTAssertFalse(decision.shouldSchedule)
        XCTAssertTrue(decision.cancellations.isEmpty)
    }

    func testRemovingRemindTimeCancelsPreviouslyScheduledReminder() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .written,
            status: .open,
            hasRemindTime: false,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: true, hasExternalAlarm: false)
        )
        XCTAssertEqual(decision.executor, .none)
        XCTAssertFalse(decision.shouldSchedule)
        XCTAssertEqual(decision.cancellations, [.localNotification(taskId: "task_1")])
    }

    func testAlreadyOwnedByAppleRemindersDoesNotCancelAnything() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .written,
            status: .open,
            hasRemindTime: true,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: false, hasExternalAlarm: true)
        )
        XCTAssertEqual(decision.executor, .appleReminders)
        XCTAssertTrue(decision.shouldSchedule)
        XCTAssertTrue(decision.cancellations.isEmpty)
    }

    func testNotRequestedWithRemindTimeUsesLocalNotification() {
        let decision = ReminderOwnership.decide(
            taskId: "task_1",
            externalWriteState: .notRequested,
            status: .open,
            hasRemindTime: true,
            externalId: nil,
            scheduling: .none
        )
        XCTAssertEqual(decision.executor, .localNotification)
        XCTAssertTrue(decision.shouldSchedule)
        XCTAssertTrue(decision.cancellations.isEmpty)
    }

    func testTaskRecordConvenienceReadsRemindLocal() {
        let withReminder = makeTask(externalWriteState: .written)
        XCTAssertTrue(ReminderOwnership.hasRemindTime(withReminder))
        let decision = ReminderOwnership.decide(
            for: withReminder,
            externalId: "ext_1",
            scheduling: ReminderSchedulingState(hasLocalNotificationScheduled: true)
        )
        XCTAssertEqual(decision.executor, .appleReminders)
        XCTAssertEqual(decision.cancellations, [.localNotification(taskId: "task_1")])

        let dateOnly = makeTask(remindLocal: nil)
        XCTAssertFalse(ReminderOwnership.hasRemindTime(dateOnly))
        let dateDecision = ReminderOwnership.decide(
            for: dateOnly,
            externalId: "ext_1",
            scheduling: .none
        )
        XCTAssertEqual(dateDecision.executor, .none)
        XCTAssertFalse(dateDecision.shouldSchedule)
    }

    func testEachExecutorNameIsDistinct() {
        // 保证映射文案不会退化：执行方定义变了，界面与日志才有意义。
        XCTAssertEqual(ReminderExecutor.appleReminders.rawValue, "apple_reminders")
        XCTAssertEqual(ReminderExecutor.localNotification.rawValue, "local_notification")
        XCTAssertEqual(ReminderExecutor.allCases.count, 3)
    }
}
