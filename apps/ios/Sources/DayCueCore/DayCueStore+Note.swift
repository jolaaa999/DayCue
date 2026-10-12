import Foundation

/// 笔记仓储的业务错误。
///
/// 不复用 DayCueStoreError（它在 DayCueStore.swift 里，且语义是「捕获/任务缺失」）：
/// 把 noteNotFound 混进去会让调用方的 catch 分支必须同时猜测两类实体的缺失。
public enum NoteStoreError: Error, Equatable {
    case noteNotFound(String)
}

/// 标签的序列化与解析。
///
/// 为什么要独立成一个类型：tags 在库里是单个 TEXT 列，只要出现第二份实现，
/// 就会出现「写入用换行、读取按逗号切」这种只在个别数据上暴露的错。
///
/// 分隔符选换行而不是逗号，是因为标签本身完全可能带逗号（例如「第三章, 第四讲」），
/// 逗号分隔会把它拆成两个标签，而且不可逆。界面输入框允许用户打逗号，
/// 但那只是输入便利，进入这里之前已经被拆好，序列化格式始终只有一种。
public enum NoteTagCodec {

    public static let separator: Character = "\n"

    /// 序列化。空数组写成 NULL 而不是空字符串：
    /// 「没有标签」在库里只有一种表示，查询与统计不会出现两种空值。
    public static func encode(_ tags: [String]) -> String? {
        let normalized = normalize(tags)
        guard !normalized.isEmpty else { return nil }
        return normalized.joined(separator: String(separator))
    }

    /// 解析。容忍 NULL、空串、多余空行与前后空白。
    public static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let pieces = raw
            .split(separator: separator, omittingEmptySubsequences: false)
            .map(String.init)
        return normalize(pieces)
    }

    /// 界面输入框的切分。
    ///
    /// 允许换行、半角逗号与全角逗号，但切分规则也只在这里定义一次：
    /// 如果界面按逗号切、存储按换行切，就会出现「输入框里看着是三个标签、库里只有一个」。
    public static func parseInput(_ text: String) -> [String] {
        let pieces = text
            .split(whereSeparator: { $0 == separator || $0 == "," || $0 == "，" })
            .map(String.init)
        return normalize(pieces)
    }

    /// 去空白、丢空项、按首次出现顺序去重。
    ///
    /// 去重的原因：同一个标签出现两次对用户没有信息量，却会让「按标签浏览」出现重复行；
    /// 保留首次出现顺序是为了让用户输入的次序在往返之后仍然可预期。
    public static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

public extension DayCueStore {

    // MARK: - 写入

    /// 新增一条笔记。
    ///
    /// 这里不做「同来源查重」：去重属于「候选 -> 笔记录入」那条路径（NoteExtraction），
    /// 手动创建的笔记允许没有来源，硬塞一个查重键会把两种场景混在一起。
    @discardableResult
    func insertNote(_ note: NoteRecord) throws -> NoteRecord {
        var record = note
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO note
              (id, title, body, tags, course_hint, origin_capture_id, origin_item_id,
               origin_kind, user_edited, occurred_at, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(Self.noteInsertValues(record))
        try statement.run()
        return record
    }

    /// 整行覆盖（不含 created_at 与 deleted_at）。
    ///
    /// 为什么不写 deleted_at：从列表页取到的 NoteRecord 其 deletedAt 一定是 nil，
    /// 如果把它写回去，就等于「编辑一次就把删掉的笔记复活了」。
    /// 删除只能通过 softDeleteNote，恢复只能通过显式的恢复流程。
    ///
    /// user_edited 用 MAX(user_edited, ?) 写：这个标志一旦为 1 就不允许被回退，
    /// 否则一份过期的内存记录（userEdited = false）整行覆盖之后，
    /// 「用户改过的笔记」会重新变成可被解析覆盖的状态。
    func updateNote(_ note: NoteRecord) throws {
        // 用 note(id:) 而不是直接 UPDATE：它只认未删除的行，
        // 于是「更新一条已删除笔记」会明确抛错，而不是静默写坏数据。
        guard try self.note(id: note.id) != nil else { throw NoteStoreError.noteNotFound(note.id) }

        var record = note
        record.updatedAt = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            """
            UPDATE note SET
              title = ?, body = ?, tags = ?, course_hint = ?, origin_capture_id = ?, origin_item_id = ?,
              origin_kind = ?, user_edited = MAX(user_edited, ?), occurred_at = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL;
            """
        )
        try statement.bind([
            .text(record.title),
            .text(record.body),
            .optionalText(NoteTagCodec.encode(record.tags)),
            .optionalText(record.courseHint),
            .optionalText(record.originCaptureId),
            .optionalText(record.originItemId),
            .text(record.originKind.rawValue),
            .bool(record.userEdited),
            .optionalText(record.occurredAt),
            .text(record.updatedAt),
            .text(record.id)
        ])
        try statement.run()
    }

    /// 整行 upsert。
    ///
    /// created_at 保持第一次写入的值：重试解析不应该把「这条笔记是什么时候产生的」刷新成现在。
    /// ON CONFLICT 分支故意不碰 deleted_at，所以对已删除的行做 upsert 不会让它复活。
    @discardableResult
    func upsertNote(_ note: NoteRecord) throws -> NoteRecord {
        var record = note
        let now = DayCueClock.nowUTCString()
        if record.createdAt.isEmpty { record.createdAt = now }
        record.updatedAt = now

        let statement = try database.prepare(
            """
            INSERT INTO note
              (id, title, body, tags, course_hint, origin_capture_id, origin_item_id,
               origin_kind, user_edited, occurred_at, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              body = excluded.body,
              tags = excluded.tags,
              course_hint = excluded.course_hint,
              origin_capture_id = excluded.origin_capture_id,
              origin_item_id = excluded.origin_item_id,
              origin_kind = excluded.origin_kind,
              user_edited = excluded.user_edited,
              occurred_at = excluded.occurred_at,
              updated_at = excluded.updated_at;
            """
        )
        try statement.bind(Self.noteInsertValues(record))
        try statement.run()
        return record
    }

    /// 置「用户编辑过」标志。一旦置 1 就不回退（与 capture 的 user_edited 同一套规则）：
    /// 重试解析能不能覆盖，只需要看这一个标志位。
    func markNoteUserEdited(id: String) throws {
        guard try note(id: id) != nil else { throw NoteStoreError.noteNotFound(id) }
        let statement = try database.prepare(
            "UPDATE note SET user_edited = 1, updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(DayCueClock.nowUTCString()), .text(id)])
        try statement.run()
    }

    /// 软删除。
    ///
    /// deleted_at 只在第一次删除时写入：重复删除不应该把时间往后推，
    /// 否则按删除时间做对账/同步会拿到一个不稳定的值。
    func softDeleteNote(id: String) throws {
        let now = DayCueClock.nowUTCString()
        let statement = try database.prepare(
            "UPDATE note SET deleted_at = COALESCE(deleted_at, ?), updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(now), .text(now), .text(id)])
        try statement.run()
    }

    // MARK: - 查询

    /// 按 id 取回一条未删除的笔记。已软删除的笔记在这里返回 nil：
    /// 「deletedAt 非空的笔记不得出现在任何查询结果里」是硬规则，不因为调用方式而放宽。
    func note(id: String) throws -> NoteRecord? {
        let statement = try database.prepare(
            "SELECT \(noteColumns) FROM note WHERE id = ? AND deleted_at IS NULL LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeNote(statement)
    }

    /// 按来源定位笔记。
    ///
    /// includeDeleted 默认 false；但「候选 -> 笔记录入」必须传 true：
    /// 它要看得见已被用户删除的笔记，否则一次解析重试就会把用户删掉的笔记重新写回来。
    func note(originCaptureId: String, originItemId: String, includeDeleted: Bool = false) throws -> NoteRecord? {
        var sql = "SELECT \(noteColumns) FROM note WHERE origin_capture_id = ? AND origin_item_id = ?"
        if !includeDeleted { sql += " AND deleted_at IS NULL" }
        sql += " ORDER BY created_at ASC, id ASC LIMIT 1;"
        let statement = try database.prepare(sql)
        try statement.bind([.text(originCaptureId), .text(originItemId)])
        guard try statement.step() else { return nil }
        return Self.makeNote(statement)
    }

    /// 列表分页。newest first，同一时刻的按 id 兜底排序，保证分页不会漏行或重复。
    func notes(limit: Int = 100, offset: Int = 0) throws -> [NoteRecord] {
        try runNoteQuery(
            sql: "SELECT \(noteColumns) FROM note WHERE deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?;",
            values: [.integer(Int64(limit)), .integer(Int64(offset))]
        )
    }

    /// 按课程提示筛选。
    ///
    /// 空字符串不会被当成「不过滤」——库里没有 course_hint 为空的笔记，
    /// 想要不带筛选的列表必须调用 notes(limit:offset:)，避免「空条件恰好返回全部」这种隐式行为。
    func notes(courseHint: String, limit: Int = 100, offset: Int = 0) throws -> [NoteRecord] {
        try runNoteQuery(
            sql: """
            SELECT \(noteColumns) FROM note
            WHERE deleted_at IS NULL AND course_hint = ?
            ORDER BY created_at DESC, id DESC
            LIMIT ? OFFSET ?;
            """,
            values: [.text(courseHint), .integer(Int64(limit)), .integer(Int64(offset))]
        )
    }

    /// 关键词搜索（标题 / 正文 / 标签）。
    ///
    /// 用 instr 而不是 LIKE：LIKE 会把用户输入的 % 和 _ 当成通配符，
    /// 搜「50%」会命中一大堆无关笔记；instr 是纯字面匹配，连转义都不需要。
    /// lower() 在 SQLite 里只对 ASCII 生效，中文没有大小写，正好够用。
    func notes(searchText: String, limit: Int = 100, offset: Int = 0) throws -> [NoteRecord] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空关键词按「不筛选」处理：界面把搜索框清空之后应该立刻回到完整列表。
        guard !keyword.isEmpty else { return try notes(limit: limit, offset: offset) }
        return try runNoteQuery(
            sql: """
            SELECT \(noteColumns) FROM note
            WHERE deleted_at IS NULL
              AND (instr(lower(title), lower(?)) > 0
                OR instr(lower(body), lower(?)) > 0
                OR instr(lower(COALESCE(tags, '')), lower(?)) > 0)
            ORDER BY created_at DESC, id DESC
            LIMIT ? OFFSET ?;
            """,
            values: [
                .text(keyword),
                .text(keyword),
                .text(keyword),
                .integer(Int64(limit)),
                .integer(Int64(offset))
            ]
        )
    }

    /// 某条原始记录产出的笔记，按产生顺序正序（详情页按产出顺序读更自然）。
    func notes(originCaptureId: String) throws -> [NoteRecord] {
        try runNoteQuery(
            sql: """
            SELECT \(noteColumns) FROM note
            WHERE deleted_at IS NULL AND origin_capture_id = ?
            ORDER BY created_at ASC, id ASC;
            """,
            values: [.text(originCaptureId)]
        )
    }

    /// 笔记条数。默认统计未删除的，界面上的「共 N 条」用它。
    func noteCount(includeDeleted: Bool = false) throws -> Int {
        var sql = "SELECT COUNT(*) FROM note"
        if !includeDeleted { sql += " WHERE deleted_at IS NULL" }
        sql += ";"
        let statement = try database.prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// 查询骨架只写一次，避免每个方法重复一遍「准备、绑定、循环取行」。
    private func runNoteQuery(sql: String, values: [SQLiteValue]) throws -> [NoteRecord] {
        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [NoteRecord] = []
        while try statement.step() {
            result.append(Self.makeNote(statement))
        }
        return result
    }
}

public extension DayCueStore {

    /// 行映射只写一次。列顺序由 noteColumns 定义，改动列时只需要改这两个地方。
    static func makeNote(_ statement: SQLiteStatement) -> NoteRecord {
        NoteRecord(
            id: statement.string(0) ?? "",
            title: statement.string(1) ?? "",
            body: statement.string(2) ?? "",
            tags: NoteTagCodec.decode(statement.string(3)),
            courseHint: statement.string(4),
            originCaptureId: statement.string(5),
            originItemId: statement.string(6),
            originKind: NoteOriginKind(rawValue: statement.string(7) ?? "manual") ?? .manual,
            userEdited: statement.bool(8),
            occurredAt: statement.string(9),
            createdAt: statement.string(10) ?? "",
            updatedAt: statement.string(11) ?? "",
            deletedAt: statement.string(12)
        )
    }

    /// INSERT / upsert 的参数顺序与 noteColumns 一致；UPDATE 的列顺序不同，因此不复用它。
    ///
    /// 写成 internal 而不是 private：它要被本文件另一个 extension 里的写入方法调用，
    /// 跨 extension 的 private 访问虽然合法（SE-0169），但没必要在这种地方省一个关键字。
    internal static func noteInsertValues(_ record: NoteRecord) -> [SQLiteValue] {
        [
            .text(record.id),
            .text(record.title),
            .text(record.body),
            .optionalText(NoteTagCodec.encode(record.tags)),
            .optionalText(record.courseHint),
            .optionalText(record.originCaptureId),
            .optionalText(record.originItemId),
            .text(record.originKind.rawValue),
            .bool(record.userEdited),
            .optionalText(record.occurredAt),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt)
        ]
    }
}

/// 列顺序集中一处，取值下标才不会随查询改动而错位。
/// 手写 SQLite 映射最容易错的就是位置耦合，所以宁可多一个常量。
let noteColumns = "id, title, body, tags, course_hint, origin_capture_id, origin_item_id, origin_kind, user_edited, occurred_at, created_at, updated_at, deleted_at"
