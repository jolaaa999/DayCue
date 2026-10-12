import Foundation

/// 建库脚本与版本迁移。
///
/// 迁移做成「版本号 + 顺序执行」的形式，是因为第一阶段的表结构后面还会长（课表、记忆证据等），
/// 一旦用户设备上已经有数据，就必须靠版本号滚动升级，不能靠 IF NOT EXISTS 糊过去。
public enum DayCueSchema {

    public static let currentVersion = 3

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
        case 2:
            try database.execute(v2)
        case 3:
            try database.execute(v3)
        default:
            throw SQLiteError.execFailed(code: 0, message: "未知的迁移版本 \(version)")
        }
    }

    /// v3：给 place 补一列坐标系。
    ///
    /// 为什么不并回 v2：已经有设备的库停在 v2，改 v2 对它们不会生效（版本号已记录），
    /// 于是老设备会缺列、读取时才炸。SQLite 只能新增列，不能改既有列定义，
    /// 所以只能靠新版本号滚上去。
    ///
    /// 默认值给 'wgs84' 是有依据的：这一列存在之前，地点只能由设备定位或手工输入产生，
    /// 两者给的都是 WGS-84。所以给老数据补这个默认值是**如实回填**，
    /// 不是拿一个默认值掩盖「我们不知道」。
    private static let v3 = """
    ALTER TABLE place ADD COLUMN coordinate_system TEXT NOT NULL DEFAULT 'wgs84';
    """


    /// v2：笔记、课表与课程实例、课后追问、地点与主动规则、记忆修订、同步快照、设备。
    ///
    /// 为什么单开一版而不是改 v1：用户设备上可能已经有 v1 数据，
    /// 只能靠版本号滚上去；而 SQLite 也改不了既有 CHECK 约束，只能新增表与新增列。
    private static let v2 = """
    -- 笔记：不能再只藏在 proposal.payload_json 里，否则列表和详情都无从谈起。
    -- 保留 origin_capture_id / origin_item_id，是为了让「这条笔记从哪来」永远可追溯。
    CREATE TABLE IF NOT EXISTS note (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      tags TEXT,
      course_hint TEXT,
      origin_capture_id TEXT,
      origin_item_id TEXT,
      origin_kind TEXT NOT NULL CHECK (origin_kind IN ('capture','follow_up','manual','memory')),
      user_edited INTEGER NOT NULL DEFAULT 0,
      occurred_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_note_created ON note(created_at);
    CREATE INDEX IF NOT EXISTS idx_note_course ON note(course_hint);
    CREATE INDEX IF NOT EXISTS idx_note_origin_capture ON note(origin_capture_id);
    -- 同一条抓取条目最多只能派生一条笔记。应用层已经在事务里先查后写，
    -- 但那只在"同一个进程内串行执行"时成立；加数据库层部分唯一索引作为兜底，
    -- 避免并发或重放时产生两条同来源笔记。
    CREATE UNIQUE INDEX IF NOT EXISTS uq_note_origin_item
      ON note(origin_capture_id, origin_item_id)
      WHERE origin_capture_id IS NOT NULL AND origin_item_id IS NOT NULL;

    -- 课程：term 是学期标识，便于一学期结束后整体归档而不删数据。
    CREATE TABLE IF NOT EXISTS course (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      teacher TEXT,
      location TEXT,
      term TEXT,
      color TEXT,
      follow_up_enabled INTEGER NOT NULL DEFAULT 0,
      follow_up_delay_minutes INTEGER NOT NULL DEFAULT 5,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_course_term ON course(term);

    -- 每周重复规则。week_parity 承担单双周，section_start/end 承担节次，
    -- 两者都是「课表在纸面上长什么样」，不参与实际发生与否的判断。
    CREATE TABLE IF NOT EXISTS course_schedule_rule (
      id TEXT PRIMARY KEY,
      course_id TEXT NOT NULL REFERENCES course(id) ON DELETE CASCADE,
      weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
      section_start INTEGER NOT NULL,
      section_end INTEGER NOT NULL,
      start_time_local TEXT NOT NULL,
      end_time_local TEXT NOT NULL,
      week_parity TEXT NOT NULL CHECK (week_parity IN ('all','odd','even')),
      week_start INTEGER NOT NULL DEFAULT 1,
      week_end INTEGER NOT NULL DEFAULT 30,
      effective_from TEXT,
      effective_to TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_rule_course ON course_schedule_rule(course_id);
    CREATE INDEX IF NOT EXISTS idx_rule_weekday ON course_schedule_rule(weekday);

    -- 课程实例：每次课一行。调课改时间，停课置 cancelled，都是改这一行。
    -- 「预计结束」只用于排通知，绝不等于「实际下课」，更不等于出勤。
    CREATE TABLE IF NOT EXISTS course_instance (
      id TEXT PRIMARY KEY,
      course_id TEXT NOT NULL REFERENCES course(id) ON DELETE CASCADE,
      rule_id TEXT,
      starts_at_utc TEXT NOT NULL,
      ends_at_utc TEXT NOT NULL,
      timezone TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('scheduled','cancelled','rescheduled')),
      location TEXT,
      note TEXT,
      origin TEXT NOT NULL CHECK (origin IN ('rule','manual','ics','ocr')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_instance_start ON course_instance(starts_at_utc);
    CREATE INDEX IF NOT EXISTS idx_instance_course ON course_instance(course_id);

    -- 课后追问：一条实例最多一条追问，避免重复打扰。
    CREATE TABLE IF NOT EXISTS follow_up (
      id TEXT PRIMARY KEY,
      course_instance_id TEXT NOT NULL REFERENCES course_instance(id) ON DELETE CASCADE,
      course_id TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('scheduled','delivered','snoozed','skipped','answered','expired','cancelled')),
      scheduled_at_utc TEXT NOT NULL,
      delivered_at_utc TEXT,
      snooze_until_utc TEXT,
      attempt INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (course_instance_id)
    );
    CREATE INDEX IF NOT EXISTS idx_follow_up_state ON follow_up(state, scheduled_at_utc);

    -- 追问回复：归档时必须能关联回课程、笔记与任务。
    CREATE TABLE IF NOT EXISTS follow_up_reply (
      id TEXT PRIMARY KEY,
      follow_up_id TEXT NOT NULL REFERENCES follow_up(id) ON DELETE CASCADE,
      course_id TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('text','audio')),
      text TEXT,
      transcript TEXT,
      media_path TEXT,
      note_id TEXT,
      task_id TEXT,
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_reply_follow_up ON follow_up_reply(follow_up_id);
    CREATE INDEX IF NOT EXISTS idx_reply_course ON follow_up_reply(course_id);

    -- 记忆：v1 的表太窄，这里补列。status 覆盖候选/确认/失效/冲突。
    CREATE TABLE IF NOT EXISTS memory_revision (
      id TEXT PRIMARY KEY,
      memory_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      kind TEXT NOT NULL,
      statement TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('candidate','confirmed','retired','conflict')),
      confidence REAL,
      source_kind TEXT NOT NULL CHECK (source_kind IN ('user_setting','user_statement','inferred')),
      source_ref TEXT,
      effective_from TEXT,
      effective_to TEXT,
      created_at TEXT NOT NULL,
      UNIQUE (memory_id, revision)
    );
    CREATE INDEX IF NOT EXISTS idx_memory_rev_memory ON memory_revision(memory_id);

    CREATE TABLE IF NOT EXISTS memory_control (
      category TEXT PRIMARY KEY,
      recording_enabled INTEGER NOT NULL DEFAULT 1,
      updated_at TEXT NOT NULL
    );

    -- 记忆检索索引：纯本地关键词倒排，删记忆时必须一起清。
    CREATE TABLE IF NOT EXISTS memory_index (
      memory_id TEXT NOT NULL,
      token TEXT NOT NULL,
      weight REAL NOT NULL DEFAULT 1.0,
      PRIMARY KEY (memory_id, token)
    );
    CREATE INDEX IF NOT EXISTS idx_memory_index_token ON memory_index(token);

    -- 地点：只保存用户确认过的地点与半径，默认不记录轨迹。
    CREATE TABLE IF NOT EXISTS place (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      radius_meters REAL NOT NULL,
      address TEXT,
      confirmed_by_user INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    );

    -- 位置规则：enter/exit 条件 + 生效时段 + 冷却。
    CREATE TABLE IF NOT EXISTS geo_rule (
      id TEXT PRIMARY KEY,
      place_id TEXT NOT NULL REFERENCES place(id) ON DELETE CASCADE,
      trigger TEXT NOT NULL CHECK (trigger IN ('enter','exit','dwell')),
      title TEXT NOT NULL,
      body TEXT,
      min_dwell_seconds INTEGER NOT NULL DEFAULT 0,
      cooldown_seconds INTEGER NOT NULL DEFAULT 3600,
      active_from_local TEXT,
      active_to_local TEXT,
      weekdays TEXT,
      enabled INTEGER NOT NULL DEFAULT 1,
      expires_at_utc TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_geo_rule_place ON geo_rule(place_id);

    -- 主动消息账本：预算、冷却、去重都在这里判，不靠内存状态。
    CREATE TABLE IF NOT EXISTS proactive_message (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('follow_up','geo','schedule','review','reminder')),
      dedupe_key TEXT NOT NULL,
      target_ref TEXT,
      state TEXT NOT NULL CHECK (state IN ('pending','delivered','suppressed','expired','cancelled')),
      suppress_reason TEXT,
      scheduled_at_utc TEXT NOT NULL,
      delivered_at_utc TEXT,
      expires_at_utc TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (dedupe_key)
    );
    CREATE INDEX IF NOT EXISTS idx_proactive_state ON proactive_message(state, scheduled_at_utc);
    CREATE INDEX IF NOT EXISTS idx_proactive_kind ON proactive_message(kind, delivered_at_utc);

    -- 同步快照：三方比较（本地 / 外部 / 上次快照）靠它。
    CREATE TABLE IF NOT EXISTS sync_snapshot (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      captured_at TEXT NOT NULL,
      PRIMARY KEY (entity_type, entity_id, provider)
    );

    -- 设备与账号：不登录也能用，所以这两张表可以为空。
    CREATE TABLE IF NOT EXISTS account (
      id TEXT PRIMARY KEY,
      email TEXT,
      display_name TEXT,
      server_url TEXT,
      token_ref TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS device (
      id TEXT PRIMARY KEY,
      account_id TEXT,
      platform TEXT NOT NULL CHECK (platform IN ('ios','android','macos','unknown')),
      name TEXT,
      capabilities_json TEXT,
      push_token TEXT,
      last_seen_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 同步游标：增量拉取靠它，删除传播靠 tombstone 表。
    CREATE TABLE IF NOT EXISTS sync_cursor (
      scope TEXT PRIMARY KEY,
      cursor TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sync_tombstone (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      deleted_at TEXT NOT NULL,
      remote_version INTEGER,
      PRIMARY KEY (entity_type, entity_id)
    );
    """

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
