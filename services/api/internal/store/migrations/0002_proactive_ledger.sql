-- 主动消息账本的「认领租约」与「下发内容」扩展（0001 只建了账本骨架）。
--
-- 为什么必须扩展，而不是只靠 0001：
--   * 0001 没有「已认领」标记。调度循环必须能原子地占用一条到期行，
--     否则并发的两个循环（甚至同一进程的两轮重叠）会把同一条消息各发一次。
--     这里用语义明确的 claimed_at 时间戳表达「占用中」，而不是给 state 硬塞一个
--     'claimed' 取值：state 的五个取值（pending/delivered/suppressed/expired/cancelled）
--     被客户端、契约与 CHECK 约束同时引用，改它会牵动三方；claimed_at 额外还能回答
--     「占用发生在什么时候」，是排障与将来做租约超时回收的唯一依据。
--   * 0001 没有设备列，而「令牌失效时取消该设备上尚未发出的 pending 行」必须知道
--     一条 pending 行要发给哪台设备。device_id 由调度器认领后回填（见 runner）。
--   * 0001 没有下发内容列。客户端账本可以不存标题正文（它在本地渲染），
--     但服务端要发推送就必须知道发什么，否则组装出的 push.Message 是空内容，
--     会被 push.Guard 以 empty_message 拒绝。正文由入队方写入，不从 target_ref 借道：
--     target_ref 的真实语义是**冷却键**（例如 geo_rule 的 id），与设备、正文都无关。
--
-- 边界（如实记录，不要当成已解决）：
--   * claimed_at 只是「谁先占用」的标记，不带租约超时。若某个调度进程在认领后崩溃、
--     且未走 Release，该行会一直停在 claimed_at 非空状态，直到人工清理或未来实现
--     租约回收；它**不能**自动恢复。
--   * 这套预留只对「共享同一个 PostgreSQL 的调度进程」有效。
ALTER TABLE proactive_message
  ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS device_id  TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS title      TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS body       TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS deep_link  TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS data_json  JSONB NOT NULL DEFAULT '{}'::jsonb;

-- 认领查询固定是「state='pending' 且未被占用、按到期时刻升序」，做部分索引避免随账本增长全表扫描。
CREATE INDEX IF NOT EXISTS idx_proactive_claimable
  ON proactive_message (scheduled_at) WHERE state = 'pending' AND claimed_at IS NULL;
