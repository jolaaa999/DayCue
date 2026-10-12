-- DayCue 服务端初始结构（PostgreSQL）。
--
-- 取舍说明：
--   * 所有用户数据表都带 user_id 且建立索引，多租户隔离靠 WHERE user_id 强制，
--     不依赖应用层"记得过滤"。
--   * 同步记录不删行，删除写 deleted_at 墓碑并抬高 version，这样离线设备
--     重新上线时能得知"它被删了"，而不是永远留在本地。
--   * 供应商密钥不进库：只放环境变量，库里最多存"是否已配置"。

CREATE TABLE IF NOT EXISTS schema_migration (
  version    INTEGER PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app_user (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL,
  display_name  TEXT NOT NULL DEFAULT '',
  password_hash TEXT NOT NULL DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ
);

-- 邮箱唯一性只在"未删除"的用户之间成立：删号后同一邮箱应能重新注册。
CREATE UNIQUE INDEX IF NOT EXISTS uq_app_user_email_live
  ON app_user (lower(email)) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS device (
  id                 TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  platform           TEXT NOT NULL CHECK (platform IN ('ios','android','macos','unknown')),
  name               TEXT NOT NULL DEFAULT '',
  capabilities_json  JSONB NOT NULL DEFAULT '{}'::jsonb,
  push_token         TEXT NOT NULL DEFAULT '',
  last_seen_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_device_user ON device(user_id);

-- 同步记录：每个 (user_id, entity_type, entity_id) 一行，version 单调递增。
CREATE TABLE IF NOT EXISTS sync_record (
  user_id    TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  version     BIGINT NOT NULL,
  payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  PRIMARY KEY (user_id, entity_type, entity_id)
);
CREATE INDEX IF NOT EXISTS idx_sync_record_cursor ON sync_record(user_id, version);

-- 全局版本序列：用 BIGSERIAL 保证同一用户内 version 严格递增且无并发重号。
CREATE SEQUENCE IF NOT EXISTS sync_version_seq;

CREATE TABLE IF NOT EXISTS media_object (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  owner_type   TEXT NOT NULL,
  owner_id     TEXT NOT NULL,
  content_type TEXT NOT NULL,
  byte_size    BIGINT NOT NULL,
  sha256       TEXT NOT NULL,
  storage_key  TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_media_user ON media_object(user_id);
CREATE INDEX IF NOT EXISTS idx_media_owner ON media_object(user_id, owner_type, owner_id);

CREATE TABLE IF NOT EXISTS memory_item (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  category     TEXT NOT NULL,
  statement    TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('candidate','confirmed','retired','conflict')),
  source_kind  TEXT NOT NULL CHECK (source_kind IN ('user_setting','user_statement','inferred')),
  confidence   DOUBLE PRECISION NOT NULL DEFAULT 0,
  source_ref   TEXT NOT NULL DEFAULT '',
  revision     BIGINT NOT NULL DEFAULT 1,
  effective_to TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_memory_user ON memory_item(user_id, category, status);

-- 记忆检索索引：删记忆必须连带删除，否则已删除内容仍会出现在检索里。
CREATE TABLE IF NOT EXISTS memory_index (
  user_id   TEXT NOT NULL,
  memory_id TEXT NOT NULL,
  token     TEXT NOT NULL,
  weight    DOUBLE PRECISION NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, memory_id, token)
);
CREATE INDEX IF NOT EXISTS idx_memory_index_token ON memory_index(user_id, token);

-- 主动消息账本：预算/冷却/去重都落库，避免多设备各自计数导致超发。
CREATE TABLE IF NOT EXISTS proactive_message (
  id               TEXT PRIMARY KEY,
  user_id          TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL,
  dedupe_key       TEXT NOT NULL,
  target_ref       TEXT NOT NULL DEFAULT '',
  state            TEXT NOT NULL CHECK (state IN ('pending','delivered','suppressed','expired','cancelled')),
  suppress_reason  TEXT NOT NULL DEFAULT '',
  scheduled_at     TIMESTAMPTZ NOT NULL,
  delivered_at     TIMESTAMPTZ,
  expires_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS idx_proactive_user_day ON proactive_message(user_id, delivered_at);
