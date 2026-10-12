//go:build postgres

package store_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// 真实 PostgreSQL 上的**完整领取协议**验证。
//
// 为什么这些用例必须跑在真库上：租约、凭证、按用户限额的原子预留全都依赖
// SELECT ... FOR UPDATE / ON CONFLICT / 唯一键冲突这些数据库语义；
// 内存替身再像也不是数据库，用替身证明"并发不会超发"等于什么都没证明。
//
// 与 postgres_integration_test.go 共用 openTestDB/ensureSchema/createTestUser/registerCleanup。

func newProactiveTestMessage(user, id, key string, scheduledAt time.Time) store.ProactiveMessage {
	return store.ProactiveMessage{
		ID: id, UserID: user, Kind: "geo", DedupeKey: key,
		Title: "该出发了", Body: "去图书馆", DeepLink: "daycue://today",
		ScheduledAt: scheduledAt,
	}
}

// claimForTest 组装一个只关心"领一条"的领取请求。
func claimForTest(now time.Time, limit int) store.ProactiveClaimRequest {
	return store.ProactiveClaimRequest{
		Now: now, Limit: limit,
		ClaimedBy:   "it-runner-a",
		Lease:       10 * time.Minute,
		MaxAttempts: 4,
		DailyLimitFor: func(string) int {
			return 100
		},
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

	first := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
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

// TestIntegrationProactiveConcurrentClaimIsExclusive 验证并发两个调度进程不会领到同一行，
// 并且两条都拿到了互不相同的凭证与投递标识。
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
		msg := newProactiveTestMessage(user,
			fmt.Sprintf("%s_p%d", prefix, i), fmt.Sprintf("%s_k%d", prefix, i), now.Add(-time.Minute))
		if err := pg.EnqueueProactive(ctx, msg); err != nil {
			t.Fatalf("入队第 %d 条失败: %v", i, err)
		}
	}

	var (
		wg      sync.WaitGroup
		start   = make(chan struct{})
		results [2]store.ProactiveClaimBatch
		errs    [2]error
	)
	for k := 0; k < 2; k++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			<-start
			req := claimForTest(now, total)
			req.ClaimedBy = fmt.Sprintf("it-runner-%d", k)
			results[k], errs[k] = pg.ClaimDueProactive(ctx, req)
		}(k)
	}
	close(start)
	wg.Wait()
	for k := 0; k < 2; k++ {
		if errs[k] != nil {
			t.Fatalf("并发领取第 %d 个报错: %v", k, errs[k])
		}
	}

	// 断言真正的互斥不变量：同一条消息只能出现在一个领取者的结果里。
	//
	// 关于凭证：**同一批领取共用一个 token**，这是刻意的设计。凭证的作用是证明
	// "这批行现在归谁"，续租、发起投递、提交回执三处都按它匹配；重新领取时必然换发
	// 新凭证，所以"旧执行者的回执被拒"这条语义并不需要逐行 token。
	// 逐行 token 只有在"同一批内需要区分行"时才需要，而账本里区分行用的是 id。
	// 因此这里断言的是：① 同一条 id 只被领一次（互斥）；② 两个领取者各自的 token 不同
	// （证明不是同一批被重复返回）；③ token 必须非空（空 token 等于没有持有者）。
	seen := map[string]int{}
	tokensByRunner := map[string]map[string]bool{}
	for k := 0; k < 2; k++ {
		for _, c := range results[k].Claims {
			seen[c.ID]++
			if c.ClaimToken == "" {
				t.Fatalf("领取必须给出凭证，实际 %+v", c)
			}
			if tokensByRunner[c.ClaimToken] == nil {
				tokensByRunner[c.ClaimToken] = map[string]bool{}
			}
			tokensByRunner[c.ClaimToken][fmt.Sprintf("runner-%d", k)] = true
			if c.DeliveryID == "" {
				t.Fatalf("领取必须给出投递标识，实际 %+v", c)
			}
			if c.AttemptCount != 1 {
				t.Fatalf("首次领取后 attempt_count 应为 1，实际 %d", c.AttemptCount)
			}
		}
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("同一条消息被领取了 %d 次（id=%s），并发下会重复发送", n, id)
		}
	}
	// 两个领取者都拿到行时，凭证必须不同：相同就意味着第二次领取返回的是同一批。
	if len(results[0].Claims) > 0 && len(results[1].Claims) > 0 {
		if results[0].Claims[0].ClaimToken == results[1].Claims[0].ClaimToken {
			t.Fatalf("两个独立领取者拿到了同一个凭证 %s，凭证必须按领取批次唯一",
				results[0].Claims[0].ClaimToken)
		}
	}
	if len(seen) != total {
		t.Fatalf("两个并发领取应合起来领完全部 %d 条，实际 %d 条", total, len(seen))
	}

	var claimed int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM proactive_message WHERE user_id = $1 AND claim_token <> ''`, user).Scan(&claimed); err != nil {
		t.Fatalf("统计领取状态失败: %v", err)
	}
	if claimed != total {
		t.Fatalf("领取后应有 %d 行带凭证，实际 %d", total, claimed)
	}
}

// TestIntegrationProactiveConcurrentClaimRespectsDailyLimit 是本轮最关键的真库并发证明：
//
// 6 条到期消息、每用户每日上限 2，8 个 goroutine 用**同一条 DSN** 同时领取，
// 合计领取条数必须恰好是 2，且结算后当日 delivered 也不得超过 2。
//
// 顺序调用证明不了这件事：问题恰恰出在"两个调度进程各自看余额"的那一刻。
func TestIntegrationProactiveConcurrentClaimRespectsDailyLimit(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	const total = 6
	const budget = 2
	for i := 0; i < total; i++ {
		msg := newProactiveTestMessage(user,
			fmt.Sprintf("%s_p%d", prefix, i), fmt.Sprintf("%s_k%d", prefix, i), now.Add(-time.Minute))
		if err := pg.EnqueueProactive(ctx, msg); err != nil {
			t.Fatalf("入队第 %d 条失败: %v", i, err)
		}
	}

	const runners = 8
	var (
		wg      sync.WaitGroup
		start   = make(chan struct{})
		mu      sync.Mutex
		claimed []store.ProactiveClaim
		errs    []error
	)
	for k := 0; k < runners; k++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			<-start
			req := claimForTest(now, total)
			req.ClaimedBy = fmt.Sprintf("it-budget-runner-%d", k)
			req.DailyLimitFor = func(string) int { return budget }
			batch, err := pg.ClaimDueProactive(ctx, req)
			mu.Lock()
			defer mu.Unlock()
			claimed = append(claimed, batch.Claims...)
			errs = append(errs, err)
		}(k)
	}
	close(start)
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			t.Fatalf("并发领取报错: %v", err)
		}
	}
	if len(claimed) != budget {
		t.Fatalf("每日上限 %d 时并发领取合计必须恰好 %d 条，实际 %d 条（超出即会重复打扰用户）",
			budget, budget, len(claimed))
	}

	// 把领到的两条如实结算成已发出，再看当日账目。
	for _, c := range claimed {
		at := now.Add(time.Second)
		if err := pg.SettleProactive(ctx, store.ProactiveSettleRequest{
			ID: c.ID, Token: c.ClaimToken, State: store.ProactiveStateDelivered,
			DeliveredAt: &at, DeliveryStatus: store.ProactiveDeliveryNotAttempted, At: at,
		}); err != nil {
			t.Fatalf("结算已发出的领取失败: %v", err)
		}
	}
	facts, err := pg.ProactiveHistory(ctx, user, "", "", now, time.UTC)
	if err != nil {
		t.Fatalf("读取判定事实失败: %v", err)
	}
	if facts.DeliveredToday != budget {
		t.Fatalf("当日已发出应为 %d 条，实际 %d", budget, facts.DeliveredToday)
	}
	if facts.ReservedToday != 0 {
		t.Fatalf("结算后预留必须回退为 0，实际 %d", facts.ReservedToday)
	}

	// 额度用尽后再领一次：一条都拿不到，并且用户会被明确列进 OverBudgetUsers。
	// 注意必须带上**同一个**每日上限：用默认上限（很大）来断言"领不到"是空转。
	afterReq := claimForTest(now.Add(2*time.Second), total)
	afterReq.DailyLimitFor = func(string) int { return budget }
	after, err := pg.ClaimDueProactive(ctx, afterReq)
	if err != nil {
		t.Fatalf("额度用尽后领取报错: %v", err)
	}
	if len(after.Claims) != 0 {
		t.Fatalf("当日额度已用尽，不得再领，实际 %+v", after.Claims)
	}
	if len(after.OverBudgetUsers) != 1 || after.OverBudgetUsers[0] != user {
		t.Fatalf("额度用尽的用户应被列入 OverBudgetUsers，实际 %+v", after.OverBudgetUsers)
	}
}

// TestIntegrationProactiveStaleExecutorRejected 验证旧执行者的回执被拒：
//
// 租约被回收并重新领取后，原执行者带着旧凭证提交结果必须返回
// ErrProactiveClaimMismatch，且库里状态与凭证一律不变。
func TestIntegrationProactiveStaleExecutorRejected(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	msg := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, msg); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	req := claimForTest(now, 5)
	req.Lease = time.Minute
	batch, err := pg.ClaimDueProactive(ctx, req)
	if err != nil || len(batch.Claims) != 1 {
		t.Fatalf("首次领取失败: %+v err=%v", batch.Claims, err)
	}
	stale := batch.Claims[0]

	// 让租约过期并回收：尚未发起投递，所以应当被放回待领取。
	later := now.Add(2 * time.Minute)
	res, err := pg.RecoverExpiredProactive(ctx, later, 10, time.Minute, 4, time.Hour)
	if err != nil {
		t.Fatalf("回收过期租约失败: %v", err)
	}
	if res.Requeued != 1 {
		t.Fatalf("尚未发起投递的过期租约应被放回待领取，实际 %+v", res)
	}

	req2 := claimForTest(later, 5)
	req2.Lease = time.Minute
	req2.ClaimedBy = "it-runner-b"
	fresh, err := pg.ClaimDueProactive(ctx, req2)
	if err != nil || len(fresh.Claims) != 1 {
		t.Fatalf("回收后应能重新领取: %+v err=%v", fresh.Claims, err)
	}
	if fresh.Claims[0].ClaimToken == stale.ClaimToken {
		t.Fatalf("重新领取必须换发新凭证，实际仍是 %s", stale.ClaimToken)
	}

	at := later.Add(time.Second)
	err = pg.SettleProactive(ctx, store.ProactiveSettleRequest{
		ID: stale.ID, Token: stale.ClaimToken, State: store.ProactiveStateDelivered,
		DeliveredAt: &at, DeliveryStatus: store.ProactiveDeliveryNotAttempted, At: at,
	})
	if !errors.Is(err, store.ErrProactiveClaimMismatch) {
		t.Fatalf("旧执行者的回执必须被拒为 ErrProactiveClaimMismatch，实际: %v", err)
	}

	var (
		state string
		token string
		deliv *time.Time
	)
	if err := db.QueryRowContext(ctx,
		`SELECT state, claim_token, delivered_at FROM proactive_message WHERE id = $1`, stale.ID).
		Scan(&state, &token, &deliv); err != nil {
		t.Fatalf("读取行状态失败: %v", err)
	}
	if state != store.ProactiveStatePending || token != fresh.Claims[0].ClaimToken || deliv != nil {
		t.Fatalf("被拒的回执不得改动任何状态，实际 state=%s token=%s delivered_at=%v", state, token, deliv)
	}

	// 凭证正确但租约已过期：同样必须被拒，迟到的回执无法归因。
	late := later.Add(time.Hour)
	err = pg.SettleProactive(ctx, store.ProactiveSettleRequest{
		ID: fresh.Claims[0].ID, Token: fresh.Claims[0].ClaimToken, State: store.ProactiveStateDelivered,
		DeliveredAt: &late, DeliveryStatus: store.ProactiveDeliveryNotAttempted, At: late,
	})
	if !errors.Is(err, store.ErrProactiveLeaseExpired) {
		t.Fatalf("过期租约之上的写入必须被拒为 ErrProactiveLeaseExpired，实际: %v", err)
	}
}

// TestIntegrationProactiveRetryBackoff 验证失败重试退避：
// 释放时写入的退避截止时刻之前领不到，到期后才能重新领到。
func TestIntegrationProactiveRetryBackoff(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	msg := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, msg); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	batch, err := pg.ClaimDueProactive(ctx, claimForTest(now, 5))
	if err != nil || len(batch.Claims) != 1 {
		t.Fatalf("首次领取失败: %+v err=%v", batch.Claims, err)
	}
	job := batch.Claims[0]

	const backoff = 90 * time.Second
	if err := pg.SettleProactive(ctx, store.ProactiveSettleRequest{
		ID: job.ID, Token: job.ClaimToken, State: store.ProactiveStatePending,
		SuppressReason: "rate_limited", At: now, RetryAfter: backoff,
		DeliveryStatus: store.ProactiveDeliveryNotAttempted,
	}); err != nil {
		t.Fatalf("释放（带退避）失败: %v", err)
	}

	early, err := pg.ClaimDueProactive(ctx, claimForTest(now.Add(time.Second), 5))
	if err != nil {
		t.Fatalf("退避期内领取报错: %v", err)
	}
	if len(early.Claims) != 0 {
		t.Fatalf("退避期内不得重新领取，实际 %+v", early.Claims)
	}

	later := now.Add(backoff + time.Second)
	again, err := pg.ClaimDueProactive(ctx, claimForTest(later, 5))
	if err != nil || len(again.Claims) != 1 {
		t.Fatalf("退避到期后应能重新领取: %+v err=%v", again.Claims, err)
	}
	if again.Claims[0].AttemptCount != 2 {
		t.Fatalf("重新领取应累加 attempt_count 到 2，实际 %d", again.Claims[0].AttemptCount)
	}
}

// TestIntegrationProactiveUnknownDeliveryIsNotResent 验证"结果不明不得盲目重发"：
//
// 已发起投递但结果丢失的行，租约过期后只能延长租约；它既不能被重新领取，
// 也不能被算成"尚未发送"而重发。
func TestIntegrationProactiveUnknownDeliveryIsNotResent(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	msg := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, msg); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	req := claimForTest(now, 5)
	req.Lease = time.Minute
	batch, err := pg.ClaimDueProactive(ctx, req)
	if err != nil || len(batch.Claims) != 1 {
		t.Fatalf("领取失败: %+v err=%v", batch.Claims, err)
	}
	job := batch.Claims[0]

	// 先登记"已发起投递"，然后进程"崩溃"（不再有任何回执）。
	if err := pg.BeginProactiveDelivery(ctx, job.ID, job.ClaimToken, now); err != nil {
		t.Fatalf("登记发起投递失败: %v", err)
	}

	later := now.Add(2 * time.Minute)
	res, err := pg.RecoverExpiredProactive(ctx, later, 10, time.Minute, 4, time.Hour)
	if err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if res.Extended != 1 || res.Requeued != 0 || res.Expired != 0 {
		t.Fatalf("结果不明的行只能延长租约，实际 %+v", res)
	}

	after, err := pg.ClaimDueProactive(ctx, claimForTest(later.Add(time.Second), 5))
	if err != nil {
		t.Fatalf("回收后领取报错: %v", err)
	}
	if len(after.Claims) != 0 {
		t.Fatalf("结果不明的行不得被重新领取（会重复打扰用户），实际 %+v", after.Claims)
	}

	var status string
	if err := db.QueryRowContext(ctx,
		`SELECT delivery_status FROM proactive_message WHERE id = $1`, job.ID).Scan(&status); err != nil {
		t.Fatalf("读取交付确定性失败: %v", err)
	}
	if status != store.ProactiveDeliveryUnknown {
		t.Fatalf("行应被标记为结果不明，实际 %s", status)
	}
}

// TestIntegrationProactiveUnknownDeliveryConvergesAfterGrace 回归"结果不明也必须收敛"。
//
// 守的是一个很隐蔽的死角：结果不明的行不会被再次领取，attempt_count 因此不再增长，
// "已达重试上限"对它永远不成立。少了期限，它每一轮回收都会被重写一遍却永远停在
// pending。这条用例同时钉住两件事：必须收敛成终态，且收敛之后**仍然不得重发**。
func TestIntegrationProactiveUnknownDeliveryConvergesAfterGrace(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	msg := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, msg); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	req := claimForTest(now, 5)
	req.Lease = time.Minute
	batch, err := pg.ClaimDueProactive(ctx, req)
	if err != nil || len(batch.Claims) != 1 {
		t.Fatalf("领取失败: %+v err=%v", batch.Claims, err)
	}
	job := batch.Claims[0]
	if err := pg.BeginProactiveDelivery(ctx, job.ID, job.ClaimToken, now); err != nil {
		t.Fatalf("登记发起投递失败: %v", err)
	}

	const grace = time.Hour
	// 第一次回收：刚变成结果不明，在期限之内 → 只延长租约。
	first := now.Add(2 * time.Minute)
	res, err := pg.RecoverExpiredProactive(ctx, first, 10, time.Minute, 4, grace)
	if err != nil {
		t.Fatalf("首次回收失败: %v", err)
	}
	if res.Extended != 1 || res.Expired != 0 || res.Requeued != 0 {
		t.Fatalf("期限内的结果不明只能延长租约，实际 %+v", res)
	}

	// 第二次回收：已超过期限 → 收敛成 expired。原因必须记成"结果不明超期"而不是
	// "重试打满"，否则排障时分不清该去查供应商还是该去查自己的进程。
	beyond := first.Add(2 * grace)
	res, err = pg.RecoverExpiredProactive(ctx, beyond, 10, time.Minute, 4, grace)
	if err != nil {
		t.Fatalf("超期回收失败: %v", err)
	}
	if res.Expired != 1 || res.Extended != 0 || res.Requeued != 0 {
		t.Fatalf("超过解决期限的结果不明必须收敛成终态，实际 %+v", res)
	}

	var state, reason string
	if err := db.QueryRowContext(ctx,
		`SELECT state, suppress_reason FROM proactive_message WHERE id = $1`, job.ID).
		Scan(&state, &reason); err != nil {
		t.Fatalf("读取终态失败: %v", err)
	}
	if state != store.ProactiveStateExpired || reason != "delivery_unknown_unresolved" {
		t.Fatalf("终态应为 expired/delivery_unknown_unresolved，实际 %s/%s", state, reason)
	}

	// 收敛之后仍然不得被重新领取：给期限是为了收敛，不是改主意要补发。
	after, err := pg.ClaimDueProactive(ctx, claimForTest(beyond.Add(time.Second), 5))
	if err != nil {
		t.Fatalf("收敛后领取报错: %v", err)
	}
	if len(after.Claims) != 0 {
		t.Fatalf("已收敛的结果不明行不得被重新领取，实际 %+v", after.Claims)
	}

	// 再回收一次必须无事可做：否则说明它并没有真的收敛。
	again, err := pg.RecoverExpiredProactive(ctx, beyond.Add(time.Hour), 10, time.Minute, 4, grace)
	if err != nil {
		t.Fatalf("再次回收报错: %v", err)
	}
	if again.Extended != 0 || again.Expired != 0 || again.Requeued != 0 {
		t.Fatalf("收敛后应无事可做，实际 %+v", again)
	}
}

// TestIntegrationProactiveAttemptCapConvergesToExpired 验证重试上限收敛：
// 超过上限的行由回收动作落成 expired 终态，之后再也领不到，不会无限重试。
func TestIntegrationProactiveAttemptCapConvergesToExpired(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	msg := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, msg); err != nil {
		t.Fatalf("入队失败: %v", err)
	}

	const cap = 2
	at := now
	for i := 0; i < cap; i++ {
		req := claimForTest(at, 5)
		req.Lease = time.Minute
		req.MaxAttempts = cap
		batch, err := pg.ClaimDueProactive(ctx, req)
		if err != nil || len(batch.Claims) != 1 {
			t.Fatalf("第 %d 次领取失败: %+v err=%v", i, batch.Claims, err)
		}
		if batch.Claims[0].AttemptCount != i+1 {
			t.Fatalf("第 %d 次领取后 attempt_count 应为 %d，实际 %d", i, i+1, batch.Claims[0].AttemptCount)
		}
		at = at.Add(2 * time.Minute)
	}

	res, err := pg.RecoverExpiredProactive(ctx, at, 10, time.Minute, cap, time.Hour)
	if err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if res.Expired != 1 {
		t.Fatalf("达到重试上限的行必须落 expired，实际 %+v", res)
	}

	after, err := pg.ClaimDueProactive(ctx, claimForTest(at.Add(time.Hour), 5))
	if err != nil {
		t.Fatalf("回收后领取报错: %v", err)
	}
	if len(after.Claims) != 0 {
		t.Fatalf("已落终态的行不得再被领取，实际 %+v", after.Claims)
	}

	var state, reason string
	if err := db.QueryRowContext(ctx,
		`SELECT state, suppress_reason FROM proactive_message WHERE id = $1`, msg.ID).Scan(&state, &reason); err != nil {
		t.Fatalf("读取行状态失败: %v", err)
	}
	if state != store.ProactiveStateExpired || reason != "attempts_exhausted" {
		t.Fatalf("终态应为 expired/attempts_exhausted，实际 %s/%s", state, reason)
	}
}

// TestIntegrationProactiveCancelRace 验证取消与领取的竞态：
//
// 一边把行落成 cancelled，一边并发领取并尝试落 delivered。
// 无论谁先，最终状态只能是 cancelled 或 delivered，且**绝不能出现"已取消却又被发出"**：
// 也就是不存在 state=cancelled 同时 delivered_at 非空的行。
func TestIntegrationProactiveCancelRace(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	const rounds = 12
	var wg sync.WaitGroup
	for i := 0; i < rounds; i++ {
		msg := newProactiveTestMessage(user,
			fmt.Sprintf("%s_p%d", prefix, i), fmt.Sprintf("%s_k%d", prefix, i), now.Add(-time.Minute))
		msg.DeviceID = prefix + "_dev"
		if err := pg.EnqueueProactive(ctx, msg); err != nil {
			t.Fatalf("入队第 %d 条失败: %v", i, err)
		}
	}
	// 先登记设备，取消才有对象可取消。
	if err := pg.UpsertDevice(ctx, store.Device{
		ID: prefix + "_dev", UserID: user, Platform: "ios", Name: "集成测试设备",
		PushToken: "tok", LastSeenAt: now, CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("登记设备失败: %v", err)
	}

	start := make(chan struct{})
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < 3; i++ {
			if _, err := pg.CancelPendingForDevice(context.Background(), user, prefix+"_dev", now); err != nil {
				t.Errorf("取消失败: %v", err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < 3; i++ {
			req := claimForTest(now, rounds)
			req.ClaimedBy = "it-cancel-race"
			batch, err := pg.ClaimDueProactive(context.Background(), req)
			if err != nil {
				t.Errorf("领取失败: %v", err)
				return
			}
			for _, c := range batch.Claims {
				at := now.Add(time.Second)
				// "已取消却又被发出"如果在实现里存在，这里就会真的写进去。
				_ = pg.SettleProactive(context.Background(), store.ProactiveSettleRequest{
					ID: c.ID, Token: c.ClaimToken, State: store.ProactiveStateDelivered,
					DeliveredAt: &at, DeliveryStatus: store.ProactiveDeliveryNotAttempted, At: at,
				})
			}
		}
	}()
	close(start)
	wg.Wait()

	var bad int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM proactive_message
		 WHERE user_id = $1 AND state = 'cancelled' AND delivered_at IS NOT NULL`, user).Scan(&bad); err != nil {
		t.Fatalf("统计取消竞态结果失败: %v", err)
	}
	if bad != 0 {
		t.Fatalf("出现 %d 条「已取消却又被发出」的行：取消必须是终态", bad)
	}

	var other int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM proactive_message
		 WHERE user_id = $1 AND state NOT IN ('pending','delivered','cancelled','suppressed','expired')`,
		user).Scan(&other); err != nil {
		t.Fatalf("统计非法状态失败: %v", err)
	}
	if other != 0 {
		t.Fatalf("出现了 %d 条账本 CHECK 之外的异常状态", other)
	}
}

// TestIntegrationProactiveUserTimeZoneWindow 验证时区决定自然日边界，
// 且用户**切换时区不会重置当日额度**。
//
// 这是本轮最重要的一条产品语义：如果切换时区能让额度重新开始，
// 用户只要改一次时区就会被重复打扰。
func TestIntegrationProactiveUserTimeZoneWindow(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	sh, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	// 北京 2026-10-13 00:30，此刻 UTC 仍是 10-12 16:30：两个时区的"今天"不同。
	now := time.Date(2026, 10, 12, 16, 30, 0, 0, time.UTC)
	if err := pg.SetUserTimeZone(ctx, user, "Asia/Shanghai", now); err != nil {
		t.Fatalf("写入时区失败: %v", err)
	}
	loc, err := pg.UserLocation(ctx, user)
	if err != nil || loc.String() != "Asia/Shanghai" {
		t.Fatalf("应读回 Asia/Shanghai，实际 %v err=%v", loc, err)
	}

	const budget = 2
	for i := 0; i < 3; i++ {
		msg := newProactiveTestMessage(user,
			fmt.Sprintf("%s_p%d", prefix, i), fmt.Sprintf("%s_k%d", prefix, i), now.Add(-time.Minute))
		if err := pg.EnqueueProactive(ctx, msg); err != nil {
			t.Fatalf("入队第 %d 条失败: %v", i, err)
		}
	}
	req := claimForTest(now, 10)
	req.DailyLimitFor = func(string) int { return budget }
	req.LocationFor = func(string) *time.Location { return sh }
	first, err := pg.ClaimDueProactive(ctx, req)
	if err != nil {
		t.Fatalf("首次领取失败: %v", err)
	}
	if len(first.Claims) != budget {
		t.Fatalf("上限 %d 应领到 %d 条，实际 %d", budget, budget, len(first.Claims))
	}

	// 预算窗口的起点必须正好是北京当地 00:00，而不是 UTC 00:00。
	var winStart time.Time
	if err := db.QueryRowContext(ctx,
		`SELECT win_start FROM proactive_budget_window WHERE user_id = $1 ORDER BY win_start DESC LIMIT 1`, user).
		Scan(&winStart); err != nil {
		t.Fatalf("读取预算窗口失败: %v", err)
	}
	wantStart := time.Date(2026, 10, 12, 16, 0, 0, 0, time.UTC)
	if !winStart.UTC().Equal(wantStart) {
		t.Fatalf("窗口起点应为北京 10-13 00:00（UTC %s），实际 %s", wantStart, winStart.UTC())
	}

	// 用户改到 America/Los_Angeles：此刻仍落在同一窗口内，额度不得重置。
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	if err := pg.SetUserTimeZone(ctx, user, "America/Los_Angeles", now); err != nil {
		t.Fatalf("切换时区失败: %v", err)
	}
	req2 := claimForTest(now.Add(time.Minute), 10)
	req2.DailyLimitFor = func(string) int { return budget }
	req2.LocationFor = func(string) *time.Location { return la }
	second, err := pg.ClaimDueProactive(ctx, req2)
	if err != nil {
		t.Fatalf("切换时区后领取失败: %v", err)
	}
	if len(second.Claims) != 0 {
		t.Fatalf("切换时区不得重置当日额度，实际又领到 %d 条", len(second.Claims))
	}
	if len(second.OverBudgetUsers) != 1 {
		t.Fatalf("切换时区后该用户仍应处于额度用尽状态，实际 %+v", second.OverBudgetUsers)
	}

	// 时区名非法必须被拒：写进去读不出来的值会让用户以为自己设了时区。
	if err := pg.SetUserTimeZone(ctx, user, "Not/AZone", now); !errors.Is(err, store.ErrProactiveTimeZone) {
		t.Fatalf("非法时区必须被拒为 ErrProactiveTimeZone，实际: %v", err)
	}
	// 清空表示"未知"，读取时回退 UTC。
	if err := pg.SetUserTimeZone(ctx, user, "", now); err != nil {
		t.Fatalf("清空时区应被接受: %v", err)
	}
	loc, err = pg.UserLocation(ctx, user)
	if err != nil || loc != time.UTC {
		t.Fatalf("清空后必须回退 UTC，实际 %v err=%v", loc, err)
	}
}

// TestIntegrationProactiveLeaseRenewAndCancelGuards 验证续租的两条边界：
// 有效租约可以续，已过期的租约**不允许**复活。
func TestIntegrationProactiveLeaseRenewAndCancelGuards(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	prefix := testIDPrefix(t)
	user := prefix
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)
	now := time.Now().UTC()

	msg := newProactiveTestMessage(user, prefix+"_p1", prefix+"_k1", now.Add(-time.Minute))
	if err := pg.EnqueueProactive(ctx, msg); err != nil {
		t.Fatalf("入队失败: %v", err)
	}
	req := claimForTest(now, 5)
	req.Lease = time.Minute
	batch, err := pg.ClaimDueProactive(ctx, req)
	if err != nil || len(batch.Claims) != 1 {
		t.Fatalf("领取失败: %+v err=%v", batch.Claims, err)
	}
	job := batch.Claims[0]

	deadline, err := pg.RenewProactiveLease(ctx, job.ID, job.ClaimToken, now.Add(30*time.Second), 10*time.Minute)
	if err != nil {
		t.Fatalf("有效租约应可续期: %v", err)
	}
	if !deadline.After(job.LeaseExpiresAt) {
		t.Fatalf("续期后的截止时刻必须更晚，实际 %s（原 %s）", deadline, job.LeaseExpiresAt)
	}
	if _, err := pg.RenewProactiveLease(ctx, job.ID, job.ClaimToken, now.Add(time.Hour), 10*time.Minute); !errors.Is(err, store.ErrProactiveNotClaimed) {
		t.Fatalf("已过期的租约不得复活，实际: %v", err)
	}
	// 凭证不对的续租同样被拒。
	if _, err := pg.RenewProactiveLease(ctx, job.ID, "ctk_wrong", now, time.Minute); !errors.Is(err, store.ErrProactiveNotClaimed) {
		t.Fatalf("凭证不符的续租必须被拒，实际: %v", err)
	}

	// 发起投递之后，设备失效取消不得抹掉这一行：它可能已经被供应商接受。
	if err := pg.BeginProactiveDelivery(ctx, job.ID, job.ClaimToken, now); err != nil {
		t.Fatalf("登记发起投递失败: %v", err)
	}
	if err := pg.UpsertDevice(ctx, store.Device{
		ID: prefix + "_dev", UserID: user, Platform: "ios", Name: "集成测试设备",
		PushToken: "tok", LastSeenAt: now, CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("登记设备失败: %v", err)
	}
	if err := pg.AssignProactiveDevice(ctx, job.ID, prefix+"_dev", now); err != nil {
		t.Fatalf("记录目标设备失败: %v", err)
	}
	n, err := pg.CancelPendingForDevice(ctx, user, prefix+"_dev", now)
	if err != nil {
		t.Fatalf("取消失败: %v", err)
	}
	if n != 0 {
		t.Fatalf("已发起投递的行不得被设备取消抹掉，实际取消了 %d 条", n)
	}
}
