import Foundation
import XCTest
@testable import DayCueCore

/// 手动笔记写入链路的编排测试：入口 -> NoteWriteCoordinator -> DayCueStore
/// -> 状态变化（可见/不可见、userEdited）-> 云同步通知。
///
/// 「云同步入队」在 Core 里只有 NoteLocalChangeReporting 这一个出口，
/// 所以这里用替身计数来证明「写成功才通知、写失败不通知」，
/// 而不是去测 App 层的 CloudSyncService（它依赖 UIKit，macOS 上测不了）。
///
/// 状态声明：本文件**已编写、未运行**（本机没有 Swift 工具链，无法编译/执行）。
final class NoteWriteCoordinatorTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-note-write-tests-" + UUID().uuidString
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

    // MARK: - 替身

    /// 只有调用次数有意义的通知口替身。
    private final class RecordingReporter: NoteLocalChangeReporting {
        private(set) var calls = 0
        func noteLocalChange() { calls += 1 }
    }

    private func makeCoordinator() -> (NoteWriteCoordinator, RecordingReporter) {
        let reporter = RecordingReporter()
        return (NoteWriteCoordinator(store: store, reporter: reporter), reporter)
    }

    // MARK: - 新建

    func testCreateManualNotePersistsManualOriginWithoutFakeCaptureLink() throws {
        let (coordinator, _) = makeCoordinator()

        let created = try coordinator.createManualNote(
            title: "  操作系统第三章  ",
            body: "PV 操作与信号量",
            tags: ["复习", "复习", "  "],
            courseHint: "  操作系统  ",
            id: "note_manual"
        )

        XCTAssertEqual(created.originKind, .manual, "手动创建必须带 .manual 来源")
        XCTAssertNil(created.originCaptureId, "手动笔记没有原始记录，不许伪造 capture id")
        XCTAssertNil(created.originItemId, "手动笔记没有解析条目，不许伪造 item id")

        let loaded = try XCTUnwrap(try store.note(id: "note_manual"))
        XCTAssertEqual(loaded.title, "操作系统第三章", "标题两端空白要去掉")
        XCTAssertEqual(loaded.body, "PV 操作与信号量")
        XCTAssertEqual(loaded.tags, ["复习"], "标签去空去重")
        XCTAssertEqual(loaded.courseHint, "操作系统")
        XCTAssertFalse(loaded.userEdited, "刚创建还没被用户改过，不置 userEdited")
        XCTAssertFalse(loaded.createdAt.isEmpty)
        XCTAssertEqual(NoteDisplay.sourceText(loaded), "手动创建 · 操作系统", "列表/详情看到的来源标识")

        // 来源可追溯的第二层证据：手动笔记能按列表读出来，也确实只有这一条。
        XCTAssertEqual(try store.notes().map(\.id), ["note_manual"])
    }

    func testCreateManualNoteWithNoContentThrowsAndDoesNotNotify() throws {
        let (coordinator, reporter) = makeCoordinator()

        XCTAssertThrowsError(try coordinator.createManualNote(title: "   ", body: "\n\t", id: "note_empty")) { error in
            XCTAssertEqual(error as? NoteWriteError, .emptyContent)
        }

        XCTAssertEqual(try store.noteCount(), 0, "空内容不允许落库")
        XCTAssertEqual(reporter.calls, 0, "没写成功就不能宣称有变更")
    }

    func testCreateManualNoteNotifiesExactlyOnceAfterWrite() throws {
        let (coordinator, reporter) = makeCoordinator()

        _ = try coordinator.createManualNote(title: "随手记", body: "老师划了重点", id: "note_notify")

        XCTAssertEqual(reporter.calls, 1, "成功落库之后通知一次")
        XCTAssertNotNil(try store.note(id: "note_notify"))
    }

    func testFailedWriteDoesNotNotifyCloudSync() throws {
        let (coordinator, reporter) = makeCoordinator()
        _ = try coordinator.createManualNote(title: "先占位", body: "第一条", id: "note_dup")
        XCTAssertEqual(reporter.calls, 1)

        // 主键冲突：写入必然失败，通知次数不允许增加。
        XCTAssertThrowsError(try coordinator.createManualNote(title: "撞 id", body: "第二条", id: "note_dup"))

        XCTAssertEqual(reporter.calls, 1, "写失败不能误报成有变更")
        XCTAssertEqual(try store.noteCount(), 1)
        XCTAssertEqual(try XCTUnwrap(try store.note(id: "note_dup")).title, "先占位", "失败的写入不能改动已有行")
    }

    // MARK: - 编辑

    func testUpdateMarksUserEditedAndNotifies() throws {
        let (coordinator, reporter) = makeCoordinator()
        _ = try coordinator.createManualNote(title: "原标题", body: "原正文", courseHint: "计算机网络", id: "note_edit")
        XCTAssertEqual(reporter.calls, 1)

        let saved = try coordinator.updateNoteContent(
            id: "note_edit",
            title: "改后标题",
            body: "改后正文",
            tags: ["补充"]
        )

        XCTAssertEqual(saved.title, "改后标题")
        XCTAssertEqual(saved.body, "改后正文")
        XCTAssertEqual(saved.tags, ["补充"])
        XCTAssertEqual(saved.courseHint, "计算机网络", "编辑正文不该顺手清掉课程提示")
        XCTAssertTrue(saved.userEdited, "保存之后必须置 userEdited，重试解析才不会再覆盖")
        XCTAssertEqual(reporter.calls, 2, "编辑成功也要入队同步")
    }

    func testUpdateMissingNoteThrowsAndDoesNotNotify() throws {
        let (coordinator, reporter) = makeCoordinator()

        XCTAssertThrowsError(try coordinator.updateNoteContent(
            id: "note_missing",
            title: "标题",
            body: "正文",
            tags: []
        )) { error in
            XCTAssertEqual(error as? NoteStoreError, .noteNotFound("note_missing"))
        }
        XCTAssertEqual(reporter.calls, 0)
    }

    // MARK: - 删除

    func testDeleteHidesManualNoteAndNotifies() throws {
        let (coordinator, reporter) = makeCoordinator()
        _ = try coordinator.createManualNote(title: "要删的", body: "内容", id: "note_delete")

        try coordinator.deleteNote(id: "note_delete")

        XCTAssertNil(try store.note(id: "note_delete"), "删除后按 id 也取不到")
        XCTAssertTrue(try store.notes().isEmpty)
        XCTAssertTrue(try store.notes(searchText: "内容").isEmpty, "搜索不能带出已删除的笔记")
        XCTAssertEqual(try store.noteCount(includeDeleted: true), 1, "软删除保留行，方便对账")
        XCTAssertEqual(reporter.calls, 2, "创建与删除各通知一次")
    }

    func testDeletedManualNoteIsNotRevivedByAiRetry() throws {
        let (coordinator, _) = makeCoordinator()
        _ = try coordinator.createManualNote(title: "手动记的", body: "手动内容", id: "note_manual_deleted")
        try coordinator.deleteNote(id: "note_manual_deleted")

        // AI 解析重试落库：它只按 (capture_id, item_id) 定位已有笔记，
        // 手动笔记这两列是 NULL，所以只可能新建一条 AI 笔记，绝不该碰手动那条。
        let item = ContractExtractionItem(
            itemId: "itm_ai",
            kind: .note,
            title: "AI 标题",
            detail: "AI 正文",
            sourceEvidence: "证据原文",
            due: ContractDue(kind: .none)
        )
        let outcome = try store.applyNoteCandidates([item], captureId: "cap_ai")

        XCTAssertEqual(outcome.inserted, 1, "AI 只能新建自己的笔记")
        XCTAssertEqual(outcome.skippedDeleted, 0)
        XCTAssertNil(try store.note(id: "note_manual_deleted"), "被删掉的手动笔记不能因为一次重试复活")
        let ids = try store.notes().map(\.id)
        XCTAssertFalse(ids.contains("note_manual_deleted"))
        XCTAssertEqual(try store.noteCount(includeDeleted: true), 2, "手动那条仍是软删除行，AI 只新增自己的一条")
    }

    func testDeletedManualNoteIsNotRevivedByCloudPull() throws {
        let (coordinator, _) = makeCoordinator()
        _ = try coordinator.createManualNote(title: "删了也要同步删除", body: "正文", id: "note_cloud")
        try coordinator.deleteNote(id: "note_cloud")

        var payload = SyncEntityPayload()
        payload.title = "服务端标题"
        payload.body = "服务端正文"
        payload.originKind = NoteOriginKind.manual.rawValue
        try store.applyCloudPayload(
            entityType: .note,
            entityId: "note_cloud",
            payload: payload,
            updatedAt: "2026-10-12T12:00:00Z"
        )

        XCTAssertNil(try store.note(id: "note_cloud"), "云同步回填也不允许把手动删除的笔记复活")

        // 直接看底层行：ON CONFLICT 不允许碰 deleted_at，删除时间必须还在。
        let statement = try store.database.prepare("SELECT deleted_at FROM note WHERE id = ?;")
        try statement.bind([.text("note_cloud")])
        XCTAssertTrue(try statement.step())
        XCTAssertFalse(statement.isNull(0), "软删除标记必须保留")
    }

    // MARK: - 与记忆开关的一致性

    func testManualNoteStillObeysMemoryRecordingSwitch() throws {
        let (coordinator, _) = makeCoordinator()
        _ = try coordinator.createManualNote(title: "偏好", body: "我习惯晚上学习", id: "note_memory")
        let note = try XCTUnwrap(try store.note(id: "note_memory"))

        let now = try XCTUnwrap(RFC3339.date(fromUTC: "2026-10-12T10:00:00Z"))
        let memory = MemoryIngestCoordinator(
            store: store,
            extraction: MemoryExtraction(provider: DefaultRuleBasedExtractor())
        )

        // 关掉「偏好」这一类：手动笔记同样写不进记忆。
        try store.setRecordingEnabled(category: .preference, enabled: false, at: now)
        let disabled = try memory.ingest(notes: [note], now: now)
        XCTAssertEqual(disabled.discards.filter { $0.stage == .recordingDisabled }.count, 1)
        XCTAssertEqual(try store.memoryCount(), 0, "手动笔记不能绕过记忆记录开关")

        // 打开之后才落成候选，且仍然是 candidate，不因为来源是 .manual 就自动成为事实。
        try store.setRecordingEnabled(category: .preference, enabled: true, at: now)
        let enabled = try memory.ingest(notes: [note], now: now)
        XCTAssertEqual(enabled.stored.count, 1)
        XCTAssertEqual(enabled.stored.first?.status, .candidate)
    }
}
