package com.daycue.android.data.local

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Room 迁移。
 *
 * 先说明一个事实，避免接手的人误会：
 * **Android 端从未发布过 version 1**，所以不存在需要真正迁移的用户设备。
 * 这条 1 → 2 的迁移是按任务要求预置的升级路径，它的参照物是 iOS 的 Schema.swift v2 段落，
 * 目的是让「将来真的要演进表结构」这件事有一套可被测试的写法：
 * 每次改表都必须同时给出 MIGRATION、导出 schema，并用 room-testing 的 MigrationTestHelper 跑一遍。
 *
 * 为什么不用 fallbackToDestructiveMigration：本地库里可能有用户还没同步出去的笔记与课表，
 * 迁移写错就清库等于丢数据。宁可启动崩溃。
 *
 * 这里的 DDL 必须与 Room 由实体生成的建表语句逐字对应（含索引名与默认值），
 * 否则 Room 会在启动时抛 IllegalStateException（"Migration didn't properly handle ..."）。
 * 索引名使用 Room 的命名约定 index_<表名>_<列名>；本文件从未被任何机器执行过，
 * 首次在真机/模拟器升级路径上跑之前，必须先用 MigrationTestHelper 验证。
 */
object DayCueMigrations {

    val MIGRATION_1_2: Migration = object : Migration(1, 2) {
        override fun migrate(db: SupportSQLiteDatabase) {
            // ---- v2 新增：笔记 ----
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS note (
                  id TEXT NOT NULL,
                  title TEXT NOT NULL,
                  body TEXT NOT NULL,
                  tags TEXT NOT NULL,
                  course_hint TEXT,
                  origin_capture_id TEXT,
                  origin_item_id TEXT,
                  origin_kind TEXT NOT NULL,
                  user_edited INTEGER NOT NULL,
                  occurred_at TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  deleted_at TEXT,
                  PRIMARY KEY(id)
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_note_created_at ON note(created_at)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_note_course_hint ON note(course_hint)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_note_origin_capture_id ON note(origin_capture_id)")

            // ---- v2 新增：课表 ----
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS course (
                  id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  teacher TEXT,
                  location TEXT,
                  term TEXT,
                  color TEXT,
                  follow_up_enabled INTEGER NOT NULL,
                  follow_up_delay_minutes INTEGER NOT NULL,
                  follow_up_mode TEXT NOT NULL DEFAULT 'every_class',
                  excluded_dates TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  deleted_at TEXT,
                  PRIMARY KEY(id)
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_term ON course(term)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_deleted_at ON course(deleted_at)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS course_schedule_rule (
                  id TEXT NOT NULL,
                  course_id TEXT NOT NULL,
                  weekday INTEGER NOT NULL,
                  section_start INTEGER NOT NULL,
                  section_end INTEGER NOT NULL,
                  start_time_local TEXT NOT NULL,
                  end_time_local TEXT NOT NULL,
                  week_parity TEXT NOT NULL,
                  week_start INTEGER NOT NULL,
                  week_end INTEGER NOT NULL,
                  effective_from TEXT,
                  effective_to TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(id),
                  FOREIGN KEY(course_id) REFERENCES course(id) ON UPDATE NO ACTION ON DELETE CASCADE
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_schedule_rule_course_id ON course_schedule_rule(course_id)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_schedule_rule_weekday ON course_schedule_rule(weekday)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS course_instance (
                  id TEXT NOT NULL,
                  course_id TEXT NOT NULL,
                  rule_id TEXT,
                  starts_at_utc TEXT NOT NULL,
                  ends_at_utc TEXT NOT NULL,
                  timezone TEXT NOT NULL,
                  status TEXT NOT NULL,
                  location TEXT,
                  note TEXT,
                  origin TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(id),
                  FOREIGN KEY(course_id) REFERENCES course(id) ON UPDATE NO ACTION ON DELETE CASCADE
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_instance_starts_at_utc ON course_instance(starts_at_utc)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_instance_course_id ON course_instance(course_id)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_course_instance_rule_id_starts_at_utc ON course_instance(rule_id, starts_at_utc)")

            // ---- v2 新增：课后追问 ----
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS follow_up (
                  id TEXT NOT NULL,
                  course_instance_id TEXT NOT NULL,
                  course_id TEXT NOT NULL,
                  state TEXT NOT NULL,
                  scheduled_at_utc TEXT NOT NULL,
                  delivered_at_utc TEXT,
                  snooze_until_utc TEXT,
                  attempt INTEGER NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(id),
                  FOREIGN KEY(course_instance_id) REFERENCES course_instance(id) ON UPDATE NO ACTION ON DELETE CASCADE
                )
                """.trimIndent(),
            )
            // 这一个索引同时承担「一个实例最多一条追问」的产品约束，必须是 UNIQUE。
            db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_follow_up_course_instance_id ON follow_up(course_instance_id)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_follow_up_state_scheduled_at_utc ON follow_up(state, scheduled_at_utc)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_follow_up_course_id ON follow_up(course_id)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS follow_up_reply (
                  id TEXT NOT NULL,
                  follow_up_id TEXT NOT NULL,
                  course_id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  text TEXT,
                  transcript TEXT,
                  media_path TEXT,
                  note_id TEXT,
                  task_id TEXT,
                  created_at TEXT NOT NULL,
                  PRIMARY KEY(id),
                  FOREIGN KEY(follow_up_id) REFERENCES follow_up(id) ON UPDATE NO ACTION ON DELETE CASCADE
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_follow_up_reply_follow_up_id ON follow_up_reply(follow_up_id)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_follow_up_reply_course_id ON follow_up_reply(course_id)")

            // ---- v2 新增：地点与主动消息 ----
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS place (
                  id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  latitude REAL NOT NULL,
                  longitude REAL NOT NULL,
                  radius_meters REAL NOT NULL,
                  address TEXT,
                  confirmed_by_user INTEGER NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  deleted_at TEXT,
                  PRIMARY KEY(id)
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_place_deleted_at ON place(deleted_at)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS geo_rule (
                  id TEXT NOT NULL,
                  place_id TEXT NOT NULL,
                  trigger TEXT NOT NULL,
                  title TEXT NOT NULL,
                  body TEXT,
                  min_dwell_seconds INTEGER NOT NULL,
                  cooldown_seconds INTEGER NOT NULL,
                  active_from_local TEXT,
                  active_to_local TEXT,
                  weekdays TEXT NOT NULL,
                  enabled INTEGER NOT NULL,
                  expires_at_utc TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  deleted_at TEXT,
                  PRIMARY KEY(id),
                  FOREIGN KEY(place_id) REFERENCES place(id) ON UPDATE NO ACTION ON DELETE CASCADE
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_geo_rule_place_id ON geo_rule(place_id)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_geo_rule_enabled ON geo_rule(enabled)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS proactive_message (
                  id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  dedupe_key TEXT NOT NULL,
                  target_ref TEXT,
                  state TEXT NOT NULL,
                  suppress_reason TEXT,
                  scheduled_at_utc TEXT NOT NULL,
                  delivered_at_utc TEXT,
                  expires_at_utc TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(id)
                )
                """.trimIndent(),
            )
            // 去重的最后一道防线：应用层算错时由数据库拒绝第二条。
            db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_proactive_message_dedupe_key ON proactive_message(dedupe_key)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_proactive_message_state_scheduled_at_utc ON proactive_message(state, scheduled_at_utc)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_proactive_message_kind_delivered_at_utc ON proactive_message(kind, delivered_at_utc)")

            // ---- v2 新增：同步 ----
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS sync_cursor (
                  scope TEXT NOT NULL,
                  cursor TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(scope)
                )
                """.trimIndent(),
            )
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS sync_tombstone (
                  entity_type TEXT NOT NULL,
                  entity_id TEXT NOT NULL,
                  deleted_at TEXT NOT NULL,
                  remote_version INTEGER,
                  PRIMARY KEY(entity_type, entity_id)
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS index_sync_tombstone_deleted_at ON sync_tombstone(deleted_at)")
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS sync_snapshot (
                  entity_type TEXT NOT NULL,
                  entity_id TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  captured_at TEXT NOT NULL,
                  PRIMARY KEY(entity_type, entity_id, provider)
                )
                """.trimIndent(),
            )

            // ---- v1 既有表补列 ----
            // memory_item 在 v1 就有了；source_kind 必须带 DEFAULT，否则已有的行没法满足 NOT NULL。
            db.execSQL("ALTER TABLE memory_item ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'inferred'")
        }
    }

    /**
     * v2 -> v3：地点坐标系 + 规则关联任务。
     *
     * 为什么用 ADD COLUMN 而不是重建表：两张表都已有用户数据（v2 是真机可能存在的版本），
     * 重建表要么写一整套「建新表 / 搬数据 / 删旧表 / 改名」，要么冒着漏列的风险；
     * 而这两列都允许有确定默认值（坐标系 wgs84、关联任务为 NULL），ADD COLUMN 是等价且更小的动作。
     *
     * DEFAULT 'wgs84' 必须与 PlaceRecord 的 @ColumnInfo(defaultValue = "wgs84") 逐字一致，
     * 否则 Room 在启动校验时会对不上——这条由 MigrationSchemaDriftTest 与真机 MigrationTestHelper 双重把关。
     */
    val MIGRATION_2_3: Migration = object : Migration(2, 3) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE place ADD COLUMN coordinate_system TEXT NOT NULL DEFAULT 'wgs84'")
            db.execSQL("ALTER TABLE geo_rule ADD COLUMN linked_task_id TEXT")
            // 索引必须一起补：Room 的实体声明了它，少了索引启动校验同样会失败。
            db.execSQL("CREATE INDEX IF NOT EXISTS index_geo_rule_linked_task_id ON geo_rule(linked_task_id)")
        }
    }

    /** Room 在 build 时按顺序取用；将来加 MIGRATION_3_4 时只需要往这里追加。 */
    val ALL: Array<Migration> = arrayOf(MIGRATION_1_2, MIGRATION_2_3)
}
