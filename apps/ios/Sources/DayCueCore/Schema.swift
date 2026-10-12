import Foundation

/// 建库脚本与版本迁移。
///
/// 迁移做成「版本号 + 顺序执行」的形式，是因为第一阶段的表结构后面还会长（课表、记忆证据等），
/// 一旦用户设备上已经有数据，就必须靠版本号滚动升级，不能靠 IF NOT EXISTS 糊过去。
public enum DayCueSchema {

    public static let currentVersion = 1

    public static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
              version INTEGER PRIMARY KEY,
              applied_at TEXT NOT NULL
            );
            """
        )

        let applied = try appliedVersions(database)
        for version in 1...currentVersion where !applied.contains(version) {
            try database.transaction {
                try migrate(version: version, database: database)
                let statement = try database.prepare(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);"
                )
                try statement.bind([.integer(Int64(version)), .text(DayCueClock.nowUTCString())])
                try statement.run()
            }
        }
    }

    private static func appliedVersions(_ database: SQLiteDatabase) throws -> Set<Int> {
        let statement = try database.prepare("SELECT version FROM schema_migrations;")
        var versions: Set<Int> = []
        while try statement.step() {
            versions.insert(statement.int(0))
        }
        return versions
    }

    private static func migrate(version: Int, database: SQLiteDatabase) throws {
        switch version {
        case 1:
            try database.execute(v1)
        default:
            throw SQLiteError.execFailed(code: 0, message: "未知的迁移版本 \(version)")
        }
    }

    /// v1：捕获 / 附件 / 候选 / 任务 / 外部绑定 / Outbox / 设置 / 记忆。
    /// CHECK 约束显式写出来，是为了让「状态机只能在代码里变」这件事在库层也兜一层。
    private static let v1 = """
    CREATE TABLE IF NOT EXISTS capture_item (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('text','audio','image')),
      raw_text TEXT,
      transcript TEXT,
      ocr_text TEXT,
      user_edited INTEGER NOT NULL DEFAULT 0,
      media_path TEXT,
      recorded_at TEXT NOT NULL,
      recorded_timezone TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('local','extracting','extracted','failed','needs_clarification')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_capture_item_status ON capture_item(status);
    CREATE INDEX IF NOT EXISTS idx_capture_item_recorded_at ON capture_item(recorded_at);

    CREATE TABLE IF NOT EXISTS attachment (
      id TEXT PRIMARY KEY,
      capture_id TEXT NOT NULL REFERENCES capture_item(id) ON DELETE CASCADE,
      media_type TEXT NOT NULL,
      local_path TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_attachment_capture ON attachment(capture_id);

    CREATE TABLE IF NOT EXISTS extraction_proposal (
      id TEXT PRIMARY KEY,
      capture_id TEXT NOT NULL REFERENCES capture_item(id) ON DELETE CASCADE,
      schema_version TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      mode TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('pending','accepted','rejected','needs_clarification')),
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_proposal_capture ON extraction_proposal(capture_id);

    CREATE TABLE IF NOT EXISTS task (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      detail TEXT,
      status TEXT NOT NULL CHECK (status IN ('open','done','cancelled')),
      due_kind TEXT NOT NULL CHECK (due_kind IN ('none','date','datetime')),
      due_local TEXT,
      due_utc TEXT,
      timezone TEXT NOT NULL,
      remind_local TEXT,
      remind_utc TEXT,
      course_hint TEXT,
      origin_capture_id TEXT,
      origin_item_id TEXT,
      external_write_state TEXT NOT NULL CHECK (external_write_state IN ('not_requested','waiting_for_permission','pending','written','failed','unknown','needs_reconciliation')),
      last_receipt_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_task_status ON task(status);
    CREATE INDEX IF NOT EXISTS idx_task_external_state ON task(external_write_state);
    CREATE INDEX IF NOT EXISTS idx_task_origin_capture ON task(origin_capture_id);

    CREATE TABLE IF NOT EXISTS external_binding (
      task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
      provider TEXT NOT NULL,
      list_id TEXT,
      list_title TEXT,
      external_id TEXT,
      external_last_modified TEXT,
      snapshot_json TEXT,
      created_at TEXT NOT NULL,
      PRIMARY KEY (task_id, provider)
    );
    CREATE INDEX IF NOT EXISTS idx_external_binding_external_id ON external_binding(external_id);

    CREATE TABLE IF NOT EXISTS outbox_operation (
      id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      op TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      payload_json TEXT,
      attempt INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL CHECK (state IN ('pending','running','succeeded','failed','unknown')),
      next_retry_at TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (idempotency_key)
    );
    CREATE INDEX IF NOT EXISTS idx_outbox_state ON outbox_operation(state, next_retry_at);
    CREATE INDEX IF NOT EXISTS idx_outbox_entity ON outbox_operation(entity_type, entity_id);

    CREATE TABLE IF NOT EXISTS app_setting (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS memory_item (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      statement TEXT NOT NULL,
      status TEXT NOT NULL,
      source_capture_id TEXT,
      review_at TEXT,
      created_at TEXT NOT NULL,
      deleted_at TEXT
    );
    """
}
