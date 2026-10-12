-- 主动消息账本：完整的「领取协议 + 租约 + 交付确定性」扩展，以及用户时区（0002 只加了认领标记与下发内容）。
--
-- 为什么必须扩展，而不是沿用 0002 的 claimed_at：
--   * 0002 的 claimed_at 只回答"有没有被占用"，不回答"被谁占用、占用到什么时候"。
--     某个调度进程认领后崩溃，该行会永远停在 claimed_at 非空的状态，无人能安全回收
--     （回收者无法判断原执行者是否还在发送）。这里加上 claimed_by / lease_expires_at /
--     attempt_count，把"占用"升级成一段**有主、有期限、有次数**的租约。
--   * "谁先占用"与"谁还持有"是两件事。claimed_at 按 0002 的语义是**首次占用时刻**，
--     保留不动（排障时要回答"这条第一次被认领是什么时候"）；当前是否仍被持有由
--     claim_token 表达，租约回收会换发新 token，于是旧执行者的回执自然对不上。
--   * 推送不是事务：把消息交给 APNs / FCM 之后，进程可能在收到回执前崩溃，
--     此时"供应商到底收没收到"是**不可知**的。0002 没有表达这种状态的列，
--     崩溃恢复后只能盲目重发，用户会被重复打扰。delivery_status 用来把
--     「尚未发送」与「已发起投递但结果不明」区分开：后者不会被自动重发。
--   * attempt_count 需要一个上限才能收敛。没有上限时，一条永远失败的 pending 行
--     会被无限重试，每轮都占一次当日额度，把用户真正的提醒挤掉。
--
-- 边界（如实记录，不要当成已解决）：
--   * 这套语义只对**共享同一个 PostgreSQL** 的调度进程成立。它不构成跨数据库、
--     也不构成跨外部推送系统的 exactly-once：delivery_id 只是我们给供应商的稳定标识，
--     供应商是否真的按它去重取决于该供应商的语义，我们无法验证。
--   * delivery_status='attempted_unknown' 只是**标记不确定性**，不是确认。
--     被标记的行需要人工或后续的对账（例如供应商侧按 delivery_id 查询）来收口，
--     代码里没有任何自动收口路径。
--   * 租约到期只说明原执行者太久没有回报，**不代表它一定死了**：它仍可能正在发送。
--     因此租约回收对"结果不明"的行只延长租约、不重新入队（宁可不发，也不重复打扰）。

ALTER TABLE proactive_message
  -- 领取者标识（调度进程自报的稳定名字）。用于排障："这条是谁领的"。
  ADD COLUMN IF NOT EXISTS claimed_by        TEXT NOT NULL DEFAULT '',
  -- 领取凭证。非空表示"当前有人持有"，是全部结果写入的比对依据；
  -- 租约回收会换发新值，因此旧执行者的凭证会立刻失效。
  ADD COLUMN IF NOT EXISTS claim_token       TEXT NOT NULL DEFAULT '',
  -- 租约截止时刻。到点即视为可回收，回收动作是显式的一次 Recover，不在读写路径上顺手改。
  ADD COLUMN IF NOT EXISTS lease_expires_at  TIMESTAMPTZ,
  -- 累计领取次数，用来给重试封顶。每次领取 +1（含租约回收后的再次领取）。
  ADD COLUMN IF NOT EXISTS attempt_count     INTEGER NOT NULL DEFAULT 0,
  -- 稳定投递标识：一次领取生成一个，重试同一条时保持不变，交给供应商做幂等/对账。
  ADD COLUMN IF NOT EXISTS delivery_id       TEXT NOT NULL DEFAULT '',
  -- 交付确定性：not_attempted=尚未把消息交给供应商（可安全重发）；
  -- sending=本次已发起投递、结果未回；attempted_unknown=投递已发起但结果不可知（不自动重发）。
  ADD COLUMN IF NOT EXISTS delivery_status   TEXT NOT NULL DEFAULT 'not_attempted',
  -- 不确定性被认定下来的时刻，只作审计。
  ADD COLUMN IF NOT EXISTS delivery_unknown_at TIMESTAMPTZ;

-- 为什么用 CHECK 而不是只靠 Go 侧常量：写入路径有若干条 SQL，漏掉一处就会留下
-- 一个谁都不认识的取值，排障时无法判断"这条到底发没发出去"。
ALTER TABLE proactive_message
  ADD CONSTRAINT ck_proactive_delivery_status
  CHECK (delivery_status IN ('not_attempted','sending','attempted_unknown'));

-- 0003 之前被认领过的行，按 0002 的注释其"是否真的发出"本来就不可知；
-- 迁移时如实标成 attempted_unknown（而不是 not_attempted），避免升级后被自动重发。
UPDATE proactive_message
  SET delivery_status = 'attempted_unknown', delivery_unknown_at = COALESCE(claimed_at, now())
  WHERE claimed_at IS NOT NULL AND state = 'pending';

-- 领取查询的主路径是"未持有租约的待发行、按到期时刻升序"。
-- 0002 的 idx_proactive_claimable 条件已不成立（它按 claimed_at IS NULL 过滤），
-- 换成按 claim_token 的空/非空区分"有没有人持有"，否则索引永远不会被用到。
CREATE INDEX IF NOT EXISTS idx_proactive_claimable_free
  ON proactive_message (scheduled_at) WHERE state = 'pending' AND claim_token = '';

-- 租约回收是"扫出所有已过期租约"，按截止时刻建索引避免全表扫。
CREATE INDEX IF NOT EXISTS idx_proactive_lease_expiry
  ON proactive_message (lease_expires_at)
  WHERE state = 'pending' AND claim_token <> '';

-- 每日预算预留窗口。为什么要单独建表，而不是继续用 claimed_at 现算：
--   * 并发下的"按用户每日限额预留"必须有一个**可原子自增的行**才能成立。
--     只靠 SELECT ... FOR UPDATE SKIP LOCKED 取消息行，两个调度进程完全可以各自
--     锁住不同用户、不同行，各自都认为"额度还有余量"，合计却超过某个用户当日上限。
--   * 窗口边界一旦创建就**冻结为绝对时刻**（win_start / win_end，UTC）。
--     如果每次都按"用户当前时区 + 当前时刻"现算边界，用户改一次时区就能让
--     "今天"重新开始，当日额度被重置——那就是重复打扰。
--   * 查询"当前窗口"用的是**相交**判定（win_start <= now < win_end）：用户把时区
--     往西调（例如 Asia/Shanghai -> America/Los_Angeles）时仍落在原窗口内，
--     于是继续消耗同一份额度，而不是拿到一份新的。
--   * 边界：这不解决"往东调到下一天"的情形——那时本地自然日确实翻篇了，
--     额度按新的一天计算是设计使然，不是漏洞。
CREATE TABLE IF NOT EXISTS proactive_budget_window (
  user_id    TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  -- 窗口起点（该用户当时时区下的自然日 00:00，UTC）。
  win_start  TIMESTAMPTZ NOT NULL,
  -- 窗口止点（下一个自然日 00:00，UTC）。夏令时切换当天不是 86400 秒，所以必须存下来。
  win_end    TIMESTAMPTZ NOT NULL,
  -- reserved 是"已预留但尚未定论"的条数（在途），delivered 是"已发出"的条数。
  -- 判定用的是 delivered + reserved，把在途占用也算进当日消费，否则并发下会超发。
  reserved   INTEGER NOT NULL DEFAULT 0,
  delivered  INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, win_start),
  -- 负数是逻辑错误（释放多于预留），用约束挡住而不是让它悄悄抵消掉一天的额度。
  CHECK (reserved >= 0 AND delivered >= 0)
);

-- 按用户找窗口：主键已按 (user_id, win_start) 建索引，这里只需补一个按用户查的习惯入口。
CREATE INDEX IF NOT EXISTS idx_proactive_budget_user ON proactive_budget_window (user_id, win_end);

-- 行上记住预留发生在哪个预算窗口，释放/结算时按**这一列**精确回退，
-- 不去用 claimed_at 现算窗口：用户改时区后现算会落到另一个窗口，导致预留值永久泄漏。
-- budget_reserved 是"这一行是否真的占着窗口里的一个名额"的显式标记：
-- 靠 budget_win_start 是否为空来推断会出错——一条从未被领取就被取消的 pending 行
-- 也会被误判成"占着名额"，于是回退一个不存在的预留，把当天的额度账算坏。
ALTER TABLE proactive_message
  ADD COLUMN IF NOT EXISTS budget_win_start TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS budget_reserved  BOOLEAN NOT NULL DEFAULT false;

-- 用户时区：IANA 名字（例如 Asia/Shanghai），空表示未知。
-- 为什么允许为空、读的时候回退 UTC：老账号与从未上报过时区的客户端都拿不到这个名字，
-- 而"未知"和"UTC"在语义上是两回事（未知是没信息，UTC 是一个确定的选择）。
-- 回退 UTC 是**保守且明确**的做法：预算与静默时段按 UTC 计算可能不对，但至少是确定的；
-- 若换成服务器本地时区，同一份数据在不同机房会算出不同的"今天"，那才是真正不可审计的。
-- 库里存绝对时刻的列一律仍是 UTC，时区只决定"哪一天"和"几点算静默"。
ALTER TABLE app_user
  ADD COLUMN IF NOT EXISTS timezone TEXT;