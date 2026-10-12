//go:build postgres

// 真实 PostgreSQL 上的并发冲突测试。
//
// 为什么必须用真实数据库 + 真并发 goroutine：
// "同一版本并发写入只能有一方成功"依赖 SELECT ... FOR UPDATE 的行锁语义。
// 顺序地"先推一次、再推一次"只能证明版本号比较，证明不了两个事务真的同时
// 进入"读当前版本"这一段 —— 而那正是"静默丢更新"会发生的窗口。
//
// 环境变量缺失时由 openTestDB 统一 t.Skip 并打印原因，绝不退回内存存储。
package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

// sameJSON 比较两段 JSON 的语义是否一致。
//
// 不能直接比字节：sync_record.payload 是 JSONB，PostgreSQL 会规范化键顺序与空白，
// 写进去的 {"round":0} 读出来是 {"round": 0}；按字节比会把正确实现判成失败。
func sameJSON(t *testing.T, a, b []byte) bool {
	t.Helper()
	var x, y any
	if err := json.Unmarshal(a, &x); err != nil {
		t.Fatalf("服务端内容不是合法 JSON: %v (%s)", err, a)
	}
	if err := json.Unmarshal(b, &y); err != nil {
		t.Fatalf("期望内容不是合法 JSON: %v (%s)", err, b)
	}
	return reflect.DeepEqual(x, y)
}

// TestIntegrationConcurrentSameVersionPushLosesNoData 验证同一 Version 上的并发写入
// 恰好只有一方成功，且服务端留下的是胜者的内容，冲突方绝不覆盖它。
//
// 这是"静默丢更新"的现场复现：如果 Push 只是"读版本 → 判断 → UPSERT"而不在同一事务里
// 用 SELECT ... FOR UPDATE 锁行，多个写者会同时读到旧版本并全部成功，最后提交者覆盖前者；
// 用户会以为自己的修改保存了，实际已被别人覆盖且没有任何冲突提示。
func TestIntegrationConcurrentSameVersionPushLosesNoData(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	user := prefix + "_u"
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	entityID := prefix + "_task"
	first, err := pg.Push(ctx, store.Record{
		UserID: user, Type: store.EntityTask, ID: entityID,
		Payload: mustJSON(t, map[string]string{"title": "初版"}),
	}, 0)
	if err != nil {
		t.Fatalf("写入初版失败: %v", err)
	}
	if first.Version <= 0 {
		t.Fatalf("初版应得到正版本号，实际 %d", first.Version)
	}

	const (
		// 同一版本上的并发写者数：>=3 才能暴露"两方同时通过版本检查"的漏网。
		writers = 4
		rounds  = 8
	)
	for round := 0; round < rounds; round++ {
		// 每轮都以数据库里的真实版本为共同基准，而不是复用上一轮的变量：
		// 避免测试自己把基准记错，却让并发断言看起来通过。
		cur, _, err := pg.Pull(ctx, user, "", 0)
		if err != nil {
			t.Fatalf("第 %d 轮读取当前版本失败: %v", round, err)
		}
		if len(cur) != 1 {
			t.Fatalf("第 %d 轮应当只有 1 条记录，实际 %d 条", round, len(cur))
		}
		base := cur[0].Record.Version

		payloads := make([][]byte, writers)
		for i := 0; i < writers; i++ {
			payloads[i] = mustJSON(t, map[string]any{"round": round, "writer": i})
		}
		errs := make([]error, writers)
		saved := make([]store.Record, writers)

		// start 是同步栅栏：所有写者都阻塞在 <-start 上，close 之后才一起冲进 Push，
		// 这样它们会在数据库侧真正重叠，而不是被 for 循环排成队。
		start := make(chan struct{})
		var wg sync.WaitGroup
		for i := 0; i < writers; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				saved[i], errs[i] = pg.Push(ctx, store.Record{
					UserID: user, Type: store.EntityTask, ID: entityID, Payload: payloads[i],
				}, base)
			}(i)
		}
		close(start)
		wg.Wait()

		winner := -1
		for i, e := range errs {
			switch {
			case e == nil:
				if winner >= 0 {
					t.Fatalf("第 %d 轮写者 %d 与 %d 同时成功，版本检查不是原子的", round, winner, i)
				}
				winner = i
			case errors.Is(e, store.ErrConflict):
				// 过期版本必须报冲突，交由上层让用户逐项确认，服务端不得自动选边。
			default:
				t.Fatalf("第 %d 轮写者 %d 返回了非冲突错误: %v", round, i, e)
			}
		}
		if winner < 0 {
			t.Fatalf("第 %d 轮没有任何写者成功：服务端拒绝了全部基于当前版本的写入", round)
		}

		final, _, err := pg.Pull(ctx, user, "", 0)
		if err != nil {
			t.Fatalf("第 %d 轮冲突后拉取失败: %v", round, err)
		}
		if len(final) != 1 {
			t.Fatalf("第 %d 轮应当只有 1 条记录，实际 %d 条", round, len(final))
		}
		got := final[0].Record
		if got.Version != saved[winner].Version {
			t.Fatalf("第 %d 轮服务端版本 %d，应当是胜者写入的 %d", round, got.Version, saved[winner].Version)
		}
		if !sameJSON(t, got.Payload, payloads[winner]) {
			t.Fatalf("第 %d 轮服务端内容 %s 不是胜者的 %s：冲突方覆盖了服务端数据", round, got.Payload, payloads[winner])
		}
		if got.Version <= base {
			t.Fatalf("第 %d 轮版本没有递增: %d -> %d", round, base, got.Version)
		}
		if final[0].Tombstone {
			t.Fatalf("第 %d 轮记录不应变成墓碑", round)
		}
	}
}

// TestIntegrationConcurrentServicePushReportsServerContent 验证在 syncsvc 层并发推送同一版本时，
// 只有一条 accepted，其余都是 conflict，且每条 conflict 都带回了服务端当前内容。
//
// 为什么存储层之外还要在服务层再测一次：真正的用户路径经过 syncsvc，冲突结算
// （读取服务端现状并回传）与存储层的版本检查是两段代码；只测存储层会漏掉
// "冲突结果缺内容"这类问题，而客户端拿不到服务端内容就没法让用户对比两版。
func TestIntegrationConcurrentServicePushReportsServerContent(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	user := prefix + "_u"
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	svc := &syncsvc.Service{Sync: pg, Exporter: pg}
	entityID := prefix + "_task"

	seed, err := svc.Push(ctx, user, []syncsvc.PushItem{{
		Type: store.EntityTask, ID: entityID, BaseVersion: 0,
		Payload: mustJSON(t, map[string]string{"title": "初版"}),
	}})
	if err != nil {
		t.Fatalf("写入初版失败: %v", err)
	}
	if len(seed) != 1 || seed[0].Outcome != syncsvc.OutcomeAccepted {
		t.Fatalf("初版应被接受，实际 %+v", seed)
	}

	const (
		pushers = 4
		rounds  = 6
	)
	for round := 0; round < rounds; round++ {
		cur, _, err := pg.Pull(ctx, user, "", 0)
		if err != nil {
			t.Fatalf("第 %d 轮读取当前版本失败: %v", round, err)
		}
		if len(cur) != 1 {
			t.Fatalf("第 %d 轮应当只有 1 条记录，实际 %d 条", round, len(cur))
		}
		base := cur[0].Record.Version

		payloads := make([][]byte, pushers)
		for i := 0; i < pushers; i++ {
			payloads[i] = mustJSON(t, map[string]any{"round": round, "pusher": i})
		}
		results := make([][]syncsvc.PushResult, pushers)
		errs := make([]error, pushers)

		start := make(chan struct{})
		var wg sync.WaitGroup
		for i := 0; i < pushers; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				results[i], errs[i] = svc.Push(ctx, user, []syncsvc.PushItem{{
					Type: store.EntityTask, ID: entityID, BaseVersion: base, Payload: payloads[i],
				}})
			}(i)
		}
		close(start)
		wg.Wait()

		accepted, conflicts, winner := 0, 0, -1
		for i := 0; i < pushers; i++ {
			if errs[i] != nil {
				t.Fatalf("第 %d 轮第 %d 个推送返回错误: %v", round, i, errs[i])
			}
			if len(results[i]) != 1 {
				t.Fatalf("第 %d 轮第 %d 个推送应只有 1 条结算结果，实际 %d 条", round, i, len(results[i]))
			}
			switch results[i][0].Outcome {
			case syncsvc.OutcomeAccepted:
				if accepted > 0 {
					t.Fatalf("第 %d 轮有多个 accepted（写者 %d 与 %d）", round, winner, i)
				}
				accepted++
				winner = i
			case syncsvc.OutcomeConflict:
				conflicts++
			default:
				t.Fatalf("第 %d 轮第 %d 个推送结算为 %s（%s），应只有 accepted/conflict",
					round, i, results[i][0].Outcome, results[i][0].Reason)
			}
		}
		if accepted != 1 || conflicts != pushers-1 {
			t.Fatalf("第 %d 轮应恰好 1 条 accepted、%d 条 conflict，实际 accepted=%d conflicts=%d",
				round, pushers-1, accepted, conflicts)
		}

		final, _, err := pg.Pull(ctx, user, "", 0)
		if err != nil {
			t.Fatalf("第 %d 轮拉取服务端现状失败: %v", round, err)
		}
		serverRec := final[0].Record
		if serverRec.Version != results[winner][0].Version {
			t.Fatalf("第 %d 轮服务端版本 %d，应为 accepted 的 %d", round, serverRec.Version, results[winner][0].Version)
		}
		if !sameJSON(t, serverRec.Payload, payloads[winner]) {
			t.Fatalf("第 %d 轮服务端内容被冲突方覆盖: %s，应为 %s", round, serverRec.Payload, payloads[winner])
		}
		for i := 0; i < pushers; i++ {
			if i == winner {
				continue
			}
			r := results[i][0]
			if r.ServerVersion != serverRec.Version {
				t.Fatalf("第 %d 轮冲突结果的服务端版本为 %d，应为 %d", round, r.ServerVersion, serverRec.Version)
			}
			if len(r.ServerPayload) == 0 {
				t.Fatalf("第 %d 轮冲突结果没有带回服务端内容，客户端无法对比两版", round)
			}
			if !sameJSON(t, r.ServerPayload, serverRec.Payload) {
				t.Fatalf("第 %d 轮冲突带回的内容 %s 不是服务端当前内容 %s", round, r.ServerPayload, serverRec.Payload)
			}
			if r.ServerDeleted {
				t.Fatalf("第 %d 轮记录并未删除，ServerDeleted 不应为 true", round)
			}
		}
	}
}

// TestIntegrationConcurrentDeleteAndStaleUpdateNoResurrect 验证"删除写墓碑"与
// "拿旧版本更新"并发时，数据不会被复活。
//
// 不变式（每一轮都检查）：
//   - 同一 Version 上恰好一方成功；
//   - 若删除成功，最终必须是墓碑，且旧更新已冲突 —— 否则就是被复活；
//   - 若更新成功，删除必须冲突，且最终是更新后的活记录。
//
// 竞态调度无法保证"删除获胜"这一分支每轮都出现，所以最后再补一个确定性场景：
// 删除已提交后，并发发出的旧版本更新必须全部冲突，最终仍是墓碑。
func TestIntegrationConcurrentDeleteAndStaleUpdateNoResurrect(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	user := prefix + "_u"
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	entityID := prefix + "_task"
	if _, err := pg.Push(ctx, store.Record{
		UserID: user, Type: store.EntityTask, ID: entityID,
		Payload: mustJSON(t, map[string]string{"title": "初版"}),
	}, 0); err != nil {
		t.Fatalf("写入初版失败: %v", err)
	}

	const rounds = 12
	deleteWins := 0
	for round := 0; round < rounds; round++ {
		cur, _, err := pg.Pull(ctx, user, "", 0)
		if err != nil {
			t.Fatalf("第 %d 轮读取当前状态失败: %v", round, err)
		}
		if len(cur) != 1 {
			t.Fatalf("第 %d 轮应当只有 1 条记录，实际 %d 条", round, len(cur))
		}
		// 上一轮可能被删掉。这里用当前版本显式恢复，让本轮从"活记录"开始；
		// 这正是客户端"从回收站恢复"的合法路径，不是绕过版本检查。
		if cur[0].Tombstone {
			if _, err := pg.Push(ctx, store.Record{
				UserID: user, Type: store.EntityTask, ID: entityID,
				Payload: mustJSON(t, map[string]string{"restored": "true"}),
			}, cur[0].Record.Version); err != nil {
				t.Fatalf("第 %d 轮恢复记录失败: %v", round, err)
			}
			if cur, _, err = pg.Pull(ctx, user, "", 0); err != nil {
				t.Fatalf("第 %d 轮恢复后重新读取失败: %v", round, err)
			}
		}
		base := cur[0].Record.Version

		deletedAt := time.Now().UTC()
		var (
			delErr, updErr error
			delRec, updRec store.Record
		)
		start := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			delRec, delErr = pg.Push(ctx, store.Record{
				UserID: user, Type: store.EntityTask, ID: entityID, DeletedAt: &deletedAt,
			}, base)
		}()
		go func() {
			defer wg.Done()
			<-start
			updRec, updErr = pg.Push(ctx, store.Record{
				UserID: user, Type: store.EntityTask, ID: entityID,
				Payload: mustJSON(t, map[string]any{"round": round, "revive": true}),
			}, base)
		}()
		close(start)
		wg.Wait()

		delOK, updOK := delErr == nil, updErr == nil
		if delOK == updOK {
			t.Fatalf("第 %d 轮应当恰好一方成功：delete ok=%v err=%v；update ok=%v err=%v",
				round, delOK, delErr, updOK, updErr)
		}
		if !delOK && !errors.Is(delErr, store.ErrConflict) {
			t.Fatalf("第 %d 轮删除失败必须是版本冲突，实际: %v", round, delErr)
		}
		if !updOK && !errors.Is(updErr, store.ErrConflict) {
			t.Fatalf("第 %d 轮更新失败必须是版本冲突，实际: %v", round, updErr)
		}

		final, _, err := pg.Pull(ctx, user, "", 0)
		if err != nil {
			t.Fatalf("第 %d 轮读取最终状态失败: %v", round, err)
		}
		got := final[0].Record
		if delOK {
			deleteWins++
			if !final[0].Tombstone {
				t.Fatalf("第 %d 轮删除已提交，最终却被旧更新复活: version=%d payload=%s", round, got.Version, got.Payload)
			}
			if got.Version != delRec.Version {
				t.Fatalf("第 %d 轮墓碑版本为 %d，应为删除写入的 %d", round, got.Version, delRec.Version)
			}
		} else {
			if final[0].Tombstone {
				t.Fatalf("第 %d 轮更新已提交，最终却成了墓碑", round)
			}
			if got.Version != updRec.Version {
				t.Fatalf("第 %d 轮服务端版本为 %d，应为更新写入的 %d", round, got.Version, updRec.Version)
			}
		}
	}
	t.Logf("并发删除轮次中删除获胜 %d/%d 次（调度未保证两边都出现，故下面另做确定性补测）", deleteWins, rounds)

	// 确定性补测：先让删除按正确版本提交，再由多个真实并发 goroutine 拿删除前的版本更新。
	cur, _, err := pg.Pull(ctx, user, "", 0)
	if err != nil {
		t.Fatalf("读取补测初始状态失败: %v", err)
	}
	if len(cur) != 1 {
		t.Fatalf("补测应当只有 1 条记录，实际 %d 条", len(cur))
	}
	if cur[0].Tombstone {
		if _, err := pg.Push(ctx, store.Record{
			UserID: user, Type: store.EntityTask, ID: entityID,
			Payload: mustJSON(t, map[string]string{"restored": "true"}),
		}, cur[0].Record.Version); err != nil {
			t.Fatalf("补测恢复记录失败: %v", err)
		}
		if cur, _, err = pg.Pull(ctx, user, "", 0); err != nil {
			t.Fatalf("补测恢复后读取失败: %v", err)
		}
	}
	staleBase := cur[0].Record.Version
	deletedStamp := time.Now().UTC()
	tomb, err := pg.Push(ctx, store.Record{
		UserID: user, Type: store.EntityTask, ID: entityID,
		DeletedAt: &deletedStamp,
	}, staleBase)
	if err != nil {
		t.Fatalf("补测写入删除墓碑失败: %v", err)
	}

	const staleWriters = 3
	staleErrs := make([]error, staleWriters)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < staleWriters; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, staleErrs[i] = pg.Push(ctx, store.Record{
				UserID: user, Type: store.EntityTask, ID: entityID,
				Payload: mustJSON(t, map[string]any{"stale": i}),
			}, staleBase)
		}(i)
	}
	close(start)
	wg.Wait()
	for i, e := range staleErrs {
		if !errors.Is(e, store.ErrConflict) {
			t.Fatalf("删除已提交后，拿旧版本(%d)更新必须冲突，实际第 %d 个: %v", staleBase, i, e)
		}
	}
	final, _, err := pg.Pull(ctx, user, "", 0)
	if err != nil {
		t.Fatalf("补测读取最终状态失败: %v", err)
	}
	if !final[0].Tombstone {
		t.Fatalf("删除已提交后数据被旧版本更新复活: %+v", final[0].Record)
	}
	if final[0].Record.Version != tomb.Version {
		t.Fatalf("补测最终版本为 %d，应为墓碑的 %d", final[0].Record.Version, tomb.Version)
	}
}
