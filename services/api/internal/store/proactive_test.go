package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
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
//
// 它刻意把领取协议也实现出来（租约、凭证、按用户限额窗口），而不是"记个 claimed 标记"：
// 契约测试要能验证「旧执行者的回执被拒」「额度用尽不再领取」这类语义，
// 若替身比真实实现宽松，测试会绿得毫无意义。真实并发语义仍由 postgres 集成测试证明。
type memProactive struct {
	mu          sync.Mutex
	rows        map[string]*ProactiveMessage
	order       []string
	invalidated map[string]bool
	windows     map[string]*memBudgetWindow
	timezones   map[string]string
}

// memBudgetWindow 对应 PostgreSQL 的 proactive_budget_window。
type memBudgetWindow struct {
	start     time.Time
	end       time.Time
	reserved  int
	delivered int
}

func newMemProactive() *memProactive {
	return &memProactive{
		rows:        map[string]*ProactiveMessage{},
		invalidated: map[string]bool{},
		windows:     map[string]*memBudgetWindow{},
		timezones:   map[string]string{},
	}
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
	if msg.DeliveryStatus == "" {
		msg.DeliveryStatus = ProactiveDeliveryNotAttempted
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

// windowFor 找出或创建 now 对应的预算窗口。
//
// 与真实实现一致地用**相交**判定复用已有窗口：
// 用户改时区后若仍落在原窗口内，就继续消耗同一份额度，而不是拿到一份新的。
func (m *memProactive) windowFor(userID string, now time.Time, loc *time.Location) *memBudgetWindow {
	for key, w := range m.windows {
		if !strings.HasPrefix(key, userID+"\x00") {
			continue
		}
		if !now.Before(w.start) && now.Before(w.end) {
			return w
		}
	}
	start, end := localDayBounds(now, loc)
	w := &memBudgetWindow{start: start, end: end}
	m.windows[userID+"\x00"+start.Format(time.RFC3339Nano)] = w
	return w
}

// windowByStart 按绝对起点找窗口，释放/结算时用它精确回退预留。
//
// 不用 claimed_at 现算：用户改时区后现算会落到另一个窗口，导致预留值永久泄漏。
func (m *memProactive) windowByStart(userID string, at time.Time) *memBudgetWindow {
	for key, w := range m.windows {
		if !strings.HasPrefix(key, userID+"\x00") {
			continue
		}
		if w.start.Equal(at) {
			return w
		}
	}
	return nil
}

// claimableRows 过滤掉已达重试上限的行（它们等 Recover 落终态，不该再占名额）。
func claimableRows(rows []*ProactiveMessage, maxAttempts int) []*ProactiveMessage {
	out := make([]*ProactiveMessage, 0, len(rows))
	for _, row := range rows {
		if row.AttemptCount >= maxAttempts {
			continue
		}
		out = append(out, row)
	}
	return out
}

func (m *memProactive) ClaimDueProactive(_ context.Context, req ProactiveClaimRequest) (ProactiveClaimBatch, error) {
	if req.Limit <= 0 {
		return ProactiveClaimBatch{}, nil
	}
	now := req.Now
	lease := claimLease(req.Lease)
	maxAttempts := claimMaxAttempts(req.MaxAttempts)
	m.mu.Lock()
	defer m.mu.Unlock()

	var due []*ProactiveMessage
	for _, id := range m.order {
		row := m.rows[id]
		if row.State != ProactiveStatePending || row.ScheduledAt.After(now) {
			continue
		}
		if row.DeliveryStatus == ProactiveDeliveryUnknown {
			continue
		}
		if row.ClaimToken != "" && row.LeaseExpiresAt != nil && row.LeaseExpiresAt.After(now) {
			continue
		}
		if row.AttemptCount >= maxAttempts {
			continue
		}
		due = append(due, row)
	}
	sort.SliceStable(due, func(i, j int) bool {
		if due[i].ScheduledAt.Equal(due[j].ScheduledAt) {
			return due[i].ID < due[j].ID
		}
		return due[i].ScheduledAt.Before(due[j].ScheduledAt)
	})

	// 按用户分组后逐个按限额预留：与真实实现一样，额度是在"领取"这一步原子扣减的。
	// 分组要覆盖**所有有到期行的用户**，而不只是本次取得到的那些：
	// 否则"还有到期行、但额度已经用完"的用户会既拿不到行、也不出现在 OverBudgetUsers 里，
	// 排障时就无法区分"今天因为额度没发"与"根本没消息"。
	byUser := map[string][]*ProactiveMessage{}
	for _, id := range m.order {
		row := m.rows[id]
		if row.State != ProactiveStatePending || row.ScheduledAt.After(now) {
			continue
		}
		if row.DeliveryStatus == ProactiveDeliveryUnknown {
			continue
		}
		if row.ClaimToken != "" && row.LeaseExpiresAt != nil && row.LeaseExpiresAt.After(now) {
			continue
		}
		byUser[row.UserID] = append(byUser[row.UserID], row)
	}
	users := make([]string, 0, len(byUser))
	for u := range byUser {
		users = append(users, u)
	}
	sort.Strings(users)

	batch := ProactiveClaimBatch{}
	for _, userID := range users {
		limit := DefaultDailyLimit
		if req.DailyLimitFor != nil {
			if v := req.DailyLimitFor(userID); v > 0 {
				limit = v
			}
		}
		var loc *time.Location
		if req.LocationFor != nil {
			loc = req.LocationFor(userID)
		}
		w := m.windowFor(userID, now, loc)
		avail := limit - (w.reserved + w.delivered)
		if avail > req.Limit {
			avail = req.Limit
		}
		claimable := claimableRows(byUser[userID], maxAttempts)
		if avail <= 0 || avail < len(claimable) {
			batch.OverBudgetUsers = append(batch.OverBudgetUsers, userID)
		}
		if avail <= 0 {
			continue
		}
		for _, row := range claimable {
			if avail == 0 {
				break
			}
			avail--
			w.reserved++
			row.ClaimedBy = req.ClaimedBy
			row.ClaimToken = newClaimToken()
			deadline := now.Add(lease)
			row.LeaseExpiresAt = &deadline
			row.AttemptCount++
			row.DeliveryID = newDeliveryID()
			row.DeliveryStatus = ProactiveDeliveryNotAttempted
			row.DeliveryUnknownAt = nil
			winStart := w.start
			row.BudgetWinStart = &winStart
			row.BudgetReserved = true
			if row.ClaimedAt == nil {
				t := now
				row.ClaimedAt = &t
			}
			row.SuppressReason = ""
			batch.Claims = append(batch.Claims, ProactiveClaim{
				ID: row.ID, UserID: row.UserID, Kind: row.Kind, DedupeKey: row.DedupeKey,
				TargetRef: row.TargetRef, DeviceID: row.DeviceID, Title: row.Title, Body: row.Body,
				DeepLink: row.DeepLink, Data: row.Data, ScheduledAt: row.ScheduledAt,
				ExpiresAt: row.ExpiresAt, ClaimedAt: *row.ClaimedAt,
				ClaimToken: row.ClaimToken, ClaimedBy: row.ClaimedBy,
				LeaseExpiresAt: deadline, AttemptCount: row.AttemptCount,
				DeliveryID: row.DeliveryID, DeliveryStatus: row.DeliveryStatus,
			})
		}
	}
	return batch, nil
}

// ReleaseProactive 是 prog 层便捷入口：等价于"重新排队、不清除领取凭证、不落终态"。
//
// 与 SettleProactive 的区别只在调用侧：这里不做凭证校验（供测试直接释放），
// 生产路径上的释放一律走 SettleProactive，好让"旧执行者不得提交"这条规则只有一处实现。
func (m *memProactive) ReleaseProactive(_ context.Context, id string, reason string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok || row.State != ProactiveStatePending {
		return ErrNotFound
	}
	deadline := at.Add(retryBackoff(row.AttemptCount))
	row.LeaseExpiresAt = &deadline
	row.SuppressReason = reason
	return nil
}

func (m *memProactive) SettleProactive(_ context.Context, req ProactiveSettleRequest) error {
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
	at := req.At
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[req.ID]
	if !ok {
		return ErrNotFound
	}
	if row.ClaimToken != req.Token {
		return fmt.Errorf("%w: id=%s", ErrProactiveClaimMismatch, req.ID)
	}
	if row.LeaseExpiresAt != nil && row.LeaseExpiresAt.Before(at) {
		return fmt.Errorf("%w: id=%s", ErrProactiveLeaseExpired, req.ID)
	}
	if row.ClaimToken == "" {
		return fmt.Errorf("%w: id=%s", ErrProactiveNotClaimed, req.ID)
	}

	terminal := state != proactiveSettlePending
	requeue := row.State == ProactiveStatePending &&
		(row.DeliveryStatus == ProactiveDeliveryNotAttempted || row.DeliveryStatus == ProactiveDeliverySending)
	row.State = state
	row.SuppressReason = req.SuppressReason
	row.DeliveredAt = req.DeliveredAt
	if terminal {
		if row.DeliveryStatus == ProactiveDeliverySending {
			row.DeliveryStatus = ProactiveDeliveryUnknown
			t := at
			row.DeliveryUnknownAt = &t
		} else {
			row.DeliveryStatus = status
		}
		if row.BudgetReserved && row.BudgetWinStart != nil {
			if w := m.windowByStart(row.UserID, *row.BudgetWinStart); w != nil {
				if w.reserved > 0 {
					w.reserved--
				}
				if state == ProactiveStateDelivered {
					w.delivered++
				}
			}
		}
		row.BudgetReserved = false
		row.ClaimToken = ""
		row.ClaimedBy = ""
		row.LeaseExpiresAt = nil
	} else if requeue {
		deadline := at.Add(req.RetryAfter)
		row.LeaseExpiresAt = &deadline
		if row.DeliveryStatus == ProactiveDeliveryNotAttempted {
			row.DeliveryStatus = ProactiveDeliveryNotAttempted
		}
	}
	return nil
}

// MarkProactiveResult 是便捷入口：等价于用空凭证结算落终态。
//
// 仅供不关心凭证语义的契约测试使用；生产路径一律走 SettleProactive。
func (m *memProactive) MarkProactiveResult(_ context.Context, id string, state string, reason string, deliveredAt *time.Time, at time.Time) error {
	if err := validateProactiveResult(state, deliveredAt); err != nil {
		return err
	}
	m.mu.Lock()
	row, ok := m.rows[id]
	if !ok {
		m.mu.Unlock()
		return ErrNotFound
	}
	token := row.ClaimToken
	if token == "" {
		// 未持有租约：按"显式落终态"处理，等价于 0002 的 MarkProactiveResult。
		row.State = state
		row.SuppressReason = reason
		row.DeliveredAt = deliveredAt
		row.ClaimedAt = nil
		m.mu.Unlock()
		return nil
	}
	m.mu.Unlock()
	return m.SettleProactive(context.Background(), ProactiveSettleRequest{
		ID: id, Token: token, State: state, SuppressReason: reason,
		DeliveredAt: deliveredAt, DeliveryStatus: ProactiveDeliveryNotAttempted, At: at,
	})
}

func (m *memProactive) RenewProactiveLease(_ context.Context, id string, token string, now time.Time, lease time.Duration) (time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok || row.State != ProactiveStatePending || row.ClaimToken != token ||
		row.LeaseExpiresAt == nil || row.LeaseExpiresAt.Before(now) {
		return time.Time{}, fmt.Errorf("%w: id=%s", ErrProactiveNotClaimed, id)
	}
	deadline := now.Add(claimLease(lease))
	row.LeaseExpiresAt = &deadline
	return deadline, nil
}

func (m *memProactive) BeginProactiveDelivery(_ context.Context, id string, token string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok || row.State != ProactiveStatePending || row.ClaimToken != token ||
		row.LeaseExpiresAt == nil || row.LeaseExpiresAt.Before(at) {
		return fmt.Errorf("%w: id=%s", ErrProactiveNotClaimed, id)
	}
	row.DeliveryStatus = ProactiveDeliverySending
	return nil
}

func (m *memProactive) RecoverExpiredProactive(_ context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int, unknownGrace time.Duration) (ProactiveRecoverResult, error) {
	if limit <= 0 {
		return ProactiveRecoverResult{}, nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	var out ProactiveRecoverResult
	for _, id := range m.order {
		if out.Requeued+out.Expired+out.Extended >= limit {
			break
		}
		row := m.rows[id]
		if row.State != ProactiveStatePending || row.ClaimToken == "" || row.LeaseExpiresAt == nil {
			continue
		}
		if row.LeaseExpiresAt.After(now) {
			continue
		}
		if row.DeliveryStatus == ProactiveDeliverySending {
			// "已发起投递、结果丢失"：升级为结果不明，绝不重新入队。
			row.DeliveryStatus = ProactiveDeliveryUnknown
			t := now
			row.DeliveryUnknownAt = &t
		}
		switch {
		case row.AttemptCount >= claimMaxAttempts(maxAttempts):
			row.State = ProactiveStateExpired
			row.SuppressReason = "attempts_exhausted"
			row.ClaimToken = ""
			row.ClaimedBy = ""
			row.LeaseExpiresAt = nil
			row.BudgetReserved = false
			out.Expired++
		case row.DeliveryStatus == ProactiveDeliveryUnknown &&
			row.DeliveryUnknownAt != nil &&
			!row.DeliveryUnknownAt.Add(claimUnknownGrace(unknownGrace)).After(now):
			// 结果不明已超过解决期限：收敛成终态，但**仍然不重发**。
			// 没有这一支，结果不明的行会因为 attempt_count 不再增长而永远卡在 pending，
			// 每一轮回收都重写一遍却永不收敛。原因与"重试打满"分开记，否则排障时分不清
			// 该去查供应商还是该去查自己的进程。
			row.State = ProactiveStateExpired
			row.SuppressReason = "delivery_unknown_unresolved"
			row.ClaimToken = ""
			row.ClaimedBy = ""
			row.LeaseExpiresAt = nil
			row.BudgetReserved = false
			out.Expired++
		case row.DeliveryStatus == ProactiveDeliveryUnknown:
			// 结果不明且在解决期限内：只延长租约，绝不重新入队。
			deadline := now.Add(claimLease(lease))
			row.LeaseExpiresAt = &deadline
			out.Extended++
		default:
			if row.BudgetReserved && row.BudgetWinStart != nil {
				if w := m.windowByStart(row.UserID, *row.BudgetWinStart); w != nil && w.reserved > 0 {
					w.reserved--
				}
			}
			row.ClaimToken = ""
			row.ClaimedBy = ""
			row.LeaseExpiresAt = nil
			row.BudgetReserved = false
			row.DeliveryStatus = ProactiveDeliveryNotAttempted
			row.SuppressReason = "lease_recovered"
			out.Requeued++
		}
	}
	return out, nil
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
		if row.DeliveryStatus == ProactiveDeliveryUnknown && !row.UpdatedAt.Before(start) && row.UpdatedAt.Before(end) {
			facts.UnknownToday++
		}
	}
	if w := m.windowFor(userID, now, loc); w != nil {
		facts.ReservedToday = w.reserved
	}
	return facts, nil
}

func (m *memProactive) UserLocation(_ context.Context, userID string) (*time.Location, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return resolveTimeZone(m.timezones[userID]), nil
}

func (m *memProactive) SetUserTimeZone(_ context.Context, userID string, tz string, _ time.Time) error {
	normalized, err := normalizeTimeZone(tz)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.timezones == nil {
		m.timezones = map[string]string{}
	}
	m.timezones[userID] = normalized
	return nil
}

func (m *memProactive) MarkDeviceInvalid(_ context.Context, userID, deviceID string, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.invalidated[userID+"|"+deviceID] = true
	return nil
}

func (m *memProactive) CancelPendingForDevice(_ context.Context, userID, deviceID string, at time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, id := range m.order {
		row := m.rows[id]
		if row.UserID != userID || row.DeviceID != deviceID || row.State != ProactiveStatePending {
			continue
		}
		if row.ClaimToken != "" && row.DeliveryStatus != ProactiveDeliveryNotAttempted {
			continue
		}
		if row.BudgetReserved && row.BudgetWinStart != nil {
			if w := m.windowByStart(row.UserID, *row.BudgetWinStart); w != nil && w.reserved > 0 {
				w.reserved--
			}
		}
		row.State = ProactiveStateCancelled
		row.SuppressReason = "device_invalid"
		row.ClaimedAt = nil
		row.ClaimToken = ""
		row.ClaimedBy = ""
		row.LeaseExpiresAt = nil
		row.BudgetReserved = false
		_ = at
		n++
	}
	return n, nil
}

func (m *memProactive) AssignProactiveDevice(_ context.Context, id string, deviceID string, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok || row.State != ProactiveStatePending {
		return ErrNotFound
	}
	row.DeviceID = deviceID
	return nil
}

// ---------- 契约回归 ----------

// unlimitedClaims 让契约测试不受每日限额影响：它关心的是领取/凭证语义，不是预算。
// 预算行为单独由 TestProactiveClaimRespectsUserDailyLimit 覆盖。
func unlimitedClaims(string) int { return 1000 }

// TestProactiveStoreInterfaceContract 回归领取协议的主干：幂等入队、领取即占用、
// 释放后可重新领取、只有 delivered 才允许写发出时间、当日统计与设备取消。
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

	// 领取即占用：第二次领取拿不到同一行。
	first, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(first.Claims) != 1 || first.Claims[0].ID != "m1" {
		t.Fatalf("首次领取应得到 m1，实际 %+v err=%v", first, err)
	}
	job := first.Claims[0]
	if job.ClaimToken == "" || job.DeliveryID == "" || job.LeaseExpiresAt.IsZero() {
		t.Fatalf("领取必须给出凭证、投递标识与租约截止，实际 %+v", job)
	}
	if job.AttemptCount != 1 {
		t.Fatalf("首次领取后 attempt_count 应为 1，实际 %d", job.AttemptCount)
	}
	second, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil {
		t.Fatalf("第二次领取报错: %v", err)
	}
	if len(second.Claims) != 0 {
		t.Fatalf("持有效租约的行不得再次领取，实际 %+v", second.Claims)
	}

	// 旧执行者带上错误凭证提交结果必须被拒：这正是"旧执行者不得提交新租约结果"的落点。
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m1", Token: "ctk_wrong", State: ProactiveStateDelivered, At: now,
		DeliveredAt: &now, DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); !errors.Is(err, ErrProactiveClaimMismatch) {
		t.Fatalf("凭证不符必须返回 ErrProactiveClaimMismatch，实际: %v", err)
	}

	// 释放后租约在退避期内仍然持有，退避过后才能重新领取。
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m1", Token: job.ClaimToken, State: ProactiveStatePending,
		SuppressReason: "not_due_yet", At: now, RetryAfter: 0,
		DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); err != nil {
		t.Fatalf("释放失败: %v", err)
	}
	again, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(again.Claims) != 1 {
		t.Fatalf("释放后应能重新领取，实际 %+v err=%v", again.Claims, err)
	}
	if again.Claims[0].AttemptCount != 2 {
		t.Fatalf("重新领取应累加 attempt_count，实际 %d", again.Claims[0].AttemptCount)
	}
	if again.Claims[0].ClaimToken == job.ClaimToken {
		t.Fatal("重新领取必须换发新凭证，否则旧执行者的凭证会一直有效")
	}
	job = again.Claims[0]
	if err := store.AssignProactiveDevice(ctx, "m1", "dev-a", now); err != nil {
		t.Fatalf("记录目标设备失败: %v", err)
	}

	// 被抑制绝不能带发出时间。
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m1", Token: job.ClaimToken, State: ProactiveStateSuppressed,
		SuppressReason: "daily_budget", DeliveredAt: &now, At: now,
		DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); !errors.Is(err, ErrProactiveDeliveredAt) {
		t.Fatalf("被抑制写发出时间必须被拒绝，实际: %v", err)
	}
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m1", Token: job.ClaimToken, State: ProactiveStateSuppressed,
		SuppressReason: "daily_budget", At: now, DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); err != nil {
		t.Fatalf("抑制落库失败: %v", err)
	}

	// delivered 会计入当日统计：先入队再领取，然后带凭证落 delivered。
	delivered := base
	delivered.ID = "m3"
	delivered.DedupeKey = "k3"
	delivered.ScheduledAt = now.Add(-time.Minute)
	if err := store.EnqueueProactive(ctx, delivered); err != nil {
		t.Fatalf("入队 m3 失败: %v", err)
	}
	got, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(got.Claims) != 1 || got.Claims[0].ID != "m3" {
		t.Fatalf("应领取到 m3，实际 %+v err=%v", got.Claims, err)
	}
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m3", Token: got.Claims[0].ClaimToken, State: ProactiveStateDelivered,
		DeliveredAt: &now, At: now, DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); err != nil {
		t.Fatalf("送达落库失败: %v", err)
	}
	facts, err := store.ProactiveHistory(ctx, "u1", "k3", "geo", now, time.UTC)
	if err != nil {
		t.Fatalf("读取判定事实失败: %v", err)
	}
	if facts.DeliveredToday != 1 || !facts.SameKeyDeliveredToday {
		t.Fatalf("当日已发出应为 1 且同键命中，实际 %+v", facts)
	}
	// reserved 是**在途**预留数，不是"当日已消费"：m1 被抑制后它的预留已经回退，
	// 但 m3 仍在途，所以此刻还剩 1 个预留名额。
	if facts.ReservedToday != 1 {
		t.Fatalf("m3 仍在途时应剩 1 个预留，实际 %d", facts.ReservedToday)
	}

	// 设备失效只取消该设备上尚未发出且未被占用的行。
	pending := base
	pending.ID = "m4"
	pending.DedupeKey = "k4"
	pending.DeviceID = "dev-b"
	pending.ScheduledAt = now.Add(time.Minute) // 未到点，不会被领取
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

// TestProactiveClaimRespectsUserDailyLimit 回归"按用户限额预留"的契约：
//
// 额度用尽的用户一条都领不到，并且会被明确列进 OverBudgetUsers——
// 这与"库里没有到期行"是两件不同的事，混在一起排障时无法判断。
func TestProactiveClaimRespectsUserDailyLimit(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	now := time.Now()
	for _, id := range []string{"b1", "b2", "b3"} {
		if err := store.EnqueueProactive(ctx, ProactiveMessage{
			ID: id, UserID: "u1", Kind: "geo", DedupeKey: id,
			ScheduledAt: now.Add(-time.Minute),
		}); err != nil {
			t.Fatalf("入队 %s 失败: %v", id, err)
		}
	}
	budget := func(string) int { return 2 }
	batch, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: budget,
	})
	if err != nil {
		t.Fatalf("领取失败: %v", err)
	}
	if len(batch.Claims) != 2 {
		t.Fatalf("每日限额 2 应只领到 2 条，实际 %d", len(batch.Claims))
	}
	if len(batch.OverBudgetUsers) != 1 || batch.OverBudgetUsers[0] != "u1" {
		t.Fatalf("额度用尽后该用户应被列入 OverBudgetUsers，实际 %+v", batch.OverBudgetUsers)
	}
	second, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: budget,
	})
	if err != nil {
		t.Fatalf("第二次领取失败: %v", err)
	}
	if len(second.Claims) != 0 {
		t.Fatalf("额度已用尽时不得再领，实际 %+v", second.Claims)
	}

	// 释放掉一条后额度会退回，但当日已预留计数不会凭空变成 0：
	// 预留必须精确回退，否则用户当天会莫名少收一条。
	facts, err := store.ProactiveHistory(ctx, "u1", "", "", now, time.UTC)
	if err != nil {
		t.Fatalf("读取判定事实失败: %v", err)
	}
	if facts.ReservedToday != 2 {
		t.Fatalf("两条在途行应占 2 个预留名额，实际 %d", facts.ReservedToday)
	}
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: batch.Claims[0].ID, Token: batch.Claims[0].ClaimToken, State: ProactiveStatePending,
		SuppressReason: "not_due_yet", At: now, RetryAfter: time.Minute,
		DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); err != nil {
		t.Fatalf("释放失败: %v", err)
	}
	facts, err = store.ProactiveHistory(ctx, "u1", "", "", now, time.UTC)
	if err != nil {
		t.Fatalf("读取判定事实失败: %v", err)
	}
	if facts.ReservedToday != 2 {
		t.Fatalf("重新排队（仍在途）时两条都应继续占预留，实际 %d", facts.ReservedToday)
	}
}

// TestProactiveStaleExecutorRejectedAfterLeaseRecovery 回归最关键的一条安全规则：
//
// 租约被回收并重新领取后，**旧执行者**带着旧凭证回来提交结果必须被拒，
// 否则它会把新租约的结论覆盖掉（例如把一条已经发出去的消息改写成 pending 再发一次）。
func TestProactiveStaleExecutorRejectedAfterLeaseRecovery(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	now := time.Now()
	if err := store.EnqueueProactive(ctx, ProactiveMessage{
		ID: "m1", UserID: "u1", Kind: "geo", DedupeKey: "k1",
		ScheduledAt: now.Add(-time.Minute),
	}); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	first, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 5, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(first.Claims) != 1 {
		t.Fatalf("首次领取失败: %+v err=%v", first.Claims, err)
	}
	stale := first.Claims[0]

	// 让租约过期，然后回收它——回收后凭证会变。
	later := now.Add(2 * time.Minute)
	result, err := store.RecoverExpiredProactive(ctx, later, 10, time.Minute, 4, time.Hour)
	if err != nil {
		t.Fatalf("回收过期租约失败: %v", err)
	}
	if result.Requeued != 1 {
		t.Fatalf("尚未发起投递的过期租约应被放回待领取，实际 %+v", result)
	}
	second, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: later, Limit: 5, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(second.Claims) != 1 {
		t.Fatalf("回收后应能重新领取: %+v err=%v", second.Claims, err)
	}
	if second.Claims[0].ClaimToken == stale.ClaimToken {
		t.Fatal("重新领取必须换发新凭证")
	}

	// 旧执行者提交结果：必须被拒，且不得改动任何状态。
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m1", Token: stale.ClaimToken, State: ProactiveStateDelivered,
		DeliveredAt: &later, At: later, DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); !errors.Is(err, ErrProactiveClaimMismatch) {
		t.Fatalf("旧执行者的回执必须被拒，实际: %v", err)
	}
	if mem.rows["m1"].State != ProactiveStatePending {
		t.Fatalf("被拒的回执不得改动状态，实际 %s", mem.rows["m1"].State)
	}

	// 凭证对但租约过期同样必须被拒：迟到的回执无法归因。
	if err := store.SettleProactive(ctx, ProactiveSettleRequest{
		ID: "m1", Token: second.Claims[0].ClaimToken, State: ProactiveStateDelivered,
		DeliveredAt: &later, At: later.Add(time.Hour), DeliveryStatus: ProactiveDeliveryNotAttempted,
	}); !errors.Is(err, ErrProactiveLeaseExpired) {
		t.Fatalf("过期租约之上的写入必须被拒，实际: %v", err)
	}
}

// TestProactiveUnknownDeliveryIsNotResent 回归"结果不明不得盲目重发"：
//
// 已发起投递但结果不明的行，租约过期后只能延长租约（等待人工/后续确认），
// 绝不能被放回待领取——那等于对一条可能已经被供应商接受的消息再发一次。
func TestProactiveUnknownDeliveryIsNotResent(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	now := time.Now()
	if err := store.EnqueueProactive(ctx, ProactiveMessage{
		ID: "m1", UserID: "u1", Kind: "geo", DedupeKey: "k1",
		ScheduledAt: now.Add(-time.Minute),
	}); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	got, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 5, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(got.Claims) != 1 {
		t.Fatalf("领取失败: %+v err=%v", got.Claims, err)
	}
	job := got.Claims[0]
	if err := store.BeginProactiveDelivery(ctx, job.ID, job.ClaimToken, now); err != nil {
		t.Fatalf("记录发起投递失败: %v", err)
	}
	// 进程在收到回执前"崩溃"：凭证丢失，租约过期。
	later := now.Add(2 * time.Minute)
	result, err := store.RecoverExpiredProactive(ctx, later, 10, time.Minute, 4, time.Hour)
	if err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if result.Extended != 1 || result.Requeued != 0 {
		t.Fatalf("结果不明的行只能延长租约，实际 %+v", result)
	}
	again, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: later.Add(time.Second), Limit: 5, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil {
		t.Fatalf("再领取失败: %v", err)
	}
	if len(again.Claims) != 0 {
		t.Fatalf("结果不明的行不得被重新领取（会重复打扰用户），实际 %+v", again.Claims)
	}
}

// TestProactiveUnknownDeliveryConvergesAfterGrace 回归"结果不明也必须收敛"：
//
// 这条守的是一个很隐蔽的死角：结果不明的行不会被再次领取，attempt_count 因此
// 不再增长，"已达重试上限"对它永远不成立。少了期限，它就会每一轮回收都被重写
// 一遍却永远停在 pending——写放大没有终点，"还有多少行没了结"也永远答不出来。
// 给期限不是改主意要补发：收敛之后仍然必须领不到。
func TestProactiveUnknownDeliveryConvergesAfterGrace(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	now := time.Now()
	if err := store.EnqueueProactive(ctx, ProactiveMessage{
		ID: "m1", UserID: "u1", Kind: "geo", DedupeKey: "k1",
		ScheduledAt: now.Add(-time.Minute),
	}); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	got, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 5, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil || len(got.Claims) != 1 {
		t.Fatalf("领取失败: %+v err=%v", got.Claims, err)
	}
	job := got.Claims[0]
	if err := store.BeginProactiveDelivery(ctx, job.ID, job.ClaimToken, now); err != nil {
		t.Fatalf("记录发起投递失败: %v", err)
	}
	const grace = time.Hour
	// 第一次回收：刚变成结果不明，在期限之内 → 只延长租约。
	first := now.Add(2 * time.Minute)
	res, err := store.RecoverExpiredProactive(ctx, first, 10, time.Minute, 4, grace)
	if err != nil {
		t.Fatalf("首次回收失败: %v", err)
	}
	if res.Extended != 1 || res.Expired != 0 || res.Requeued != 0 {
		t.Fatalf("期限内的结果不明只能延长租约，实际 %+v", res)
	}
	// 第二次回收：已超过期限 → 收敛成终态，且原因必须能区分开。
	beyond := first.Add(2 * grace)
	res, err = store.RecoverExpiredProactive(ctx, beyond, 10, time.Minute, 4, grace)
	if err != nil {
		t.Fatalf("超期回收失败: %v", err)
	}
	if res.Expired != 1 || res.Extended != 0 || res.Requeued != 0 {
		t.Fatalf("超过解决期限的结果不明必须收敛成终态，实际 %+v", res)
	}
	row := mem.rows[job.ID]
	if row.State != ProactiveStateExpired || row.SuppressReason != "delivery_unknown_unresolved" {
		t.Fatalf("终态应为 expired/delivery_unknown_unresolved，实际 %s/%s", row.State, row.SuppressReason)
	}
	// 收敛后仍然领不到：给期限是为了收敛，不是改主意要补发。
	after, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: beyond.Add(time.Second), Limit: 5, Lease: time.Minute, MaxAttempts: 4, DailyLimitFor: unlimitedClaims,
	})
	if err != nil {
		t.Fatalf("收敛后领取报错: %v", err)
	}
	if len(after.Claims) != 0 {
		t.Fatalf("已收敛的结果不明行不得被重新领取，实际 %+v", after.Claims)
	}
	// 再回收一次必须无事可做，否则说明它并没有真的收敛。
	againRes, err := store.RecoverExpiredProactive(ctx, beyond.Add(time.Hour), 10, time.Minute, 4, grace)
	if err != nil {
		t.Fatalf("再次回收报错: %v", err)
	}
	if againRes.Extended != 0 || againRes.Expired != 0 || againRes.Requeued != 0 {
		t.Fatalf("收敛后应无事可做，实际 %+v", againRes)
	}
}

// TestProactiveAttemptCapConvergesToExpired 回归"重试必须有上限"：
//
// 超过上限的行必须落到明确的终态 expired，而不是无限重试、每轮再占一次当日额度。
func TestProactiveAttemptCapConvergesToExpired(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	now := time.Now()
	if err := store.EnqueueProactive(ctx, ProactiveMessage{
		ID: "m1", UserID: "u1", Kind: "geo", DedupeKey: "k1",
		ScheduledAt: now.Add(-time.Minute),
	}); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	const cap = 2
	at := now
	for i := 0; i < cap; i++ {
		got, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
			Now: at, Limit: 5, Lease: time.Minute, MaxAttempts: cap, DailyLimitFor: unlimitedClaims,
		})
		if err != nil || len(got.Claims) != 1 {
			t.Fatalf("第 %d 次领取失败: %+v err=%v", i, got.Claims, err)
		}
		if got.Claims[0].AttemptCount != i+1 {
			t.Fatalf("第 %d 次领取后 attempt_count 应为 %d，实际 %d", i, i+1, got.Claims[0].AttemptCount)
		}
		at = at.Add(2 * time.Minute)
	}
	result, err := store.RecoverExpiredProactive(ctx, at, 10, time.Minute, cap, time.Hour)
	if err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if result.Expired != 1 {
		t.Fatalf("达到重试上限的行必须落 expired，实际 %+v", result)
	}
	after, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: at.Add(time.Hour), Limit: 5, Lease: time.Minute, MaxAttempts: cap, DailyLimitFor: unlimitedClaims,
	})
	if err != nil {
		t.Fatalf("再领取失败: %v", err)
	}
	if len(after.Claims) != 0 {
		t.Fatalf("已落终态的行不得再被领取，实际 %+v", after.Claims)
	}
	if mem.rows["m1"].State != ProactiveStateExpired {
		t.Fatalf("终态应为 expired，实际 %s", mem.rows["m1"].State)
	}
}

// TestProactiveTimeZoneRoundTripAndFallback 回归时区读写的边界：
//
// 未知（空）与非法时区都回退 UTC，且回退必须是一个**确定**的解释，而不是猜一个。
func TestProactiveTimeZoneRoundTripAndFallback(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	now := time.Now()

	loc, err := store.UserLocation(ctx, "u1")
	if err != nil || loc != time.UTC {
		t.Fatalf("未知时区必须回退 UTC，实际 %v err=%v", loc, err)
	}
	if err := store.SetUserTimeZone(ctx, "u1", "Asia/Shanghai", now); err != nil {
		t.Fatalf("写入时区失败: %v", err)
	}
	loc, err = store.UserLocation(ctx, "u1")
	if err != nil || loc == nil || loc.String() != "Asia/Shanghai" {
		t.Fatalf("应读回 Asia/Shanghai，实际 %v err=%v", loc, err)
	}
	if err := store.SetUserTimeZone(ctx, "u1", "Not/AZone", now); !errors.Is(err, ErrProactiveTimeZone) {
		t.Fatalf("非法时区必须被拒，实际: %v", err)
	}
	if err := store.SetUserTimeZone(ctx, "u1", "", now); err != nil {
		t.Fatalf("清空时区应被接受（表示未知）: %v", err)
	}
	loc, err = store.UserLocation(ctx, "u1")
	if err != nil || loc != time.UTC {
		t.Fatalf("清空后必须回退 UTC，实际 %v err=%v", loc, err)
	}
}

// TestProactiveSwitchTimeZoneDoesNotResetDailyBudget 回归最重要的一条：
//
// 用户切换时区**不得**让当日额度重新计算，否则用户只要改一次时区就能被重复打扰。
// 实现上的保证是：预算窗口的边界在创建时就冻结为绝对时刻，切换时区不会新建窗口。
func TestProactiveSwitchTimeZoneDoesNotResetDailyBudget(t *testing.T) {
	mem := newMemProactive()
	var store ProactiveStore = mem
	ctx := context.Background()
	// 北京 2026-10-13 00:30：此时 UTC 仍是 10-12 16:30，两个时区的"今天"不同。
	now := time.Date(2026, 10, 12, 16, 30, 0, 0, time.UTC)
	sh, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	if err := store.SetUserTimeZone(ctx, "u1", "Asia/Shanghai", now); err != nil {
		t.Fatalf("写入时区失败: %v", err)
	}
	for _, id := range []string{"s1", "s2", "s3"} {
		if err := store.EnqueueProactive(ctx, ProactiveMessage{
			ID: id, UserID: "u1", Kind: "geo", DedupeKey: id,
			ScheduledAt: now.Add(-time.Minute),
		}); err != nil {
			t.Fatalf("入队 %s 失败: %v", id, err)
		}
	}
	budget := func(string) int { return 2 }
	first, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now, Limit: 10, Lease: 30 * time.Minute, MaxAttempts: 4,
		DailyLimitFor: budget, LocationFor: func(string) *time.Location { return sh },
	})
	if err != nil {
		t.Fatalf("首次领取失败: %v", err)
	}
	if len(first.Claims) != 2 {
		t.Fatalf("限额 2 应领到 2 条，实际 %d", len(first.Claims))
	}
	// 用户改到 UTC-8：此刻仍落在原窗口内，额度必须继续消耗同一份。
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	if err := store.SetUserTimeZone(ctx, "u1", "America/Los_Angeles", now); err != nil {
		t.Fatalf("切换时区失败: %v", err)
	}
	second, err := store.ClaimDueProactive(ctx, ProactiveClaimRequest{
		Now: now.Add(time.Minute), Limit: 10, Lease: 30 * time.Minute, MaxAttempts: 4,
		DailyLimitFor: budget, LocationFor: func(string) *time.Location { return la },
	})
	if err != nil {
		t.Fatalf("切换时区后领取失败: %v", err)
	}
	if len(second.Claims) != 0 {
		t.Fatalf("切换时区不得重置当日额度，实际又领到 %d 条", len(second.Claims))
	}
	if len(second.OverBudgetUsers) != 1 {
		t.Fatalf("切换时区后该用户仍应处于额度用尽状态，实际 %+v", second.OverBudgetUsers)
	}
}

// TestLocalDayBoundsHandlesDST 回归夏令时切换当天的日界长度：
//
// 硬加 24 小时会在切换日错一小时，于是"今天"的边界落在错误时刻，
// 用户会在不该重置的时候重置额度（或反之）。
func TestLocalDayBoundsHandlesDST(t *testing.T) {
	ny, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	// 2026-03-08 是美东夏令时开始当天：本地日长度只有 23 小时。
	now := time.Date(2026, 3, 8, 12, 0, 0, 0, ny)
	start, end := localDayBounds(now, ny)
	if got := end.Sub(start); got != 23*time.Hour {
		t.Fatalf("夏令时开始当天应为 23 小时，实际 %s", got)
	}
	if start.Location() != time.UTC || end.Location() != time.UTC {
		t.Fatal("日界必须统一为 UTC，绝对时刻不能带本地时区")
	}
	// 2026-11-01 是夏令时结束当天：本地日长度 25 小时。
	now = time.Date(2026, 11, 1, 12, 0, 0, 0, ny)
	start, end = localDayBounds(now, ny)
	if got := end.Sub(start); got != 25*time.Hour {
		t.Fatalf("夏令时结束当天应为 25 小时，实际 %s", got)
	}
}
