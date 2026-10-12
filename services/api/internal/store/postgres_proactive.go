package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// ---------- 主动消息账本（PostgreSQL 实现） ----------
//
// SQL 集中在这个文件里，并在 init 中登记进统一的语句清单，
// 让 postgres_test.go 的"用户域语句必须带 user_id"断言同样覆盖它们。
// 按主键 id 更新的语句末尾带 RETURNING user_id：id 是全局唯一主键，
// 语义上无需再用 user_id 过滤，但回归清单需要能机械地确认它们确实落在用户域。

const (
	// 入队用 ON CONFLICT DO NOTHING 实现幂等：同一 (user_id, dedupe_key) 重复入队不产生第二行也不报错。
	sqlProactiveInsert = `INSERT INTO proactive_message
	(id, user_id, kind, dedupe_key, target_ref, device_id, state, suppress_reason,
	 title, body, deep_link, data_json, scheduled_at, delivered_at, expires_at, claimed_at, created_at, updated_at)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
	ON CONFLICT (user_id, dedupe_key) DO NOTHING`

	// 认领查询：只取到期且未被占用的 pending 行。FOR UPDATE SKIP LOCKED 让并发事务
	// 直接跳过别人已经锁住的行，而不是排队等锁后再抢同一条消息。
	sqlProactiveClaimSelect = `SELECT id, user_id, kind, dedupe_key, target_ref, device_id, title, body, deep_link, data_json, scheduled_at, expires_at
	FROM proactive_message
	WHERE state = 'pending' AND claimed_at IS NULL AND scheduled_at <= $1
	ORDER BY scheduled_at ASC
	LIMIT $2
	FOR UPDATE SKIP LOCKED`

	// 标记认领：写 claimed_at 并清掉上一次释放留下的原因。
	sqlProactiveClaimMark = `UPDATE proactive_message
	SET claimed_at = $2, suppress_reason = '', updated_at = $2
	WHERE id = $1
	RETURNING user_id`

	// 释放：回到未被占用的 pending；reason 只作审计，不改变可发送性。
	sqlProactiveRelease = `UPDATE proactive_message
	SET claimed_at = NULL, suppress_reason = $2, updated_at = $3
	WHERE id = $1 AND state = 'pending'
	RETURNING user_id`

	// 落终态：一并清掉占用标记。delivered_at 只在 $4 非空时被写入。
	sqlProactiveResult = `UPDATE proactive_message
	SET state = $2, suppress_reason = $3, delivered_at = $4, claimed_at = NULL, updated_at = $5
	WHERE id = $1
	RETURNING user_id`

	// 判定事实：一条语句同时算当日已发出、当日已占用、同键/同类最近发出与同键今日是否已发。
	// COALESCE(BOOL_OR(...), false) 让零行时不会扫出 NULL 布尔值。
	sqlProactiveHistory = `SELECT
	COUNT(*) FILTER (WHERE delivered_at >= $2 AND delivered_at < $3) AS delivered_today,
	COUNT(*) FILTER (WHERE claimed_at >= $2 AND claimed_at < $3) AS claimed_today,
	MAX(delivered_at) FILTER (WHERE dedupe_key = $4) AS last_same_key,
	MAX(delivered_at) FILTER (WHERE kind = $5) AS last_same_kind,
	COALESCE(BOOL_OR(dedupe_key = $4 AND delivered_at >= $2 AND delivered_at < $3), false) AS same_key_today
	FROM proactive_message
	WHERE user_id = $1`

	sqlProactiveAssignDevice = `UPDATE proactive_message
	SET device_id = $2, updated_at = $3
	WHERE id = $1
	RETURNING user_id`

	// 只取消"尚未发出"的行：已认领（claimed_at 非空）的那条由调用方单独落终态，
	// 避免把正在发送中的行也一并抹掉。
	sqlProactiveCancelForDevice = `UPDATE proactive_message
	SET state = 'cancelled', suppress_reason = 'device_invalid', claimed_at = NULL, updated_at = $3
	WHERE user_id = $1 AND device_id = $2 AND state = 'pending' AND claimed_at IS NULL
	RETURNING user_id`

	// 停用设备：清空令牌而不是删行，用户重新登记同一台设备时能覆盖回来。
	sqlDeviceInvalidate = `UPDATE device
	SET push_token = '', updated_at = $3
	WHERE user_id = $1 AND id = $2
	RETURNING user_id`
)

// proactiveStatements 是主动消息域 SQL 的登记清单，供租户隔离断言使用。
var proactiveStatements = []Statement{
	{"proactive.insert", sqlProactiveInsert, true},
	{"proactive.claim_select", sqlProactiveClaimSelect, true},
	{"proactive.claim_mark", sqlProactiveClaimMark, true},
	{"proactive.release", sqlProactiveRelease, true},
	{"proactive.result", sqlProactiveResult, true},
	{"proactive.history", sqlProactiveHistory, true},
	{"proactive.assign_device", sqlProactiveAssignDevice, true},
	{"proactive.cancel_for_device", sqlProactiveCancelForDevice, true},
	{"device.invalidate", sqlDeviceInvalidate, true},
}

// init 把本文件的语句并入统一清单。
//
// 用 init 而不是去改 postgres.go 的切片字面量：主动消息域的 SQL 与实现放在同一个文件，
// 迁移、排障、回归三处只需看这一份。
func init() {
	sqlStatements = append(sqlStatements, proactiveStatements...)
}

// scanProactiveClaim 扫描一行到期消息。data_json 是 JSONB，扫描进 []byte 后再解析。
func scanProactiveClaim(s rowScanner) (ProactiveClaim, error) {
	var (
		c         ProactiveClaim
		raw       []byte
		expiresAt sql.NullTime
	)
	if err := s.Scan(&c.ID, &c.UserID, &c.Kind, &c.DedupeKey, &c.TargetRef, &c.DeviceID,
		&c.Title, &c.Body, &c.DeepLink, &raw, &c.ScheduledAt, &expiresAt); err != nil {
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
	return c, nil
}

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
	var deliveredAt, expiresAt, claimedAt any
	if m.DeliveredAt != nil {
		deliveredAt = m.DeliveredAt.UTC()
	}
	if m.ExpiresAt != nil {
		expiresAt = m.ExpiresAt.UTC()
	}
	if m.ClaimedAt != nil {
		claimedAt = m.ClaimedAt.UTC()
	}
	if _, err := p.db.ExecContext(ctx, sqlProactiveInsert,
		m.ID, m.UserID, m.Kind, m.DedupeKey, m.TargetRef, m.DeviceID, state, m.SuppressReason,
		m.Title, m.Body, m.DeepLink, data, m.ScheduledAt.UTC(),
		deliveredAt, expiresAt, claimedAt, createdAt.UTC(), updatedAt.UTC()); err != nil {
		return fmt.Errorf("store: 入队主动消息失败: %w", err)
	}
	return nil
}

// ClaimDueProactive 在一笔事务里完成"取到期行 -> 占用 -> 标记已认领"。
//
// 为什么必须在一个事务里：SELECT ... FOR UPDATE SKIP LOCKED 只锁住行，若事务外再标记，
// 两个并发循环都可能在各自事务里选中同一行（一个先提交前另一个已读完），
// 事务内 SELECT 后立即 UPDATE 才能保证"看见即占用"。
func (p *Postgres) ClaimDueProactive(ctx context.Context, now time.Time, limit int) ([]ProactiveClaim, error) {
	if limit <= 0 {
		return nil, nil
	}
	at := now.UTC()
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("store: 认领主动消息开启事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	rows, err := tx.QueryContext(ctx, sqlProactiveClaimSelect, at, limit)
	if err != nil {
		return nil, fmt.Errorf("store: 查询到期主动消息失败: %w", err)
	}
	var claims []ProactiveClaim
	for rows.Next() {
		c, err := scanProactiveClaim(rows)
		if err != nil {
			rows.Close()
			return nil, fmt.Errorf("store: 扫描到期主动消息失败: %w", err)
		}
		claims = append(claims, c)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("store: 遍历到期主动消息失败: %w", err)
	}
	rows.Close()
	if len(claims) == 0 {
		return nil, nil
	}

	for i := range claims {
		if _, err := tx.ExecContext(ctx, sqlProactiveClaimMark, claims[i].ID, at); err != nil {
			return nil, fmt.Errorf("store: 标记主动消息已认领失败: %w", err)
		}
		claims[i].ClaimedAt = at
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("store: 提交主动消息认领失败: %w", err)
	}
	return claims, nil
}

// ReleaseProactive 释放占用但保留 pending。行已不在 pending（例如已被别的路径落终态）时返回 ErrNotFound。
func (p *Postgres) ReleaseProactive(ctx context.Context, id string, reason string, at time.Time) error {
	res, err := p.db.ExecContext(ctx, sqlProactiveRelease, id, reason, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 释放主动消息占用失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取释放结果失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// MarkProactiveResult 落终态并清掉占用。
func (p *Postgres) MarkProactiveResult(ctx context.Context, id string, state string, suppressReason string, deliveredAt *time.Time, at time.Time) error {
	if err := validateProactiveResult(state, deliveredAt); err != nil {
		return err
	}
	var delivered any
	if deliveredAt != nil {
		delivered = deliveredAt.UTC()
	}
	res, err := p.db.ExecContext(ctx, sqlProactiveResult, id, state, suppressReason, delivered, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 写入主动消息结果失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取主动消息结果写入状态失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ProactiveHistory 汇总判定事实。当日边界按用户时区的自然日计算。
func (p *Postgres) ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (ProactiveHistoryFacts, error) {
	start, end := localDayBounds(now, loc)
	var (
		delivered int
		claimed   int
		lastKey   sql.NullTime
		lastKind  sql.NullTime
		sameKey   sql.NullBool
	)
	if err := p.db.QueryRowContext(ctx, sqlProactiveHistory, userID, start, end, dedupeKey, kind).
		Scan(&delivered, &claimed, &lastKey, &lastKind, &sameKey); err != nil {
		return ProactiveHistoryFacts{}, fmt.Errorf("store: 查询主动消息历史失败: %w", err)
	}
	facts := ProactiveHistoryFacts{
		DeliveredToday:        delivered,
		ClaimedToday:          claimed,
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
func (p *Postgres) CancelPendingForDevice(ctx context.Context, userID string, deviceID string, at time.Time) (int, error) {
	res, err := p.db.ExecContext(ctx, sqlProactiveCancelForDevice, userID, deviceID, at.UTC())
	if err != nil {
		return 0, fmt.Errorf("store: 取消设备待发主动消息失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("store: 读取取消结果失败: %w", err)
	}
	return int(n), nil
}

// AssignProactiveDevice 记录一条已认领消息实际路由到哪台设备。
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
