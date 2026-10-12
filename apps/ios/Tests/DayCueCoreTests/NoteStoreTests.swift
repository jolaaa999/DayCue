import Foundation
import XCTest
@testable import DayCueCore

/// 笔记仓储测试：往返、可见性、筛选、分页与标签编解码。
/// 每个用例用独立的临时目录，避免互相污染（与 SQLiteStoreTests 的做法一致）。
final class NoteStoreTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-note-tests-" + UUID().uuidString
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

    private func makeNote(
        id: String = DayCueID.new(),
        title: String = "操作系统第三章",
        body: String = "PV 操作与信号量",
        tags: [String] = [],
        courseHint: String? = "操作系统",
        originCaptureId: String? = nil,
        originItemId: String? = nil,
        originKind: NoteOriginKind = .manual,
        userEdited: Bool = false,
        occurredAt: String? = nil,
        createdAt: String = "",
        updatedAt: String = ""
    ) -> NoteRecord {
        NoteRecord(
            id: id,
            title: title,
            body: body,
            tags: tags,
            courseHint: courseHint,
            originCaptureId: originCaptureId,
            originItemId: originItemId,
            originKind: originKind,
            userEdited: userEdited,
            occurredAt: occurredAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func testInsertedNoteCanBeFetchedById() throws {
        try store.insertNote(makeNote(
            id: "note_round_trip",
            title: "第三章 进程同步",
            body: "PV 操作、信号量、管程",
            tags: ["复习", "期末"],
            courseHint: "操作系统",
            originCaptureId: "cap_1",
            originItemId: "itm_1",
            originKind: .capture,
            occurredAt: "2026-10-12T08:00:00Z",
            createdAt: "2026-10-12T09:00:00Z"
        ))

        let loaded = try XCTUnwrap(try store.note(id: "note_round_trip"))
        XCTAssertEqual(loaded.title, "第三章 进程同步")
        XCTAssertEqual(loaded.body, "PV 操作、信号量、管程")
        XCTAssertEqual(loaded.tags, ["复习", "期末"])
        XCTAssertEqual(loaded.courseHint, "操作系统")
        XCTAssertEqual(loaded.originKind, .capture)
        XCTAssertEqual(loaded.originCaptureId, "cap_1")
        XCTAssertEqual(loaded.originItemId, "itm_1")
        XCTAssertFalse(loaded.userEdited)
        XCTAssertEqual(loaded.occurredAt, "2026-10-12T08:00:00Z")
        XCTAssertEqual(loaded.createdAt, "2026-10-12T09:00:00Z")
        XCTAssertEqual(loaded.updatedAt, "2026-10-12T09:00:00Z")
        XCTAssertNil(loaded.deletedAt)
    }

    func testSoftDeletedNoteDisappearsFromEveryQuery() throws {
        try store.insertNote(makeNote(id: "note_keep", title: "留着的笔记", createdAt: "2026-10-12T09:00:00Z"))
        try store.insertNote(makeNote(id: "note_drop", title: "要删的笔记", createdAt: "2026-10-12T10:00:00Z"))

        try store.softDeleteNote(id: "note_drop")

        XCTAssertNil(try store.note(id: "note_drop"), "软删除后不允许再按 id 取回")
        XCTAssertEqual(try store.notes().map(\.id), ["note_keep"])
        XCTAssertTrue(try store.notes(searchText: "要删").isEmpty, "搜索不能带出已删除的笔记")
        XCTAssertEqual(try store.notes(courseHint: "操作系统").map(\.id), ["note_keep"])
        XCTAssertEqual(try store.noteCount(), 1)
        XCTAssertEqual(try store.noteCount(includeDeleted: true), 2)
    }

    func testNotesFilteredByCourseHint() throws {
        try store.insertNote(makeNote(id: "note_os_1", courseHint: "操作系统"))
        try store.insertNote(makeNote(id: "note_os_2", courseHint: "操作系统"))
        try store.insertNote(makeNote(id: "note_net", courseHint: "计算机网络"))
        try store.insertNote(makeNote(id: "note_no_course", courseHint: nil))

        XCTAssertEqual(Set(try store.notes(courseHint: "操作系统").map(\.id)), ["note_os_1", "note_os_2"])
        XCTAssertEqual(try store.notes(courseHint: "计算机网络").map(\.id), ["note_net"])
        // 空字符串不等于「不过滤」：库里没有 course_hint 为空串的笔记，它匹配不到任何一行。
        XCTAssertTrue(try store.notes(courseHint: "").isEmpty)
        XCTAssertEqual(try store.notes().count, 4)
    }

    func testSearchMatchesTitleBodyAndTagsWithoutWildcardSemantics() throws {
        try store.insertNote(makeNote(id: "note_title", title: "操作系统第三章", body: "笔记正文"))
        try store.insertNote(makeNote(id: "note_body", title: "随手记", body: "信号量的 P 操作会阻塞"))
        try store.insertNote(makeNote(id: "note_tag", title: "随手记", body: "老师划了重点", tags: ["期末", "考试范围"]))
        try store.insertNote(makeNote(id: "note_percent", title: "占比", body: "期末占 50% 成绩"))
        try store.insertNote(makeNote(id: "note_number", title: "编号", body: "编号 500012"))

        XCTAssertEqual(try store.notes(searchText: "第三章").map(\.id), ["note_title"])
        XCTAssertEqual(try store.notes(searchText: "阻塞").map(\.id), ["note_body"])
        XCTAssertEqual(try store.notes(searchText: "考试").map(\.id), ["note_tag"])
        // % 必须当普通字符：用 LIKE 的实现会在这里把整库都命中。
        XCTAssertEqual(try store.notes(searchText: "50%").map(\.id), ["note_percent"])
        XCTAssertEqual(try store.notes(searchText: "%").map(\.id), ["note_percent"])
        // 空关键词等于不筛选。
        XCTAssertEqual(try store.notes(searchText: "   ").count, 5)
    }

    func testTagsRoundTripThroughStorage() throws {
        // 标签里带逗号也不能被拆开：逗号只是输入习惯，不是存储分隔符。
        try store.insertNote(makeNote(id: "note_tags", tags: ["复习", "第三章, 第四讲", "复习", "  "]))

        let loaded = try XCTUnwrap(try store.note(id: "note_tags"))
        XCTAssertEqual(loaded.tags, ["复习", "第三章, 第四讲"], "空白项去掉、重复项去重、顺序保持首次出现")

        let statement = try store.database.prepare("SELECT tags FROM note WHERE id = ?;")
        try statement.bind([.text("note_tags")])
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(try XCTUnwrap(statement.string(0)), "复习\n第三章, 第四讲")

        try store.insertNote(makeNote(id: "note_no_tags", tags: []))
        let nullStatement = try store.database.prepare("SELECT tags FROM note WHERE id = ?;")
        try nullStatement.bind([.text("note_no_tags")])
        XCTAssertTrue(try nullStatement.step())
        XCTAssertTrue(nullStatement.isNull(0), "没有标签时库里应当是 NULL，而不是空字符串")
    }

    func testUpsertUpdatesRowAndKeepsCreatedAt() throws {
        try store.insertNote(makeNote(
            id: "note_upsert",
            title: "原标题",
            body: "原正文",
            createdAt: "2026-10-12T09:00:00Z"
        ))
        try store.upsertNote(makeNote(
            id: "note_upsert",
            title: "新标题",
            body: "新正文",
            tags: ["补充"],
            createdAt: "2026-10-12T09:00:00Z"
        ))

        XCTAssertEqual(try store.noteCount(), 1, "同一个 id 的 upsert 不能产生第二行")
        let loaded = try XCTUnwrap(try store.note(id: "note_upsert"))
        XCTAssertEqual(loaded.title, "新标题")
        XCTAssertEqual(loaded.body, "新正文")
        XCTAssertEqual(loaded.tags, ["补充"])
        XCTAssertEqual(loaded.createdAt, "2026-10-12T09:00:00Z", "upsert 不允许刷新创建时间")
    }

    func testUpdateNoteRefusesDeletedNote() throws {
        try store.insertNote(makeNote(id: "note_deleted_edit"))
        try store.softDeleteNote(id: "note_deleted_edit")

        XCTAssertThrowsError(try store.updateNote(makeNote(id: "note_deleted_edit", title: "改后标题"))) { error in
            XCTAssertEqual(error as? NoteStoreError, .noteNotFound("note_deleted_edit"))
        }
        XCTAssertThrowsError(try store.markNoteUserEdited(id: "note_deleted_edit")) { error in
            XCTAssertEqual(error as? NoteStoreError, .noteNotFound("note_deleted_edit"))
        }
    }

    func testUserEditedFlagIsSticky() throws {
        try store.insertNote(makeNote(id: "note_edit_flag"))
        XCTAssertFalse(try XCTUnwrap(try store.note(id: "note_edit_flag")).userEdited)

        try store.markNoteUserEdited(id: "note_edit_flag")
        XCTAssertTrue(try XCTUnwrap(try store.note(id: "note_edit_flag")).userEdited)

        // 用一份 userEdited = false 的过期记录整行覆盖，标志位也不允许被回退。
        var stale = try XCTUnwrap(try store.note(id: "note_edit_flag"))
        stale.title = "只改标题"
        stale.userEdited = false
        try store.updateNote(stale)

        let reloaded = try XCTUnwrap(try store.note(id: "note_edit_flag"))
        XCTAssertEqual(reloaded.title, "只改标题")
        XCTAssertTrue(reloaded.userEdited, "user_edited 置 1 之后不允许回退")
    }

    func testPaginationReturnsNewestFirst() throws {
        try store.insertNote(makeNote(id: "note_1", title: "第一条", createdAt: "2026-10-12T09:00:00Z"))
        try store.insertNote(makeNote(id: "note_2", title: "第二条", createdAt: "2026-10-12T10:00:00Z"))
        try store.insertNote(makeNote(id: "note_3", title: "第三条", createdAt: "2026-10-12T11:00:00Z"))

        XCTAssertEqual(try store.notes(limit: 2).map(\.id), ["note_3", "note_2"])
        XCTAssertEqual(try store.notes(limit: 2, offset: 2).map(\.id), ["note_1"])
        XCTAssertTrue(try store.notes(limit: 2, offset: 3).isEmpty)
    }

    func testOriginLookupHidesDeletedUnlessExplicitlyRequested() throws {
        try store.insertNote(makeNote(
            id: "note_origin",
            originCaptureId: "cap_9",
            originItemId: "itm_9",
            originKind: .capture
        ))

        XCTAssertEqual(try store.note(originCaptureId: "cap_9", originItemId: "itm_9")?.id, "note_origin")

        try store.softDeleteNote(id: "note_origin")

        XCTAssertNil(try store.note(originCaptureId: "cap_9", originItemId: "itm_9"), "默认看不到已删除的笔记")
        XCTAssertEqual(
            try store.note(originCaptureId: "cap_9", originItemId: "itm_9", includeDeleted: true)?.id,
            "note_origin",
            "录入路径必须看得见已删除的笔记，否则会把用户删掉的笔记重新写回来"
        )
    }
}
