package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ---------- 主动消息账本（PostgreSQL 实现） ----------
//
// 本文件实现 0003 迁移定义的**完整领取协议**：租约 + 领取凭证 + 按用户限额的原子预算预留。
//
// 三条不变式，改动本文件时必须同时成立：
//  1. 领取 = 同一事务里「按用户限额预留额度 + 写租约 + attempt_count+1」；
//  2. 除 Recover 之外的一切状态写入都必须带 (claim_token, 租约未过期) 校验；
//  3. 释放/结算按行上的 budget_win_start 精确回退预留，绝不按当前时刻现算窗口。
//
// SQL 集中在这里，并登记进统一清单，让 postgres_test.go 的"用户域语句必须带 user_id"
// 断言同样覆盖它们。按主键 id 更新的语句都通过 id 反查 user_id 做用户域归属校验。
const (
	// 入队用 ON CONFLICT DO NOTHING 实现幂等：同一 (user_id, dedupe_key) 重复入队不产生第二行也不报错。
	sqlProactiveInsert = `INSERT INTO proactive_message
	(id, user_id, kind, dedupe_key, target_ref, device_id, state, suppress_reason,
	 title, body, deep_link, data_json, scheduled_at, delivered_at, expires_at, claimed_at,
	 claimed_by, claim_token, lease_expires_at, attempt_count, delivery_id, delivery_status,
	 delivery_unknown_at, budget_win_start, budget_reserved, created_at, updated_at)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16,
	 $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27)
	ON CONFLICT (user_id, dedupe_key) DO NOTHING`

	// 领取主查询：一条语句完成「找预算窗口 → 按用户限额预留 → 写租约 → 读回结果」。
	//
	// 为什么必须是一条语句而不是几条：按限额预留的原子性需要一个**双方都会写到的行**。
	// 各调度进程领取的往往是不同用户、不同的消息行，只锁消息行根本无法比较"合计发了多少"；
	// 而所有为同一用户、同一时间窗口打算预留的事务都会写同一行 proactive_budget_window，
	// 于是它们在这里串行化，限额判定才成立。
	//
	// FOR UPDATE SKIP LOCKED 仍然必要：它让并发事务跳过别人正在领的消息行，
	// 而不是排队等锁——预算行上的串行化与消息行上的跳过锁是两个不同层次的事。
	// sqlProactiveBudgetReserve 是领取协议的**第一步**：把当日的预算窗口准备好并预留本次要占用的额度。
	//
	// 为什么这件事必须单独占一条语句（而不是和认领写在同一个 WITH 里）：
	// 同一条语句里的数据修改型 CTE 共享同一个快照，彼此看不到对方的写入。
	// 于是"新建窗口"与"在窗口上累加预留"无法在一条语句内完成——新建出来的行对
	// 另一个直接读表的 UPDATE 不可见，预留永远是 0，按限额的原子预留就彻底失效
	// （这不是理论风险：真库并发测试就是靠这条断言抓出来的）。
	// 拆成两条语句后，第二条读的是第一条**同一事务内已提交到可见性**的行，且该行已被
	// 本事务锁定，因此计数与后续认领是严格一致的。
	//
	// 返回值：avail 是本次允许预留的条数（已按 daily limit 与 delivered+reserved 收敛），
	// pending 是当前还有多少条到期候选行——用来区分"额度用尽"与"没活可干"。
	sqlProactiveBudgetWindow = `WITH
	-- 已有窗口：按"相交"判定选中并加行锁。
	-- 用相交而不是按当前时区现算边界，是为了让用户切换时区时复用同一个窗口，
	-- 当日额度不会因为改了一次时区就重置。
	locked_window AS (
		SELECT win_start FROM proactive_budget_window
		WHERE user_id = $1::text AND win_start <= $2 AND win_end > $2
		FOR UPDATE
	),
	-- 没有窗口覆盖当前时刻时按用户时区开一个，边界一旦写入就冻结为绝对时刻。
	-- 边界由调用方按用户时区算好传入，所以这里不做任何时区运算。
	new_window AS (
		INSERT INTO proactive_budget_window (user_id, win_start, win_end, reserved, delivered, created_at, updated_at)
		SELECT $1::text, $3, $4, 0, 0, $2, $2
		WHERE NOT EXISTS (SELECT 1 FROM locked_window)
		ON CONFLICT (user_id, win_start) DO NOTHING
		RETURNING win_start
	)
	SELECT win_start FROM locked_window
	UNION ALL
	SELECT win_start FROM new_window`

	// sqlProactiveBudgetReserve 是领取协议的**第二步**：在已锁定的窗口行上原子累加预留。
	//
	// 为什么预留要单独一条语句：这条 UPDATE 读的是**当前已提交**的 reserved/delivered，
	// 而不是上一条语句开始时的快照。把算术放在上一条语句里会读到陈旧值——
	// 两个调度进程会各自算出"余额 2"，于是各领 2 条，当日实际超发一倍
	// （真库并发用例正是这样抓到丢更新的：6 条消息、上限 2，实测领走 4 条）。
	// 预留值本身也必须是"在旧值上累加"，而不是"算出新值再整体覆盖"。
	//
	// 承诺量口径始终是 delivered + reserved：只看 delivered 会让并发领取各算各的余额，
	// 只看 reserved 则会把已经发出去的额度当成还可用。
	sqlProactiveBudgetReserve = `WITH cur AS (
		SELECT win_start, delivered, reserved FROM proactive_budget_window
		WHERE user_id = $1::text AND win_start = $3
		FOR UPDATE
	),
	-- 本次允许预留的条数：
	--   * 额度不限（$4 <= 0）时按本次总量封顶，避免一次领走几千行；
	--   * 同时不得超过当前还有多少条到期候选行，免得给不存在的消息占额度。
	calc AS (
		SELECT c.win_start,
		       LEAST(
		           GREATEST(CASE WHEN $4::int <= 0 THEN $5::int
		                         ELSE $4::int - (c.delivered + c.reserved) END, 0),
		           $5::int,
		           (SELECT COUNT(*) FROM proactive_message m
		             WHERE m.user_id = $1::text AND m.state = 'pending'
		               AND m.scheduled_at <= $2
		               AND (m.claim_token = '' OR m.lease_expires_at <= $2)
		               AND m.attempt_count < $6
		               AND m.delivery_status <> 'attempted_unknown')
		       ) AS avail,
		       -- 同时带出候选行总数：用来区分"额度用尽"与"根本没消息"。
		       (SELECT COUNT(*) FROM proactive_message m
		         WHERE m.user_id = $1::text AND m.state = 'pending'
		           AND m.scheduled_at <= $2
		           AND (m.claim_token = '' OR m.lease_expires_at <= $2)
		           AND m.attempt_count < $6
		           AND m.delivery_status <> 'attempted_unknown') AS pending_n
		FROM cur c
	),
	upd AS (
		UPDATE proactive_budget_window w
		SET reserved = w.reserved + cp.avail, updated_at = $2
		FROM calc cp
		WHERE w.user_id = $1::text AND w.win_start = cp.win_start AND cp.avail > 0
		RETURNING w.user_id
	)
	SELECT cp.avail, cp.pending_n, ((SELECT COUNT(*) FROM upd) > 0) AS did_reserve FROM calc cp`

	// sqlProactiveClaimRows 是领取协议的**第二步**：在已经预留好额度的窗口中认领消息行。
	//
	// 为什么可以把"额度判定"交给上一条语句：预留是在同一事务里、在同一行锁之下做的，
	// 本语句只需按已预留的条数取行；两条语句之间没有别人能插进来。
	sqlProactiveClaim = `WITH
		-- 候选行：到期、无人持有（或原租约已过期）、且不是"结果不明"（那种行绝不允许自动重发）。
		-- 已达重试上限的行也不取：它们由 Recover 落成明确的 expired 终态，而不是无限重试。
		locked AS (
			SELECT id, user_id, scheduled_at
			FROM proactive_message
			WHERE state = 'pending'
			  AND scheduled_at <= $2
			  AND (claim_token = '' OR lease_expires_at <= $2)
			  AND attempt_count < $7
			  AND delivery_status <> 'attempted_unknown'
			  AND user_id = $1::text
			ORDER BY scheduled_at ASC, id ASC
			LIMIT $9
			FOR UPDATE SKIP LOCKED
		),
		-- 记账并交接所有权：凭证、租约、尝试次数、投递标识一次性写入。
		-- budget_win_start 取真实窗口起点（$3），结算时据此回退预留；
		-- 用 $3 而不是按当前时区现算，是为了让跨时区切换仍然能正确回退到当初那个窗口。
		claimed AS (
			UPDATE proactive_message m
			SET claimed_by = $4,
			    claim_token = $5,
			    lease_expires_at = $6,
			    attempt_count = m.attempt_count + 1,
			    delivery_id = $8,
			    delivery_status = 'not_attempted',
			    delivery_unknown_at = NULL,
			    budget_win_start = $3,
			    budget_reserved = true,
			    claimed_at = COALESCE(m.claimed_at, $2),
			    suppress_reason = '',
			    updated_at = $2
			FROM locked k
			WHERE m.id = k.id AND m.state = 'pending'
			RETURNING m.id, m.user_id, m.kind, m.dedupe_key, m.target_ref, m.device_id,
			          m.title, m.body, m.deep_link, m.data_json, m.scheduled_at, m.expires_at,
			          m.claimed_at, m.attempt_count, m.claim_token, m.claimed_by,
			          m.lease_expires_at, m.delivery_id
		)
		SELECT c.id, c.user_id, c.kind, c.dedupe_key, c.target_ref, c.device_id,
		       c.title, c.body, c.deep_link, c.data_json, c.scheduled_at, c.expires_at,
		       c.claimed_at, c.attempt_count, c.claim_token, c.claimed_by,
		       c.lease_expires_at, c.delivery_id
		FROM claimed c
		ORDER BY c.scheduled_at ASC, c.id ASC`

	// 先问一句"哪些用户此刻还有可领取的行"。
	//
	// 为什么先探一次而不是直接写一条跨用户的大语句：按用户限额预留需要对每个用户
	// 做"预留 + 改行"两件事，而这两个写操作必须落在**同一个事务**里；
	// 一次事务里串行处理多个用户的预算行会显著拉长持锁时间，也更容易出现死锁。
	// 代价是多一次只读查询（走 idx_proactive_claimable_free 索引），可以接受。
	sqlProactiveClaimCandidates = `SELECT user_id
	FROM proactive_message
	WHERE state = 'pending'
	  AND scheduled_at <= $1
	  AND (claim_token = '' OR lease_expires_at <= $1)
	  AND attempt_count < $3
	  AND delivery_status <> 'attempted_unknown'
	GROUP BY user_id
	ORDER BY MIN(scheduled_at) ASC, user_id ASC
	LIMIT $2`

	// 结算：只有凭证匹配且租约未过期才允许写入。
	//
	// 三个分支刻意写在 SQL 里而不是"先查再改"：先查再改之间隔着一次网络往返，
	// 租约完全可能在这中间过期，于是校验形同虚设。
	//
	//   * allowed 为假：凭证不符（租约已被回收后重新领取，说明有新执行者持有）或租约过期；
	//   * requeue：重新排队且**没有发起投递**（not_attempted / sending）——可以安全重发；
	//   * terminal：落终态。delivery_status='sending' 说明投递已经发起、结果却丢了，
	//     此时把交付确定性升级为 attempted_unknown，而不是留一个"正在发送"的假象；
	//   * 任何终态写入都会回退预留额度，并把预算窗口的 delivered+1 仅加在"确实发出"这一支。
	sqlProactiveSettle = `WITH locked AS (
		SELECT user_id, state, claim_token, lease_expires_at, attempt_count,
		       delivery_status, budget_win_start, budget_reserved
		FROM proactive_message
		WHERE id = $1
		FOR UPDATE
	),
	outcome AS (
		SELECT
			(user_id IS NOT NULL) AS found,
			(claim_token = $2 AND (lease_expires_at IS NULL OR lease_expires_at >= $5)) AS allowed,
			(state = 'pending' AND (delivery_status = 'not_attempted' OR delivery_status = 'sending')) AS requeue
		FROM locked
	),
	next_state AS (
		SELECT CASE WHEN $4::text = 'pending' THEN 'pending' ELSE $4::text END AS state,
		       ($4::text <> 'pending') AS terminal,
		       ($4::text = 'delivered') AS delivered
	),
	claimed AS (
		UPDATE proactive_message m
		SET state = n.state,
		    suppress_reason = $3,
		    delivered_at = CASE WHEN n.delivered THEN $6::timestamptz ELSE NULL END,
		    claim_token = CASE WHEN o.requeue AND NOT n.terminal THEN m.claim_token ELSE '' END,
		    claimed_by = CASE WHEN o.requeue AND NOT n.terminal THEN m.claimed_by ELSE '' END,
		    lease_expires_at = CASE WHEN o.requeue AND NOT n.terminal THEN $7::timestamptz ELSE NULL END,
		    delivery_status = CASE
		        WHEN n.terminal AND m.delivery_status = 'sending' THEN 'attempted_unknown'
		        WHEN n.terminal THEN $8
		        WHEN o.requeue AND m.delivery_status = 'not_attempted' THEN 'not_attempted'
		        ELSE m.delivery_status END,
		    delivery_unknown_at = CASE
		        WHEN n.terminal AND m.delivery_status = 'sending' THEN $5
		        ELSE m.delivery_unknown_at END,
		    budget_reserved = CASE WHEN n.terminal THEN false ELSE m.budget_reserved END,
		    updated_at = $5
		FROM outcome o, next_state n
		WHERE m.id = $1
		  AND o.found
		  AND o.allowed
		  AND (NOT n.terminal OR m.state = 'pending')
		  AND (NOT (o.requeue AND NOT n.terminal) OR $7 >= $5)
		RETURNING m.user_id
	),
	budget AS (
		UPDATE proactive_budget_window w
		SET reserved = GREATEST(w.reserved - 1, 0),
		    delivered = w.delivered + CASE WHEN $4::text = 'delivered' THEN 1 ELSE 0 END,
		    updated_at = $5
		FROM locked l, next_state n
		WHERE l.budget_reserved
		  AND l.budget_win_start IS NOT NULL
		  AND w.user_id = l.user_id
		  AND w.win_start = l.budget_win_start
		  AND n.terminal
		RETURNING w.user_id
	)
	SELECT (SELECT COUNT(*) FROM claimed) AS changed,
	       (SELECT COUNT(*) FROM locked WHERE claim_token = $2) AS token_match,
	       (SELECT COUNT(*) FROM locked) AS found,
	       (SELECT COUNT(*) FROM locked WHERE lease_expires_at IS NOT NULL AND lease_expires_at < $5) AS lease_expired`

	// 租约续期。刻意**不允许**续一个已经过期的租约：
	// 那会让"过期即可回收"这条保证失效——回收者可能刚把行放回待领取，原执行者又把它续回去。
	sqlProactiveRenewLease = `UPDATE proactive_message
	SET lease_expires_at = $4, updated_at = $3
	WHERE id = $1 AND claim_token = $2 AND state = 'pending'
	  AND lease_expires_at IS NOT NULL AND lease_expires_at >= $3
	RETURNING user_id`

	// 发起投递标记：必须在真正调用供应商**之前**写入。
	// 崩在调用中间时，恢复者看到的应当是 sending（经由 Recover 升级为 attempted_unknown），
	// 而不是 not_attempted——后者会被当成"还没发过"而盲目重发。
	sqlProactiveBeginDelivery = `UPDATE proactive_message
	SET delivery_status = 'sending', updated_at = $3
	WHERE id = $1 AND claim_token = $2 AND state = 'pending'
	  AND lease_expires_at >= $3
	RETURNING user_id`

	// 过期租约回收：一条语句同时算出分类与结果，避免"先查后改"之间租约状态漂移。
	//
	// 三类处理：未发起投递 → 放回待领取；结果不明 → 只延长租约（不重发）；
	// 已达重试上限 → 落 expired 终态。只有"放回待领取"那一支需要回退预留额度。

	// 判定事实：一条语句同时算当日已发出、当日已领取、当日"结果不明"，
	// 以及同键/同类最近发出与同键今日是否已发；预算预留从当日窗口单独读。
	// COALESCE(BOOL_OR(...), false) 让零行时不会扫出 NULL 布尔值。
	sqlProactiveHistory = `WITH win AS (
		SELECT win_start, reserved, delivered
		FROM proactive_budget_window
		WHERE user_id = $1 AND win_start <= $5 AND win_end > $5
		ORDER BY win_start DESC
		LIMIT 1
	)
	SELECT
	COUNT(*) FILTER (WHERE m.delivered_at >= $2 AND m.delivered_at < $3) AS delivered_today,
	COUNT(*) FILTER (WHERE m.claim_token <> '' AND m.lease_expires_at IS NOT NULL
	                 AND m.lease_expires_at > $5 AND m.created_at < $3) AS claimed_today,
	COUNT(*) FILTER (WHERE m.delivery_status = 'attempted_unknown'
	                 AND m.updated_at >= $2 AND m.updated_at < $3) AS unknown_today,
	MAX(m.delivered_at) FILTER (WHERE m.dedupe_key = $4) AS last_same_key,
	MAX(m.delivered_at) FILTER (WHERE m.kind = $6) AS last_same_kind,
	COALESCE(BOOL_OR(m.dedupe_key = $4 AND m.delivered_at >= $2 AND m.delivered_at < $3), false) AS same_key_today,
	COALESCE((SELECT w.reserved FROM win w), 0) AS reserved_today
	FROM proactive_message m
	WHERE m.user_id = $1`

	sqlProactiveAssignDevice = `UPDATE proactive_message
	SET device_id = $2, updated_at = $3
	WHERE id = $1 AND state = 'pending'
	RETURNING user_id`

	// 只取消"尚未发出"的行：已经发起投递（sending/attempted_unknown）的行必须走结算路径，
	// 否则一条可能已被供应商接受的消息会被静默抹掉，用户永远等不到它，账本也不再有人管它。
	// claimed_at 在这里清空是刻意的：Cancel 属于"不需要凭证的显式释放"（与 0002 的 Release 同义）。
	// 被取消的行若占着预算预留，必须一并回退，否则用户当天会白白少收一条提醒。
	sqlProactiveCancelForDevice = `WITH cancelled AS (
		UPDATE proactive_message
		SET state = 'cancelled', suppress_reason = 'device_invalid',
		    claimed_at = NULL, claim_token = '', claimed_by = '', lease_expires_at = NULL,
		    budget_reserved = false, updated_at = $3
		WHERE user_id = $1 AND device_id = $2 AND state = 'pending'
		  AND (claim_token = '' OR delivery_status = 'not_attempted')
		RETURNING user_id, budget_win_start, budget_reserved
	),
	budget_give_back AS (
		UPDATE proactive_budget_window w
		SET reserved = GREATEST(w.reserved - 1, 0), updated_at = $3
		WHERE w.user_id = $1
		  AND w.win_start IN (
		        SELECT c.budget_win_start FROM cancelled c
		        WHERE c.budget_reserved AND c.budget_win_start IS NOT NULL)
		RETURNING w.user_id
	)
	SELECT COUNT(*) FROM cancelled`

	// 回退多预留的额度：认领阶段实际拿到的行少于预留值时用它补齐。
	// 为什么需要：预留与认领之间虽在同一事务内，但候选行可能已被并发的取消
	// 或结算动作排掉，于是"预留了却没得可发"。不退就等于白占用户当天的额度。
	sqlProactiveBudgetRelease = `UPDATE proactive_budget_window
	SET reserved = GREATEST(reserved - $3, 0), updated_at = $4
	WHERE user_id = $1 AND win_start = $2
	RETURNING user_id`

	// 停用设备：清空令牌而不是删行，用户重新登记同一台设备时能覆盖回来。
	sqlDeviceInvalidate = `UPDATE device
	SET push_token = '', updated_at = $3
	WHERE user_id = $1 AND id = $2
	RETURNING user_id`

	// 用户时区：读的时候空值与非法值都回退 UTC（见 0003 迁移的说明）。
	sqlUserTimeZone    = `SELECT COALESCE(timezone, '') FROM app_user WHERE id = $1`
	sqlUserSetTimeZone = `UPDATE app_user SET timezone = NULLIF($2, ''), updated_at = $3 WHERE id = $1 RETURNING id`
)

// proactiveDeliveryUncertain 是"投递**可能已经**被供应商接受"的交付确定性集合。
//
// 为什么必须集中定义、而不是在判定处散写字面量：'sending'（已发起调用、回执随进程一起丢了）
// 与 'attempted_unknown'（恢复者已确认它结果不明）在**重发判定上语义完全相同**——
// 两者都要当作"也许用户已经收到了"，因此绝不能放回待领取队列重发。
// 早期实现只认后者，导致崩在发送调用中间的消息被重新领取并**再次发送**，
// 这正是"宁可不发也不重复打扰"那条硬规则所禁止的。
var proactiveDeliveryUncertain = []string{ProactiveDeliverySending, ProactiveDeliveryUnknown}

// sqlInList 把一个受控的取值集合渲染成 SQL 的 IN 列表。
//
// 只用于包内写死的常量集合（不含任何用户输入），因此不存在注入面；
// 用 sacnner 而不是参数占位符，是因为这些值本身要参与"哪一支分支"的语义，
// 写成 $n 反而会让每次调用都要多传一串参数。
func sqlInList(values []string) string {
	quoted := make([]string, 0, len(values))
	for _, v := range values {
		quoted = append(quoted, "'"+v+"'")
	}
	return strings.Join(quoted, ", ")
}

// sqlProactiveRecover 回收过期租约，按"投递是否可能已经发生"分成三支：
//
//   - exhausted：已达重试上限 → 落 expired 终态（不再无限重试，也不再占额度）；
//   - unknown   ：可能已经发出去过 → **只延长租约**，绝不放回队列（放回就等于重发）；
//   - 其余      ：确定还没发出 → 放回待领取，并回退它占用的预算预留。
var sqlProactiveRecover = fmt.Sprintf(`WITH expired AS (
		SELECT id, user_id, attempt_count, delivery_status, budget_win_start, budget_reserved
		FROM proactive_message
		WHERE state = 'pending'
		  AND claim_token <> ''
		  AND lease_expires_at IS NOT NULL
		  AND lease_expires_at <= $1
		ORDER BY lease_expires_at ASC
		LIMIT $2
		FOR UPDATE SKIP LOCKED
	),
	fresh AS (
		SELECT id, user_id, attempt_count, delivery_status, budget_win_start, budget_reserved,
		       (delivery_status IN (%s)) AS unknown,
		       (attempt_count >= $4) AS exhausted
		FROM expired
	),
	-- 结果不明：把交付确定性**升级**成 attempted_unknown 并延长租约。
	-- 升级是必要的：'sending' 只是"调用已发起"的瞬时标记，进程已经崩了，
	-- 留着它会让后续每一次判定都要重新推断"这到底是发没发"，而这些行永远不会有人来结算。
	-- 同时记下 delivery_unknown_at，让"哪些行需要人工/对账处理"可查询。
	rewritten AS (
		UPDATE proactive_message m
		SET lease_expires_at = $3,
		    delivery_status = 'attempted_unknown',
		    delivery_unknown_at = COALESCE(m.delivery_unknown_at, $1),
		    suppress_reason = 'lease_recovered',
		    updated_at = $1
		FROM fresh f
		WHERE m.id = f.id AND f.unknown AND NOT f.exhausted
		RETURNING m.user_id, m.budget_reserved, m.budget_win_start
	),
	expired_out AS (
		UPDATE proactive_message m
		SET state = 'expired',
		    suppress_reason = 'attempts_exhausted',
		    claim_token = '',
		    claimed_by = '',
		    lease_expires_at = NULL,
		    budget_reserved = false,
		    updated_at = $1
		FROM fresh f
		WHERE m.id = f.id AND f.exhausted
		RETURNING m.user_id
	),
	requeued_out AS (
		UPDATE proactive_message m
		SET claim_token = '',
		    claimed_by = '',
		    lease_expires_at = NULL,
		    budget_reserved = false,
		    delivery_status = 'not_attempted',
		    suppress_reason = 'lease_recovered',
		    updated_at = $1
		FROM fresh f
		WHERE m.id = f.id AND NOT f.unknown AND NOT f.exhausted
		RETURNING m.user_id
	),
	budget_give_back AS (
		UPDATE proactive_budget_window w
		SET reserved = GREATEST(w.reserved - 1, 0), updated_at = $1
		WHERE w.user_id IN (SELECT user_id FROM requeued_out)
		  AND w.win_start IN (
		        SELECT f.budget_win_start FROM fresh f
		        WHERE f.budget_win_start IS NOT NULL
		          AND NOT f.unknown AND NOT f.exhausted)
		RETURNING w.user_id
	)
	SELECT (SELECT COUNT(*) FROM requeued_out) AS requeued,
	       (SELECT COUNT(*) FROM expired_out) AS expired,
	       (SELECT COUNT(*) FROM rewritten) AS extended`, sqlInList(proactiveDeliveryUncertain))

// proactiveStatements 是主动消息域 SQL 的登记清单，供租户隔离断言使用。
var proactiveStatements = []Statement{
	{"proactive.insert", sqlProactiveInsert, true},
	{"proactive.claim_candidates", sqlProactiveClaimCandidates, true},
	{"proactive.budget_window", sqlProactiveBudgetWindow, true},
	{"proactive.budget_reserve", sqlProactiveBudgetReserve, true},
	{"proactive.claim", sqlProactiveClaim, true},
	{"proactive.settle", sqlProactiveSettle, true},
	{"proactive.renew_lease", sqlProactiveRenewLease, true},
	{"proactive.begin_delivery", sqlProactiveBeginDelivery, true},
	{"proactive.recover", sqlProactiveRecover, true},
	{"proactive.history", sqlProactiveHistory, true},
	{"proactive.assign_device", sqlProactiveAssignDevice, true},
	{"proactive.cancel_for_device", sqlProactiveCancelForDevice, true},
	{"device.invalidate", sqlDeviceInvalidate, true},
	// 时区读写以 app_user.id 为主键（id 就是 userID，没有独立的 user_id 列），
	// 与 postgres.go 里的账号域语句一样属于系统级查询。
	{"user.timezone_get", sqlUserTimeZone, false},
	{"user.timezone_set", sqlUserSetTimeZone, false},
}

// init 把本文件的语句并入统一清单。
//
// 用 init 而不是去改 postgres.go 的切片字面量：主动消息域的 SQL 与实现放在同一个文件，
// 迁移、排障、回归三处只需看这一份。
func init() {
	sqlStatements = append(sqlStatements, proactiveStatements...)
}

// ---------- 扫描辅助 ----------

// scanProactiveClaim 扫描领取查询的一行。data_json 是 JSONB，扫描进 []byte 后再解析。
func scanProactiveClaim(s rowScanner) (ProactiveClaim, error) {
	var (
		c         ProactiveClaim
		raw       []byte
		expiresAt sql.NullTime
		claimedAt sql.NullTime
		claimedBy string
		token     string
		lease     time.Time
		delivery  string
	)
	if err := s.Scan(&c.ID, &c.UserID, &c.Kind, &c.DedupeKey, &c.TargetRef, &c.DeviceID,
		&c.Title, &c.Body, &c.DeepLink, &raw, &c.ScheduledAt, &expiresAt,
		&claimedAt, &c.AttemptCount, &token, &claimedBy, &lease, &c.DeliveryID); err != nil {
		return ProactiveClaim{}, err
	}
	data, err := unmarshalProactiveData(raw)
	if err != nil {
		return ProactiveClaim{}, err
	}
	c.Data = data
	if expiresAt.Valid {
		t := expiresAt.Time
		c.ExpiresAt = &t
	}
	if claimedAt.Valid {
		c.ClaimedAt = claimedAt.Time
	}
	c.ClaimToken = token
	c.ClaimedBy = claimedBy
	c.LeaseExpiresAt = lease
	c.DeliveryStatus = delivery
	return c, nil
}

// ---------- 入队 ----------

// EnqueueProactive 幂等入队。
//
// 返回 nil 有两种情形：真的插入了，或者同 (user_id, dedupe_key) 已存在被 DO NOTHING 忽略。
// 去重键命中本来就是设计中的正常路径，不该当成错误让生产者重试。
func (p *Postgres) EnqueueProactive(ctx context.Context, m ProactiveMessage) error {
	if err := validateEnqueue(m); err != nil {
		return err
	}
	state := m.State
	if state == "" {
		state = ProactiveStatePending
	}
	if err := validateProactiveState(state); err != nil {
		return err
	}
	data, err := marshalProactiveData(m.Data)
	if err != nil {
		return err
	}
	createdAt := m.CreatedAt
	if createdAt.IsZero() {
		createdAt = p.now()
	}
	updatedAt := m.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = createdAt
	}
	var deliveredAt, expiresAt, claimedAt, leaseExpiresAt, deliveryUnknownAt, budgetWinStart any
	if m.DeliveredAt != nil {
		deliveredAt = m.DeliveredAt.UTC()
	}
	if m.ExpiresAt != nil {
		expiresAt = m.ExpiresAt.UTC()
	}
	if m.ClaimedAt != nil {
		claimedAt = m.ClaimedAt.UTC()
	}
	if m.LeaseExpiresAt != nil {
		leaseExpiresAt = m.LeaseExpiresAt.UTC()
	}
	if m.DeliveryUnknownAt != nil {
		deliveryUnknownAt = m.DeliveryUnknownAt.UTC()
	}
	if m.BudgetWinStart != nil {
		budgetWinStart = m.BudgetWinStart.UTC()
	}
	deliveryStatus := m.DeliveryStatus
	if deliveryStatus == "" {
		deliveryStatus = ProactiveDeliveryNotAttempted
	}
	if err := validateDeliveryStatus(deliveryStatus); err != nil {
		return err
	}
	if _, err := p.db.ExecContext(ctx, sqlProactiveInsert,
		m.ID, m.UserID, m.Kind, m.DedupeKey, m.TargetRef, m.DeviceID, state, m.SuppressReason,
		m.Title, m.Body, m.DeepLink, data, m.ScheduledAt.UTC(),
		deliveredAt, expiresAt, claimedAt,
		m.ClaimedBy, m.ClaimToken, leaseExpiresAt, m.AttemptCount, m.DeliveryID, deliveryStatus,
		deliveryUnknownAt, budgetWinStart, m.BudgetWinStart != nil,
		createdAt.UTC(), updatedAt.UTC()); err != nil {
		return fmt.Errorf("store: 入队主动消息失败: %w", err)
	}
	return nil
}

// ---------- 领取 ----------

// errProactiveWindowRace 标记"新预算窗口被并发创建"这一种可重试竞态。
//
// 唯一会撞这里的是：两个事务同时发现没有窗口，同时插入，后到的那个唯一键冲突。
// 它是一次性的竞态，不是故障——重跑一次就能看到对方建好的窗口。
var errProactiveWindowRace = errors.New("store: 预算窗口并发创建冲突")

// ClaimDueProactive 领取到期行，按用户当日限额原子预留额度。
//
// 重试只针对"预算窗口并发创建"这一种竞态，最多两次；其余错误原样上抛。
func (p *Postgres) ClaimDueProactive(ctx context.Context, req ProactiveClaimRequest) (ProactiveClaimBatch, error) {
	if req.Limit <= 0 {
		return ProactiveClaimBatch{}, nil
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		batch, err := p.claimOnce(ctx, req)
		if err == nil {
			return batch, nil
		}
		if !errors.Is(err, errProactiveWindowRace) {
			return ProactiveClaimBatch{}, err
		}
		lastErr = err
	}
	return ProactiveClaimBatch{}, lastErr
}

func (p *Postgres) claimOnce(ctx context.Context, req ProactiveClaimRequest) (ProactiveClaimBatch, error) {
	at := req.Now.UTC()
	lease := claimLease(req.Lease)
	maxAttempts := claimMaxAttempts(req.MaxAttempts)
	token := newClaimToken()
	deliveryID := newDeliveryID()

	userIDs, err := p.proactiveClaimCandidates(ctx, at, req.Limit, maxAttempts)
	if err != nil {
		return ProactiveClaimBatch{}, err
	}
	var batch ProactiveClaimBatch
	for _, userID := range userIDs {
		limit := DefaultDailyLimit
		if req.DailyLimitFor != nil {
			if v := req.DailyLimitFor(userID); v > 0 {
				limit = v
			}
		}
		claims, over, err := p.claimUser(ctx, userID, at, req.Limit, limit, lease, maxAttempts, req.ClaimedBy, token, deliveryID)
		if err != nil {
			return ProactiveClaimBatch{}, err
		}
		batch.Claims = append(batch.Claims, claims...)
		if over {
			batch.OverBudgetUsers = append(batch.OverBudgetUsers, userID)
		}
	}
	return batch, nil
}

// proactiveClaimCandidates 列出此刻还有可领取行的用户。
func (p *Postgres) proactiveClaimCandidates(ctx context.Context, at time.Time, limit, maxAttempts int) ([]string, error) {
	rows, err := p.db.QueryContext(ctx, sqlProactiveClaimCandidates, at, limit, maxAttempts)
	if err != nil {
		return nil, fmt.Errorf("store: 查询可领取用户失败: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var userID string
		if err := rows.Scan(&userID); err != nil {
			return nil, fmt.Errorf("store: 扫描可领取用户失败: %w", err)
		}
		out = append(out, userID)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历可领取用户失败: %w", err)
	}
	return out, nil
}

// claimUser 领取某个用户的到期行：一个事务里完成"预留额度 + 写租约"。
//
// 逐用户单独开事务的理由：某个用户额度用尽不该把整批其它用户一起回滚；
// 同时把预算行上的持锁时间限制在单个用户的一次领取上，降低死锁概率。
func (p *Postgres) claimUser(
	ctx context.Context, userID string, at time.Time, limit, dailyLimit int,
	lease time.Duration, maxAttempts int, claimedBy, token, deliveryID string,
) ([]ProactiveClaim, bool, error) {
	loc := p.userLocation(ctx, userID)
	winStart, winEnd := localDayBounds(at, loc)

	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, false, fmt.Errorf("store: 领取主动消息开启用户事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	// 第一步：准备并锁定当日预算窗口。持有它的行锁是本协议唯一的跨进程串行点：
	// 另一个调度进程若要给同一个用户领取，会在这里排队，而不是各算各的余额。
	var reservedWinStart time.Time
	err = tx.QueryRowContext(ctx, sqlProactiveBudgetWindow, userID, at, winStart, winEnd).Scan(&reservedWinStart)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// 两个事务同时新建同一窗口时，输的那个会看到 locked_window 与 new_window 都为空。
		// 这不是错误：重试一次就能读到赢家已经提交的窗口。
		return nil, false, errProactiveWindowRace
	case err != nil:
		return nil, false, fmt.Errorf("store: 准备主动消息预算窗口失败: %w", err)
	}

	// 第二步：在已锁定的窗口行上原子累加预留，并取回本次真正允许预留的条数。
	var (
		avail      int
		pending    int
		didReserve bool
	)
	err = tx.QueryRowContext(ctx, sqlProactiveBudgetReserve,
		userID, at, reservedWinStart, dailyLimit, limit, maxAttempts).Scan(&avail, &pending, &didReserve)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// 窗口行在两条语句之间消失（例如运维清理）：重试一次比硬报错更合理。
		return nil, false, errProactiveWindowRace
	case err != nil:
		return nil, false, fmt.Errorf("store: 预留主动消息额度失败: %w", err)
	}

	// 还有到期行却一条额度都没留住，就是"当日额度用尽"。
	// 这与"没有活可干"必须区分开：前者说明限额正在生效，后者只是这一轮没消息。
	overBudget := pending > 0 && avail <= 0
	if !didReserve {
		if err := tx.Commit(); err != nil {
			return nil, false, fmt.Errorf("store: 提交主动消息领取失败: %w", err)
		}
		return nil, overBudget, nil
	}

	// 第三步：在已经预留好的窗口里认领具体行。LIMIT 用已预留的条数，
	// 保证"预留多少就最多认领多少"，不会出现预留 2 条却发出 3 条。
	rows, err := tx.QueryContext(ctx, sqlProactiveClaim,
		userID, at, reservedWinStart,
		claimedBy, token, at.Add(lease), maxAttempts, deliveryID, avail)
	if err != nil {
		return nil, false, fmt.Errorf("store: 领取主动消息失败: %w", err)
	}
	var claims []ProactiveClaim
	for rows.Next() {
		c, err := scanProactiveClaim(rows)
		if err != nil {
			rows.Close()
			return nil, false, fmt.Errorf("store: 扫描领取到的主动消息失败: %w", err)
		}
		claims = append(claims, c)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, false, fmt.Errorf("store: 遍历领取结果失败: %w", err)
	}
	rows.Close()

	// 预留了却没领到行（例如候选行被并发取消）：把多预留的额度退回去。
	// 不退的话，用户当天的额度会被一些永远不会发出的行白占掉。
	if given := avail - len(claims); given > 0 {
		if _, err := tx.ExecContext(ctx, sqlProactiveBudgetRelease,
			userID, reservedWinStart, given, at); err != nil {
			return nil, false, fmt.Errorf("store: 回退多预留的额度失败: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, false, fmt.Errorf("store: 提交主动消息领取失败: %w", err)
	}
	return claims, overBudget, nil
}

// isUniqueViolation 判断错误是否为唯一键冲突（新预算窗口并发创建）。
//
// 刻意按 SQLSTATE 23505 判断，而不是引入驱动私有类型：本包不 import 任何数据库驱动
// （见 postgres.go 的设计取舍），绑上 pgx / lib/pq 的类型会让存储层多一个硬依赖。
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	var coded interface{ SQLState() string }
	if errors.As(err, &coded) {
		return coded.SQLState() == "23505"
	}
	return strings.Contains(err.Error(), "23505")
}

// ---------- 结算 ----------

// SettleProactive 结算一条已领取的行：校验凭证与租约，落状态，回退预留额度。
//
// 为什么把"回退预留"放在同一事务里：预留值与行状态必须一起变。
// 如果先改状态再（异步地）回退，中间崩溃就会让当日额度被永久占掉一格，
// 用户会莫名其妙地少收到一条提醒，且没有任何日志能解释。
func (p *Postgres) SettleProactive(ctx context.Context, req ProactiveSettleRequest) error {
	state := req.State
	if state == "" {
		state = proactiveSettlePending
	}
	if state != proactiveSettlePending {
		if err := validateProactiveResult(state, req.DeliveredAt); err != nil {
			return err
		}
	}
	status := req.DeliveryStatus
	if status == "" {
		status = ProactiveDeliveryNotAttempted
	}
	if err := validateDeliveryStatus(status); err != nil {
		return err
	}
	if req.RetryAfter < 0 {
		return errors.New("store: 重试退避不能为负")
	}
	at := req.At.UTC()
	retryAt := at.Add(req.RetryAfter)
	var deliveredAt any
	if req.DeliveredAt != nil {
		deliveredAt = req.DeliveredAt.UTC()
	}

	var changed, tokenMatch, found, leaseExpired int
	if err := p.db.QueryRowContext(ctx, sqlProactiveSettle,
		req.ID, req.Token, req.SuppressReason, state, at, deliveredAt, retryAt, status).
		Scan(&changed, &tokenMatch, &found, &leaseExpired); err != nil {
		return fmt.Errorf("store: 结算主动消息失败: %w", err)
	}
	if changed > 0 {
		return nil
	}
	// 三种被拒的情形分开报：调用方对它们的处置完全不同。
	switch {
	case found == 0:
		return ErrNotFound
	case tokenMatch == 0:
		return fmt.Errorf("%w: id=%s", ErrProactiveClaimMismatch, req.ID)
	case leaseExpired > 0:
		return fmt.Errorf("%w: id=%s", ErrProactiveLeaseExpired, req.ID)
	default:
		return fmt.Errorf("%w: id=%s state=%s", ErrProactiveNotClaimed, req.ID, state)
	}
}

// RenewProactiveLease 续租；返回新的租约截止时刻，方便调用方在日志里断言"我真的还持有它"。
func (p *Postgres) RenewProactiveLease(ctx context.Context, id string, token string, now time.Time, lease time.Duration) (time.Time, error) {
	at := now.UTC()
	deadline := at.Add(claimLease(lease))
	var userID string
	err := p.db.QueryRowContext(ctx, sqlProactiveRenewLease, id, token, at, deadline).Scan(&userID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return time.Time{}, fmt.Errorf("%w: id=%s", ErrProactiveNotClaimed, id)
		}
		return time.Time{}, fmt.Errorf("store: 续租主动消息失败: %w", err)
	}
	return deadline, nil
}

// BeginProactiveDelivery 记录"本次已发起投递"。
//
// 调用方必须在真正调用供应商之前调用它：顺序反了的话，崩在发送调用中间的行
// 会被恢复者当成"还没发过"，于是被重发——用户收到两条同样的提醒。
func (p *Postgres) BeginProactiveDelivery(ctx context.Context, id string, token string, at time.Time) error {
	res, err := p.db.ExecContext(ctx, sqlProactiveBeginDelivery, id, token, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 记录发起投递失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取发起投递结果失败: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("%w: id=%s", ErrProactiveNotClaimed, id)
	}
	return nil
}

// ---------- 租约回收 ----------

// RecoverExpiredProactive 回收过期租约。
//
// 三类处理（见 0003 迁移的边界说明）：
//   - 未发起投递 → 放回待领取，安全重发，并回退预留额度；
//   - 已发起投递、结果不明 → 只延长租约，**不重发**（宁可不发也不重复打扰）；
//   - 已达重试上限 → 落 expired 终态，让"可能失败"收敛成一个明确结论。
func (p *Postgres) RecoverExpiredProactive(ctx context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int) (ProactiveRecoverResult, error) {
	if limit <= 0 {
		return ProactiveRecoverResult{}, nil
	}
	at := now.UTC()
	var out ProactiveRecoverResult
	if err := p.db.QueryRowContext(ctx, sqlProactiveRecover,
		at, limit, at.Add(claimLease(lease)), claimMaxAttempts(maxAttempts)).
		Scan(&out.Requeued, &out.Expired, &out.Extended); err != nil {
		return ProactiveRecoverResult{}, fmt.Errorf("store: 回收过期租约失败: %w", err)
	}
	return out, nil
}

// ---------- 判定事实 ----------

// ProactiveHistory 汇总判定事实。当日边界按用户时区的自然日计算，
// 预算预留从当日窗口读，因此用户改时区不会让它漂移。
func (p *Postgres) ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (ProactiveHistoryFacts, error) {
	start, end := localDayBounds(now, loc)
	var (
		delivered int
		claimed   int
		unknown   int
		lastKey   sql.NullTime
		lastKind  sql.NullTime
		sameKey   sql.NullBool
		reserved  int
	)
	if err := p.db.QueryRowContext(ctx, sqlProactiveHistory,
		userID, start, end, dedupeKey, now.UTC(), kind).
		Scan(&delivered, &claimed, &unknown, &lastKey, &lastKind, &sameKey, &reserved); err != nil {
		return ProactiveHistoryFacts{}, fmt.Errorf("store: 查询主动消息历史失败: %w", err)
	}
	facts := ProactiveHistoryFacts{
		DeliveredToday:        delivered,
		ClaimedToday:          claimed,
		UnknownToday:          unknown,
		ReservedToday:         reserved,
		SameKeyDeliveredToday: sameKey.Valid && sameKey.Bool,
	}
	if lastKey.Valid {
		facts.LastDeliveredSameKey = lastKey.Time
	}
	if lastKind.Valid {
		facts.LastDeliveredSameKind = lastKind.Time
	}
	return facts, nil
}

// ---------- 用户时区 ----------

// userLocation 是给内部调用用的"拿时区"：读失败时回退 UTC，不中断调度。
//
// 与 UserLocation 的区别：UserLocation 把错误交给调用方（HTTP 层需要知道），
// 而领取/回收路径上"读不到时区"不该让整轮调度失败——按 UTC 算一个确定的"今天"
// 远好过整轮不发。
func (p *Postgres) userLocation(ctx context.Context, userID string) *time.Location {
	loc, err := p.UserLocation(ctx, userID)
	if err != nil {
		return time.UTC
	}
	return loc
}

// userTimeZone 读取库里原样的时区名（可能为空串表示未知）。
func (p *Postgres) userTimeZone(ctx context.Context, userID string) (string, error) {
	var tz string
	err := p.db.QueryRowContext(ctx, sqlUserTimeZone, userID).Scan(&tz)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", fmt.Errorf("store: 读取用户时区失败: %w", err)
	}
	return tz, nil
}

// UserLocation 返回用户时区；库中为空或无法识别时回退 UTC。
//
// 回退 UTC 而不是报错：老账号与从未上报过时区的客户端都拿不到名字，
// 而"未知"必须有一个确定的解释。用服务器本地时区是更糟的选择——
// 同一份数据在不同机房会算出不同的"今天"。
func (p *Postgres) UserLocation(ctx context.Context, userID string) (*time.Location, error) {
	var tz string
	err := p.db.QueryRowContext(ctx, sqlUserTimeZone, userID).Scan(&tz)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// 账号不存在时也回退 UTC：调用方多半只是拿一个"默认时区"，没有理由因此失败。
		return time.UTC, nil
	case err != nil:
		return nil, fmt.Errorf("store: 读取用户时区失败: %w", err)
	}
	return resolveTimeZone(tz), nil
}

// setUserTimeZone 写入用户 IANA 时区名；空串表示清空为"未知"（读时回退 UTC）。
func (p *Postgres) setUserTimeZone(ctx context.Context, userID string, tz string, at time.Time) error {
	normalized, err := normalizeTimeZone(tz)
	if err != nil {
		return err
	}
	var id string
	err = p.db.QueryRowContext(ctx, sqlUserSetTimeZone, userID, normalized, at.UTC()).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return fmt.Errorf("store: 写入用户时区失败: %w", err)
	}
	return nil
}

// ---------- 设备 ----------

// MarkDeviceInvalid 停用令牌失效的设备（清空 push_token）。设备不存在返回 ErrNotFound。
func (p *Postgres) MarkDeviceInvalid(ctx context.Context, userID string, deviceID string, at time.Time) error {
	res, err := p.db.ExecContext(ctx, sqlDeviceInvalidate, userID, deviceID, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 停用设备失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取停用设备结果失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// CancelPendingForDevice 取消该设备上尚未发出的 pending 行，返回条数。
//
// 会连带回退这些行占用的预算预留：取消意味着额度当天不会再被这条用掉，
// 不回退的话用户当天会白白少收一条提醒。
func (p *Postgres) CancelPendingForDevice(ctx context.Context, userID string, deviceID string, at time.Time) (int, error) {
	var n int
	if err := p.db.QueryRowContext(ctx, sqlProactiveCancelForDevice, userID, deviceID, at.UTC()).Scan(&n); err != nil {
		return 0, fmt.Errorf("store: 取消设备待发主动消息失败: %w", err)
	}
	return n, nil
}

// AssignProactiveDevice 记录一条已领取消息实际路由到哪台设备。
//
// 只允许改 pending 行：落到终态的行再改设备没有意义，而且会把"这条发给谁"的审计线索弄脏。
func (p *Postgres) AssignProactiveDevice(ctx context.Context, id string, deviceID string, at time.Time) error {
	res, err := p.db.ExecContext(ctx, sqlProactiveAssignDevice, id, deviceID, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 记录主动消息目标设备失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取记录目标设备结果失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetUserTimeZone 实现 UserStore：委托给主动消息域的实现（同一列 app_user.timezone）。
//
// 放在这里而不是再写一份 SQL：时区的校验与回退语义只有一处定义，
// 两个域各写一遍迟早会不一致（一处接受 "UTC+8"，另一处拒绝）。
func (p *Postgres) SetUserTimeZone(ctx context.Context, userID string, tz string, at time.Time) error {
	return p.setUserTimeZone(ctx, userID, tz, at)
}

// UserTimeZone 返回用户时区名（原样，可能为空串表示未知）。
func (p *Postgres) UserTimeZone(ctx context.Context, userID string) (string, error) {
	return p.userTimeZone(ctx, userID)
}
