package store

import (
	"context"
	"errors"
	"sort"
	"sync"
	"testing"
	"time"
)

// 本文件只做**不依赖真实数据库**的契约与纯函数回归。
// 事务、FOR UPDATE SKIP LOCKED 的并发语义、JSONB 编解码等真实行为，
// 由 postgres_proactive_integration_test.go（//go:build postgres）在真实库上验证。

func TestLocalDayBoundsUsesUserTimeZone(t *testing.T) {
	sh, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	// 北京时间 2026-10-13 00:30 属于 10-13 这一天，而不是服务器 UTC 的 10-12。
	now := time.Date(2026, 10, 12, 16, 30, 0, 0, time.UTC)
	start, end := localDayBounds(now, sh)
	wantStart := time.Date(2026, 10, 12, 16, 0, 0, 0, time.UTC)
	if !start.Equal(wantStart) {
		t.Fatalf("当日起点应为北京 10-13 00:00（UTC %s），实际 %s", wantStart, start)
	}
	if end.Sub(start) < 23*time.Hour || end.Sub(start) > 25*time.Hour {
		t.Fatalf("一日区间应约 24 小时，实际 %s", end.Sub(start))
	}
	if loc := start.Location(); loc != time.UTC {
		t.Fatalf("边界应统一为 UTC，实际 %s", loc)
	}
}

func TestValidateProactiveResultRejectsFakeDelivery(t *testing.T) {
	at := time.Now()
	// 只有 delivered 才允许带发出时间：其它状态写发出时间就是虚报送达。
	if err := validateProactiveResult(ProactiveStateDelivered, &at); err != nil {
		t.Fatalf("delivered + 发出时间应通过: %v", err)
	}
	if err := validateProactiveResult(ProactiveStateSuppressed, &at); !errors.Is(err, ErrProactiveDeliveredAt) {
		t.Fatalf("suppressed + 发出时间必须被拒绝，实际: %v", err)
	}
	if err := validateProactiveResult(ProactiveStatePending, nil); err != nil {
		t.Fatalf("pending 不带发出时间应通过: %v", err)
	}
	if err := validateProactiveResult("claimed", nil); !errors.Is(err, ErrProactiveState) {
		t.Fatalf("未知状态必须被拒绝，实际: %v", err)
	}
}

func TestMarshalUnmarshalProactiveData(t *testing.T) {
	raw, err := marshalProactiveData(nil)
	if err != nil || raw != "{}" {
		t.Fatalf("空附加字段应序列化为 {}，实得 %q err=%v", raw, err)
	}
	raw, err = marshalProactiveData(map[string]string{"kind": "geo"})
	if err != nil {
		t.Fatalf("序列化失败: %v", err)
	}
	back, err := unmarshalProactiveData([]byte(raw))
	if err != nil || back["kind"] != "geo" {
		t.Fatalf("反序列化应还原字段，实得 %+v err=%v", back, err)
	}
	back, err = unmarshalProactiveData(nil)
	if err != nil || back == nil {
		t.Fatalf("空值应返回非 nil 空 map，实得 %+v err=%v", back, err)
	}
	if _, err := unmarshalProactiveData([]byte("{")); err == nil {
		t.Fatal("非法 JSON 必须报错")
	}
}

func TestValidateEnqueueRequiresIdentityFields(t *testing.T) {
	ok := ProactiveMessage{ID: "m1", UserID: "u1", Kind: "geo", DedupeKey: "k1", ScheduledAt: time.Now()}
	if err := validateEnqueue(ok); err != nil {
		t.Fatalf("完整消息不应报错: %v", err)
	}
	bad := ok
	bad.DedupeKey = ""
	if err := validateEnqueue(bad); err == nil {
		t.Fatal("缺少去重键必须报错，否则唯一约束会拒两次入队")
	}
	bad = ok
	bad.ScheduledAt = time.Time{}
	if err := validateEnqueue(bad); err == nil {
		t.Fatal("缺少 scheduled_at 必须报错，否则会写入 year 1")
	}
}

// ---------- 接口契约（内存替身） ----------

// memProactive 是 ProactiveStore 的内存替身，只用于在没有数据库时回归接口契约。
// 它不是生产实现；真实并发语义由 postgres 集成测试证明。
type memProactive struct {
	mu          sync.Mutex
	rows        map[string]*ProactiveMessage
	order       []string
	invalidated map[string]bool
}

func newMemProactive() *memProactive {
	return &memProactive{rows: map[string]*ProactiveMessage{}, invalidated: map[string]bool{}}
}

func keyOf(m ProactiveMessage) string { return m.UserID + "\x00" + m.DedupeKey }

func (m *memProactive) EnqueueProactive(_ context.Context, msg ProactiveMessage) error {
	if err := validateEnqueue(msg); err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if msg.State == "" {
		msg.State = ProactiveStatePending
	}
	if err := validateProactiveState(msg.State); err != nil {
		return err
	}
	for _, id := range m.order {
		row := m.rows[id]
		if keyOf(*row) == keyOf(msg) {
			return nil
		}
	}
	cp := msg
	m.rows[cp.ID] = &cp
	m.order = append(m.order, cp.ID)
	return nil
}

func (m *memProactive) ClaimDueProactive(_ context.Context, now time.Time, limit int) ([]ProactiveClaim, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var due []*ProactiveMessage
	for _, id := range m.order {
		row := m.rows[id]
		if row.State == ProactiveStatePending && row.ClaimedAt == nil && !row.ScheduledAt.After(now) {
			due = append(due, row)
		}
	}
	sort.SliceStable(due, func(i, j int) bool { return due[i].ScheduledAt.Before(due[j].ScheduledAt) })
	if limit > 0 && len(due) > limit {
		due = due[:limit]
	}
	claims := make([]ProactiveClaim, 0, len(due))
	for _, row := range due {
		at := now
		row.ClaimedAt = &at
		claims = append(claims, ProactiveClaim{
			ID: row.ID, UserID: row.UserID, Kind: row.Kind, DedupeKey: row.DedupeKey,
			TargetRef: row.TargetRef, DeviceID: row.DeviceID, Title: row.Title, Body: row.Body,
			DeepLink: row.DeepLink, Data: row.Data, ScheduledAt: row.ScheduledAt,
			ExpiresAt: row.ExpiresAt, ClaimedAt: at,
		})
	}
	return claims, nil
}

func (m *memProactive) ReleaseProactive(_ context.Context, id string, reason string, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok || row.State != ProactiveStatePending {
		return ErrNotFound
	}
	row.ClaimedAt = nil
	row.SuppressReason = reason
	return nil
}

func (m *memProactive) MarkProactiveResult(_ context.Context, id string, state string, reason string, deliveredAt *time.Time, _ time.Time) error {
	if err := validateProactiveResult(state, deliveredAt); err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok {
		return ErrNotFound
	}
	row.State = state
	row.SuppressReason = reason
	row.DeliveredAt = deliveredAt
	row.ClaimedAt = nil
	return nil
}

func (m *memProactive) ProactiveHistory(_ context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (ProactiveHistoryFacts, error) {
	start, end := localDayBounds(now, loc)
	m.mu.Lock()
	defer m.mu.Unlock()
	var facts ProactiveHistoryFacts
	for _, id := range m.order {
		row := m.rows[id]
		if row.UserID != userID {
			continue
		}
		if row.DeliveredAt != nil {
			if !row.DeliveredAt.Before(start) && row.DeliveredAt.Before(end) {
				facts.DeliveredToday++
				if row.DedupeKey == dedupeKey {
					facts.SameKeyDeliveredToday = true
				}
			}
			if row.DedupeKey == dedupeKey && row.DeliveredAt.After(facts.LastDeliveredSameKey) {
				facts.LastDeliveredSameKey = *row.DeliveredAt
			}
			if row.Kind == kind && row.DeliveredAt.After(facts.LastDeliveredSameKind) {
				facts.LastDeliveredSameKind = *row.DeliveredAt
			}
		}
		if row.ClaimedAt != nil && !row.ClaimedAt.Before(start) && row.ClaimedAt.Before(end) {
			facts.ClaimedToday++
		}
	}
	return facts, nil
}

func (m *memProactive) MarkDeviceInvalid(_ context.Context, userID, deviceID string, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.invalidated[userID+"|"+deviceID] = true
	return nil
}

func (m *memProactive) CancelPendingForDevice(_ context.Context, userID, deviceID string, _ time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, id := range m.order {
		row := m.rows[id]
		if row.UserID == userID && row.DeviceID == deviceID && row.State == ProactiveStatePending && row.ClaimedAt == nil {
			row.State = ProactiveStateCancelled
			row.SuppressReason = "device_invalid"
			n++
		}
	}
	return n, nil
}

func (m *memProactive) AssignProactiveDevice(_ context.Context, id string, deviceID string, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok {
		return ErrNotFound
	}
	row.DeviceID = deviceID
	return nil
}

func TestProactiveStoreInterfaceContract(t *testing.T) {
	var store ProactiveStore = newMemProactive()
	ctx := context.Background()
	now := time.Now()
	base := ProactiveMessage{
		ID: "m1", UserID: "u1", Kind: "geo", DedupeKey: "k1",
		Title: "该走了", Body: "去图书馆", ScheduledAt: now.Add(-time.Minute),
	}

	// 幂等入队：同一 (user_id, dedupe_key) 第二次不报错也不产生第二行。
	if err := store.EnqueueProactive(ctx, base); err != nil {
		t.Fatalf("首次入队失败: %v", err)
	}
	dup := base
	dup.ID = "m2"
	if err := store.EnqueueProactive(ctx, dup); err != nil {
		t.Fatalf("重复入队不得报错: %v", err)
	}

	// 认领即占用：第二次认领拿不到同一行。
	first, err := store.ClaimDueProactive(ctx, now, 10)
	if err != nil || len(first) != 1 || first[0].ID != "m1" {
		t.Fatalf("首次认领应得到 m1，实际 %+v err=%v", first, err)
	}
	second, err := store.ClaimDueProactive(ctx, now, 10)
	if err != nil {
		t.Fatalf("第二次认领报错: %v", err)
	}
	if len(second) != 0 {
		t.Fatalf("已被占用的行不得再次认领，实际 %+v", second)
	}

	// 释放后可以重新认领；期间原因只作审计。
	if err := store.ReleaseProactive(ctx, "m1", "retryable_failure", now); err != nil {
		t.Fatalf("释放失败: %v", err)
	}
	again, err := store.ClaimDueProactive(ctx, now, 10)
	if err != nil || len(again) != 1 {
		t.Fatalf("释放后应能重新认领，实际 %+v err=%v", again, err)
	}
	if err := store.AssignProactiveDevice(ctx, "m1", "dev-a", now); err != nil {
		t.Fatalf("记录目标设备失败: %v", err)
	}

	// 被抑制绝不能带发出时间。
	if err := store.MarkProactiveResult(ctx, "m1", ProactiveStateSuppressed, "daily_budget", &now, now); !errors.Is(err, ErrProactiveDeliveredAt) {
		t.Fatalf("被抑制写发出时间必须被拒绝，实际: %v", err)
	}
	if err := store.MarkProactiveResult(ctx, "m1", ProactiveStateSuppressed, "daily_budget", nil, now); err != nil {
		t.Fatalf("抑制落库失败: %v", err)
	}

	// delivered 会计入当日统计。
	delivered := base
	delivered.ID = "m3"
	delivered.DedupeKey = "k3"
	delivered.ScheduledAt = now.Add(-time.Minute)
	if err := store.EnqueueProactive(ctx, delivered); err != nil {
		t.Fatalf("入队 m3 失败: %v", err)
	}
	if err := store.MarkProactiveResult(ctx, "m3", ProactiveStateDelivered, "", &now, now); err != nil {
		t.Fatalf("送达落库失败: %v", err)
	}
	facts, err := store.ProactiveHistory(ctx, "u1", "k3", "geo", now, time.UTC)
	if err != nil {
		t.Fatalf("读取判定事实失败: %v", err)
	}
	if facts.DeliveredToday != 1 || !facts.SameKeyDeliveredToday {
		t.Fatalf("当日已发出应为 1 且同键命中，实际 %+v", facts)
	}

	// 设备失效只取消该设备上尚未发出且未被占用的行。
	pending := base
	pending.ID = "m4"
	pending.DedupeKey = "k4"
	pending.DeviceID = "dev-b"
	pending.ScheduledAt = now.Add(time.Minute) // 未到点，不会被认领
	if err := store.EnqueueProactive(ctx, pending); err != nil {
		t.Fatalf("入队 m4 失败: %v", err)
	}
	n, err := store.CancelPendingForDevice(ctx, "u1", "dev-b", now)
	if err != nil || n != 1 {
		t.Fatalf("应取消 1 条 dev-b 的待发行，实际 %d err=%v", n, err)
	}
	if err := store.MarkDeviceInvalid(ctx, "u1", "dev-a", now); err != nil {
		t.Fatalf("停用设备失败: %v", err)
	}
}
