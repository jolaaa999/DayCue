package store

import (
	"context"
	"testing"
	"time"
)

func fixedNow() time.Time {
	return time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)
}

func newTestStore(t *testing.T) *Memory {
	t.Helper()
	return NewMemory(fixedNow)
}

func seedUser(t *testing.T, m *Memory, id, email string) {
	t.Helper()
	now := fixedNow()
	err := m.CreateUser(context.Background(), User{
		ID: id, Email: email, DisplayName: id, CreatedAt: now, UpdatedAt: now,
	})
	if err != nil {
		t.Fatalf("建用户失败: %v", err)
	}
}

func TestUserIsolationOnSync(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")
	seedUser(t, m, "u2", "b@example.com")

	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow(), Payload: []byte("{}")}, 0); err != nil {
		t.Fatalf("u1 写入失败: %v", err)
	}

	// u2 绝不能看到 u1 的记录，这是多租户最基本的一条。
	changes, _, err := m.Pull(ctx, "u2", "", 100)
	if err != nil {
		t.Fatalf("u2 拉取失败: %v", err)
	}
	if len(changes) != 0 {
		t.Fatalf("u2 不应看到任何记录，实际 %d 条", len(changes))
	}

	changes, _, err = m.Pull(ctx, "u1", "", 100)
	if err != nil {
		t.Fatalf("u1 拉取失败: %v", err)
	}
	if len(changes) != 1 || changes[0].Record.ID != "t1" {
		t.Fatalf("u1 应看到自己的 1 条记录，实际 %+v", changes)
	}
}

func TestEmailUniquenessIsCaseInsensitive(t *testing.T) {
	m := newTestStore(t)
	seedUser(t, m, "u1", "Same@Example.com")
	err := m.CreateUser(context.Background(), User{ID: "u2", Email: "same@example.com"})
	if err == nil {
		t.Fatal("同一个邮箱不应允许建第二个账号")
	}
}

func TestPushVersionConflict(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")

	first, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow(), Payload: []byte("v1")}, 0)
	if err != nil {
		t.Fatalf("首次写入失败: %v", err)
	}

	// 用错误的基准版本再写一次：必须报冲突，不能悄悄覆盖。
	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow(), Payload: []byte("v2")}, first.Version+1); err != ErrConflict {
		t.Fatalf("版本不匹配应返回 ErrConflict，实际 %v", err)
	}

	// 用正确版本写则成功。
	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow(), Payload: []byte("v2")}, first.Version); err != nil {
		t.Fatalf("正确版本写入应成功，实际 %v", err)
	}
}

func TestPushNewOnExistingLiveRecordConflicts(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")
	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow()}, 0); err != nil {
		t.Fatalf("首次写入失败: %v", err)
	}
	// baseVersion=0 表示"我认为这是新增"，但服务端已有活记录 —— 认知分叉，必须报冲突。
	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow()}, 0); err != ErrConflict {
		t.Fatalf("重复新增应返回 ErrConflict，实际 %v", err)
	}
}

func TestTombstonePropagatesThroughPull(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")

	rec, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow(), Payload: []byte("{}")}, 0)
	if err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	// 模拟一个"已经拉到 v1"的客户端。
	_, clientCursor, err := m.Pull(ctx, "u1", "", 100)
	if err != nil {
		t.Fatalf("首次拉取失败: %v", err)
	}
	if clientCursor == "" {
		t.Fatal("首次拉取应给出游标")
	}

	deleted := fixedNow().Add(time.Hour)
	if _, err := m.Push(ctx, Record{
		UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: deleted, DeletedAt: &deleted,
	}, rec.Version); err != nil {
		t.Fatalf("写入墓碑失败: %v", err)
	}

	// 关键保证：**已同步过的客户端**必须能通过游标得知这条被删了。
	// 如果删除只是把行抹掉，这个客户端就永远不知道，本地会残留一条幽灵记录。
	delta, _, err := m.Pull(ctx, "u1", clientCursor, 100)
	if err != nil {
		t.Fatalf("增量拉取失败: %v", err)
	}
	if len(delta) != 1 {
		t.Fatalf("增量应恰好看到 1 条删除，实际 %d", len(delta))
	}
	if !delta[0].Tombstone || !delta[0].Record.Deleted() {
		t.Fatalf("增量里的这一条必须是墓碑，实际 %+v", delta[0])
	}

	// 全新客户端从空游标拉取，得到的是"当前快照"：只有那条墓碑。
	snapshot, _, err := m.Pull(ctx, "u1", "", 100)
	if err != nil {
		t.Fatalf("快照拉取失败: %v", err)
	}
	if len(snapshot) != 1 || !snapshot[0].Tombstone {
		t.Fatalf("空游标应得到含墓碑的当前快照，实际 %+v", snapshot)
	}
}

func TestDeleteOfNeverSyncedRecordIsStillVisibleToFreshClient(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")

	rec, _ := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow()}, 0)
	del := fixedNow().Add(time.Minute)
	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: del, DeletedAt: &del}, rec.Version); err != nil {
		t.Fatalf("写墓碑失败: %v", err)
	}

	// 从没同步过的新设备不该看到一条活任务。
	changes, _, err := m.Pull(ctx, "u1", "", 100)
	if err != nil {
		t.Fatalf("拉取失败: %v", err)
	}
	for _, c := range changes {
		if !c.Tombstone {
			t.Fatalf("新设备不应看到活记录，实际 %+v", c)
		}
	}
}

func TestPullCursorIsIncrementalAndRespectsLimit(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")

	for i, id := range []string{"t1", "t2", "t3"} {
		if _, err := m.Push(ctx, Record{
			UserID: "u1", Type: EntityTask, ID: id,
			UpdatedAt: fixedNow().Add(time.Duration(i) * time.Minute),
		}, 0); err != nil {
			t.Fatalf("写入 %s 失败: %v", id, err)
		}
	}

	page1, cursor, err := m.Pull(ctx, "u1", "", 2)
	if err != nil {
		t.Fatalf("第一页失败: %v", err)
	}
	if len(page1) != 2 || cursor == "" {
		t.Fatalf("第一页应为 2 条且有游标，实际 %d 条 游标=%q", len(page1), cursor)
	}

	page2, cursor2, err := m.Pull(ctx, "u1", cursor, 2)
	if err != nil {
		t.Fatalf("第二页失败: %v", err)
	}
	if len(page2) != 1 {
		t.Fatalf("第二页应为 1 条，实际 %d", len(page2))
	}
	if page2[0].Record.ID != "t3" {
		t.Fatalf("第二页应是 t3，实际 %s", page2[0].Record.ID)
	}
	if cursor2 == cursor {
		t.Fatal("游标必须前进")
	}

	// 游标到底之后再拉，应为空且不报错。
	page3, _, err := m.Pull(ctx, "u1", cursor2, 2)
	if err != nil {
		t.Fatalf("第三页失败: %v", err)
	}
	if len(page3) != 0 {
		t.Fatalf("追平后不应再有变更，实际 %d", len(page3))
	}
}

func TestPullRejectsBadCursor(t *testing.T) {
	m := newTestStore(t)
	seedUser(t, m, "u1", "a@example.com")
	// 非法游标必须报错，而不是被当成 0 从头重放（重放会掩盖客户端 bug）。
	if _, _, err := m.Pull(context.Background(), "u1", "not-a-number", 10); err == nil {
		t.Fatal("非法游标应报错")
	}
}

func TestDeleteMemoryClearsDerivedFields(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")

	if err := m.UpsertMemory(ctx, MemoryItem{
		ID: "m1", UserID: "u1", Category: "preference",
		Statement: "用户喜欢早上学习", Status: "confirmed",
		SourceKind: "user_setting", SourceRef: "设置页", CreatedAt: fixedNow(), UpdatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("写入记忆失败: %v", err)
	}

	if err := m.DeleteMemory(ctx, "u1", "m1", fixedNow()); err != nil {
		t.Fatalf("删除记忆失败: %v", err)
	}

	live, err := m.MemoriesByUser(ctx, "u1", false)
	if err != nil {
		t.Fatalf("查询失败: %v", err)
	}
	if len(live) != 0 {
		t.Fatalf("删除后不应出现在常规查询里，实际 %d 条", len(live))
	}

	// 派生内容（正文与来源）必须一并清空，否则等于删了行却留着内容。
	all, err := m.MemoriesByUser(ctx, "u1", true)
	if err != nil {
		t.Fatalf("查询失败: %v", err)
	}
	if len(all) != 1 {
		t.Fatalf("带墓碑查询应返回 1 条，实际 %d", len(all))
	}
	if all[0].Statement != "" || all[0].SourceRef != "" {
		t.Fatalf("删除必须清空派生内容，实际 statement=%q sourceRef=%q", all[0].Statement, all[0].SourceRef)
	}
}

func TestExportIncludesTombstones(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")

	rec, _ := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: fixedNow()}, 0)
	del := fixedNow().Add(time.Hour)
	if _, err := m.Push(ctx, Record{UserID: "u1", Type: EntityTask, ID: "t1", UpdatedAt: del, DeletedAt: &del}, rec.Version); err != nil {
		t.Fatalf("写墓碑失败: %v", err)
	}

	b, err := m.Export(ctx, "u1")
	if err != nil {
		t.Fatalf("导出失败: %v", err)
	}
	// 导出的是当前状态：这条记录只剩墓碑。墓碑必须在导出里，否则用户
	// 拿到备份后无法判断"这条到底是从没存在过，还是被自己删了"。
	if len(b.Records) != 1 {
		t.Fatalf("导出应含 1 条墓碑，实际 %d", len(b.Records))
	}
	if !b.Records[0].Deleted() {
		t.Fatalf("导出的这条必须是墓碑，实际 %+v", b.Records[0])
	}
}

func TestPurgeOnlyAffectsTargetUser(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")
	seedUser(t, m, "u2", "b@example.com")

	for _, uid := range []string{"u1", "u2"} {
		if _, err := m.Push(ctx, Record{UserID: uid, Type: EntityTask, ID: "t-" + uid, UpdatedAt: fixedNow()}, 0); err != nil {
			t.Fatalf("写入 %s 失败: %v", uid, err)
		}
		if err := m.UpsertMemory(ctx, MemoryItem{ID: "m-" + uid, UserID: uid, Statement: "x", CreatedAt: fixedNow(), UpdatedAt: fixedNow()}); err != nil {
			t.Fatalf("写记忆 %s 失败: %v", uid, err)
		}
	}

	if err := m.Purge(ctx, "u1"); err != nil {
		t.Fatalf("清除失败: %v", err)
	}

	// u1 的所有内容必须消失。
	if changes, _, _ := m.Pull(ctx, "u1", "", 100); len(changes) != 0 {
		t.Fatalf("u1 应被清空，实际剩 %d 条", len(changes))
	}
	if mems, _ := m.MemoriesByUser(ctx, "u1", true); len(mems) != 0 {
		t.Fatalf("u1 的记忆应被清空，实际剩 %d 条", len(mems))
	}
	// u2 必须毫发无损 —— 越权删除是最严重的一类缺陷。
	if changes, _, _ := m.Pull(ctx, "u2", "", 100); len(changes) != 1 {
		t.Fatalf("u2 不应受影响，实际剩 %d 条", len(changes))
	}
	if mems, _ := m.MemoriesByUser(ctx, "u2", true); len(mems) != 1 {
		t.Fatalf("u2 的记忆不应受影响，实际剩 %d 条", len(mems))
	}
}

func TestDeviceRequiresExistingUser(t *testing.T) {
	m := newTestStore(t)
	err := m.UpsertDevice(context.Background(), Device{ID: "d1", UserID: "ghost"})
	if err != ErrNotFound {
		t.Fatalf("给不存在的用户建设备应返回 ErrNotFound，实际 %v", err)
	}
}

func TestSoftDeletedUserIsInvisible(t *testing.T) {
	m := newTestStore(t)
	ctx := context.Background()
	seedUser(t, m, "u1", "a@example.com")
	if err := m.SoftDeleteUser(ctx, "u1", fixedNow()); err != nil {
		t.Fatalf("软删除失败: %v", err)
	}
	if _, err := m.UserByID(ctx, "u1"); err != ErrNotFound {
		t.Fatalf("已删除用户应不可见，实际 %v", err)
	}
	if _, err := m.UserByEmail(ctx, "a@example.com"); err != ErrNotFound {
		t.Fatalf("已删除用户的邮箱应可再次注册，实际 %v", err)
	}
}
