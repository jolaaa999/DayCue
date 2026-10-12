import Foundation
import XCTest
@testable import DayCueCore

/// 本地库往返与约束测试。每个用例用独立的临时目录，避免互相污染。
final class SQLiteStoreTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-tests-" + UUID().uuidString
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

    func testSchemaMigrationRunsOnceAndReportsVersion() throws {
        // 重复打开同一个目录不应该重复执行迁移，也不应该报错。
        let reopened = try DayCueStore(baseDirectory: temporaryDirectory)
        XCTAssertEqual(reopened.databasePath, store.databasePath)

        var versions: [Int] = []
        let statement = try reopened.database.prepare("SELECT version FROM schema_migrations;")
        while try statement.step() { versions.append(statement.int(0)) }
        XCTAssertEqual(versions, [DayCueSchema.currentVersion])
    }

    func testCaptureRoundTripKeepsEveryField() throws {
        let capture = CaptureRecord(
            id: "cap_round_trip",
            kind: .audio,
            rawText: nil,
            transcript: "今天操作系统讲了 PV 操作",
            ocrText: nil,
            userEdited: false,
            mediaPath: "/tmp/media/rec.m4a",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai",
            status: .local
        )

        let inserted = try store.insertCapture(capture)
        let loaded = try XCTUnwrap(try store.capture(id: "cap_round_trip"))

        XCTAssertEqual(loaded.id, inserted.id)
        XCTAssertEqual(loaded.kind, .audio)
        XCTAssertNil(loaded.rawText)
        XCTAssertEqual(loaded.transcript, "今天操作系统讲了 PV 操作")
        XCTAssertNil(loaded.ocrText)
        XCTAssertFalse(loaded.userEdited)
        XCTAssertEqual(loaded.mediaPath, "/tmp/media/rec.m4a")
        XCTAssertEqual(loaded.recordedAt, "2026-10-11T13:00:00Z")
        XCTAssertEqual(loaded.recordedTimezone, "Asia/Shanghai")
        XCTAssertEqual(loaded.status, .local)
        XCTAssertFalse(loaded.createdAt.isEmpty)
        XCTAssertFalse(loaded.updatedAt.isEmpty)
    }

    func testTaskRoundTripKeepsDueAndReminderSeparately() throws {
        let task = TaskRecord(
            id: "task_round_trip",
            title: "交实验报告",
            detail: "周五之前",
            status: .open,
            dueKind: .date,
            dueLocal: "2026-10-16",
            dueUTC: nil,
            timezone: "Asia/Shanghai",
            remindLocal: nil,
            remindUTC: nil,
            courseHint: "操作系统",
            originCaptureId: "cap_round_trip",
            originItemId: "itm_task_report",
            externalWriteState: .waitingForPermission
        )

        try store.insertTask(task)
        let loaded = try XCTUnwrap(try store.task(id: "task_round_trip"))

        XCTAssertEqual(loaded.title, "交实验报告")
        XCTAssertEqual(loaded.dueKind, .date)
        XCTAssertEqual(loaded.dueLocal, "2026-10-16")
        // 日期型任务的 utc 必须保持为空：不能自动补一个假的午夜时刻。
        XCTAssertNil(loaded.dueUTC)
        XCTAssertNil(loaded.remindLocal)
        XCTAssertNil(loaded.remindUTC)
        XCTAssertEqual(loaded.timezone, "Asia/Shanghai")
        XCTAssertEqual(loaded.courseHint, "操作系统")
        XCTAssertEqual(loaded.originCaptureId, "cap_round_trip")
        XCTAssertEqual(loaded.originItemId, "itm_task_report")
        XCTAssertEqual(loaded.externalWriteState, .waitingForPermission)
        XCTAssertNil(loaded.deletedAt)
    }

    func testDuplicateIdempotencyKeyIsRejectedByUniqueIndex() throws {
        let key = IdempotencyKey.createReminder(taskId: "task_1", listId: "list_A")

        let first = OutboxOperationRecord(
            entityType: .task,
            entityId: "task_1",
            op: .createReminder,
            idempotencyKey: key,
            createdAt: "",
            updatedAt: ""
        )
        try store.insertOutboxOperation(first)

        let duplicate = OutboxOperationRecord(
            entityType: .task,
            entityId: "task_1",
            op: .createReminder,
            idempotencyKey: key,
            createdAt: "",
            updatedAt: ""
        )

        XCTAssertThrowsError(try store.insertOutboxOperation(duplicate)) { error in
            guard let sqliteError = error as? SQLiteError else {
                return XCTFail("期望 SQLiteError，实际是 \(error)")
            }
            XCTAssertTrue(sqliteError.isUniqueConstraintViolation, "期望唯一约束冲突，实际是 \(sqliteError)")
        }

        XCTAssertEqual(try store.outboxOperations().count, 1)
    }

    func testEnqueueIsIdempotentAndReturnsExistingRow() throws {
        let key = IdempotencyKey.createReminder(taskId: "task_9", listId: "list_Z")

        let first = try store.enqueueOutboxOperation(
            entityType: .task,
            entityId: "task_9",
            op: .createReminder,
            idempotencyKey: key
        )
        let second = try store.enqueueOutboxOperation(
            entityType: .task,
            entityId: "task_9",
            op: .createReminder,
            idempotencyKey: key
        )

        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created, "同一个幂等键第二次入队不应该新建记录")
        XCTAssertEqual(first.record.id, second.record.id)
        XCTAssertEqual(try store.outboxOperations().count, 1)
    }

    func testAttachmentsAndBindingsRoundTrip() throws {
        let capture = CaptureRecord(
            id: "cap_attachment",
            kind: .image,
            ocrText: "实验三，下周三上课前交",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        )
        try store.insertCapture(capture)

        try store.insertAttachment(AttachmentRecord(
            id: "att_1",
            captureId: "cap_attachment",
            mediaType: "image/jpeg",
            localPath: "/tmp/media/photo.jpg",
            byteSize: 12345,
            sha256: SHA256Hex.digest("photo"),
            createdAt: "2026-10-11T13:00:01Z"
        ))

        let attachments = try store.attachments(captureId: "cap_attachment")
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.byteSize, 12345)

        let task = TaskRecord(id: "task_binding", title: "交实验报告", createdAt: "", updatedAt: "")
        try store.insertTask(task)

        try store.upsertExternalBinding(ExternalBindingRecord(
            taskId: "task_binding",
            provider: "apple_reminders",
            listId: "list_A",
            listTitle: "作业",
            externalId: "x-apple-reminder://ABC",
            externalLastModified: "2026-10-11T13:05:00Z",
            snapshotJSON: #"{"title":"交实验报告"}"#,
            createdAt: "2026-10-11T13:05:00Z"
        ))

        let binding = try XCTUnwrap(try store.externalBinding(taskId: "task_binding"))
        XCTAssertEqual(binding.externalId, "x-apple-reminder://ABC")
        XCTAssertEqual(binding.listId, "list_A")

        // 同一个 (task_id, provider) 再写一次应该是更新而不是报错。
        try store.upsertExternalBinding(ExternalBindingRecord(
            taskId: "task_binding",
            provider: "apple_reminders",
            listId: "list_B",
            listTitle: "学习",
            externalId: "x-apple-reminder://ABC",
            externalLastModified: "2026-10-11T14:00:00Z",
            snapshotJSON: nil,
            createdAt: "2026-10-11T14:00:00Z"
        ))
        let updated = try XCTUnwrap(try store.externalBinding(taskId: "task_binding"))
        XCTAssertEqual(updated.listId, "list_B")
        XCTAssertEqual(updated.listTitle, "学习")
    }

    func testTaskExistsPreventsDuplicateFromSameProposalItem() throws {
        let task = TaskRecord(
            id: "task_dedupe",
            title: "复习 PV",
            originCaptureId: "cap_1",
            originItemId: "itm_1",
            createdAt: "",
            updatedAt: ""
        )
        try store.insertTask(task)

        XCTAssertTrue(try store.taskExists(originCaptureId: "cap_1", originItemId: "itm_1"))
        XCTAssertFalse(try store.taskExists(originCaptureId: "cap_1", originItemId: "itm_2"))
    }

    func testWipeAllDataClearsRowsButKeepsSchema() throws {
        try store.insertCapture(CaptureRecord(
            id: "cap_wipe",
            kind: .text,
            rawText: "测试",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        ))
        try store.insertTask(TaskRecord(id: "task_wipe", title: "测试", createdAt: "", updatedAt: ""))

        try store.wipeAllData()

        XCTAssertTrue(try store.captures().isEmpty)
        XCTAssertTrue(try store.tasks().isEmpty)
        // 表结构还在，所以迁移不会被重复执行。
        XCTAssertNoThrow(try store.insertTask(TaskRecord(id: "task_after_wipe", title: "再次可用", createdAt: "", updatedAt: "")))
    }
}
