//go:build postgres

package store_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// 真实 PostgreSQL 上的账本行为验证。
// 与 postgres_integration_test.go 共用 openTestDB/ensureSchema/createTestUser/registerCleanup 等辅助。

func newProactiveTestMessage(prefix, user, id, key string, scheduledAt time.Time) store.ProactiveMessage {
	return store.ProactiveMessage{
		ID: id, UserID: user, Kind: "geo", DedupeKey: key,
		Title: "该出发了", Body: "去图书馆", DeepLink: "daycue://today",
		ScheduledAt: scheduledAt,
	}
}

// TestIntegrationProactiveEnqueueIsIdempotent 验证 UNIQUE(user_id, dedupe_key) 的幂等语义：
// 重复入队既不报错也不产生第二行，且第一行内容不被后来的覆盖。
func TestIntegrationProactiveEnqueueIsIdempotent(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	first := newProactiveTestMessage(prefix, user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, first); err != nil {
		t.Fatalf("首次入队失败: %v", err)
	}
	dup := first
	dup.ID = prefix + "_p2"
	dup.Title = "被覆盖的标题"
	if err := pg.EnqueueProactive(ctx, dup); err != nil {
		t.Fatalf("重复入队不得报错: %v", err)
	}

	var (
		count int
		id    string
		title string
	)
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*), COALESCE(MIN(id), ''), COALESCE(MIN(title), '') FROM proactive_message WHERE user_id = $1 AND dedupe_key = $2`,
		user, first.DedupeKey).Scan(&count, &id, &title); err != nil {
		t.Fatalf("统计入队结果失败: %v", err)
	}
	if count != 1 {
		t.Fatalf("同一 (user_id, dedupe_key) 必须只有一行，实际 %d 行", count)
	}
	if id != first.ID || title != first.Title {
		t.Fatalf("DO NOTHING 不应覆盖首行，实际 id=%s title=%s", id, title)
	}
}

// TestIntegrationProactiveConcurrentClaimIsExclusive 验证并发两个调度循环不会认领到同一行。
// 这是"预算预留"承诺里最关键的一条：认领必须原子，否则同一条消息会被发两次。
func TestIntegrationProactiveConcurrentClaimIsExclusive(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	const total = 5
	for i := 0; i < total; i++ {
		msg := newProactiveTestMessage(prefix, user,
			prefix+"_p"+string(rune('a'+i)), prefix+"_k"+string(rune('a'+i)), now.Add(-time.Minute))
		if err := pg.EnqueueProactive(ctx, msg); err != nil {
			t.Fatalf("入队第 %d 条失败: %v", i, err)
		}
	}

	var (
		wg      sync.WaitGroup
		start   = make(chan struct{})
		results [2][]store.ProactiveClaim
		errs    [2]error
	)
	for k := 0; k < 2; k++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			<-start
			results[k], errs[k] = pg.ClaimDueProactive(ctx, now, total)
		}(k)
	}
	close(start)
	wg.Wait()
	for k := 0; k < 2; k++ {
		if errs[k] != nil {
			t.Fatalf("并发认领第 %d 个报错: %v", k, errs[k])
		}
	}

	seen := map[string]int{}
	for k := 0; k < 2; k++ {
		for _, c := range results[k] {
			seen[c.ID]++
		}
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("同一条消息被认领了 %d 次（id=%s），并发下会重复发送", n, id)
		}
	}
	if len(seen) != total {
		t.Fatalf("两个并发认领应合起来占用全部 %d 条，实际 %d 条", total, len(seen))
	}

	var claimed int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM proactive_message WHERE user_id = $1 AND claimed_at IS NOT NULL`, user).Scan(&claimed); err != nil {
		t.Fatalf("统计认领状态失败: %v", err)
	}
	if claimed != total {
		t.Fatalf("认领后应有 %d 行 claimed_at 非空，实际 %d", total, claimed)
	}
}

// TestIntegrationProactiveMarkDeviceInvalid 验证令牌失效会清空设备的 push_token 而不是删行。
func TestIntegrationProactiveMarkDeviceInvalid(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	device := store.Device{
		ID: prefix + "_dev", UserID: user, Platform: "ios", Name: "iPhone",
		PushToken: "tok-abc", CreatedAt: now, UpdatedAt: now,
	}
	if err := pg.UpsertDevice(ctx, device); err != nil {
		t.Fatalf("登记设备失败: %v", err)
	}
	if err := pg.MarkDeviceInvalid(ctx, user, device.ID, now); err != nil {
		t.Fatalf("停用设备失败: %v", err)
	}
	got, err := pg.DeviceByID(ctx, user, device.ID)
	if err != nil {
		t.Fatalf("停用后仍应能读到设备（不是删行）: %v", err)
	}
	if got.PushToken != "" {
		t.Fatalf("停用后 push_token 必须清空，实际 %q", got.PushToken)
	}
	// 不存在的设备必须报 ErrNotFound，而不是静默成功。
	if err := pg.MarkDeviceInvalid(ctx, user, prefix+"_missing", now); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("停用不存在的设备应返回 ErrNotFound，实际: %v", err)
	}
}
