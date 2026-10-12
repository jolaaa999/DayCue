package syncsvc

import (
	"context"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

var base = time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)

func newSvc(t *testing.T) (*Service, *store.Memory) {
	t.Helper()
	mem := store.NewMemory(func() time.Time { return base })
	if err := mem.CreateUser(context.Background(), store.User{
		ID: "u1", Email: "a@example.com", CreatedAt: base, UpdatedAt: base,
	}); err != nil {
		t.Fatalf("建用户失败: %v", err)
	}
	return &Service{Sync: mem, Exporter: mem, Now: func() time.Time { return base }}, mem
}

func TestPushAndPullRoundTrip(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()

	results, err := svc.Push(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "t1", Payload: []byte(`{"title":"交作业"}`), UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if len(results) != 1 || results[0].Outcome != OutcomeAccepted {
		t.Fatalf("应被接受，实际 %+v", results)
	}

	got, err := svc.Pull(ctx, "u1", "", 100)
	if err != nil {
		t.Fatalf("拉取失败: %v", err)
	}
	if len(got.Changes) != 1 || got.Changes[0].Record.ID != "t1" {
		t.Fatalf("应拉回 1 条，实际 %+v", got.Changes)
	}
	if got.Cursor == "" {
		t.Fatal("拉取后应给出游标")
	}
}

func TestResultsArePositionallyAlignedWithInput(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()

	// 第一条正常，第二条缺 ID，第三条正常。结果必须严格同序，
	// 否则客户端会把第二、三条的结果对错位置。
	results, err := svc.Push(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "ok1", UpdatedAt: base},
		{Type: store.EntityTask, ID: "", UpdatedAt: base},
		{Type: store.EntityNote, ID: "ok2", UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("结果数应与输入一致，实际 %d", len(results))
	}
	if results[0].Outcome != OutcomeAccepted || results[0].ID != "ok1" {
		t.Errorf("第 0 条应是 ok1 被接受，实际 %+v", results[0])
	}
	if results[1].Outcome != OutcomeRejected {
		t.Errorf("第 1 条应被拒绝，实际 %+v", results[1])
	}
	if results[2].Outcome != OutcomeAccepted || results[2].ID != "ok2" {
		t.Errorf("第 2 条应是 ok2 被接受，实际 %+v", results[2])
	}
}

func TestConflictDoesNotBlockOtherItems(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()

	first, _ := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: "t1", UpdatedAt: base}})
	v := first[0].Version

	// 先正常改一次，让服务端版本前进。
	if _, err := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: "t1", BaseVersion: v, Payload: []byte("v2"), UpdatedAt: base}}); err != nil {
		t.Fatalf("第二次推送失败: %v", err)
	}

	// 再拿已经过期的版本推一次：应报冲突，但同批的其它条目仍要落库。
	results, err := svc.Push(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: v, Payload: []byte("stale"), UpdatedAt: base},
		{Type: store.EntityTask, ID: "t2", UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if results[0].Outcome != OutcomeConflict {
		t.Fatalf("第一条应冲突，实际 %+v", results[0])
	}
	if results[0].Reason == "" {
		t.Error("冲突必须给出中文原因，供界面展示")
	}
	if results[1].Outcome != OutcomeAccepted {
		t.Fatalf("第二条不应被第一条冲突连累，实际 %+v", results[1])
	}
}

func TestConflictCarriesServerVersionForUserDecision(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()

	first, _ := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: "t1", UpdatedAt: base}})
	results, _, err := svc.PushAndCollectConflicts(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: first[0].Version + 99, UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if results[0].Outcome != OutcomeConflict {
		t.Fatalf("应冲突，实际 %+v", results[0])
	}
	if results[0].ServerVersion == 0 {
		t.Fatal("冲突必须带上服务端版本，否则界面无法让用户比较")
	}
}

func TestCollectConflictsSeparatesThemFromSuccesses(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()
	first, _ := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: "t1", UpdatedAt: base}})

	_, conflicts, err := svc.PushAndCollectConflicts(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: first[0].Version + 5, UpdatedAt: base},
		{Type: store.EntityTask, ID: "t2", UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if len(conflicts) != 1 {
		t.Fatalf("应摘出 1 条冲突，实际 %d", len(conflicts))
	}
	if conflicts[0].ID != "t1" {
		t.Fatalf("冲突应是 t1，实际 %s", conflicts[0].ID)
	}
}

func TestDeleteWritesTombstoneAndClearsPayload(t *testing.T) {
	svc, mem := newSvc(t)
	ctx := context.Background()

	first, _ := svc.Push(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "t1", Payload: []byte(`{"title":"秘密"}`), UpdatedAt: base},
	})
	if _, err := svc.Push(ctx, "u1", []PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: first[0].Version, Deleted: true, UpdatedAt: base.Add(time.Minute)},
	}); err != nil {
		t.Fatalf("删除推送失败: %v", err)
	}

	got, err := svc.Pull(ctx, "u1", "", 100)
	if err != nil {
		t.Fatalf("拉取失败: %v", err)
	}
	if len(got.Changes) != 1 || !got.Changes[0].Tombstone {
		t.Fatalf("应拉到一条墓碑，实际 %+v", got.Changes)
	}
	// 墓碑里不能残留正文，否则等于删了却还留着内容。
	if len(got.Changes[0].Record.Payload) != 0 {
		t.Fatalf("墓碑不应带内容，实际 %s", got.Changes[0].Record.Payload)
	}

	// 导出也要体现删除。
	b, err := svc.Export(ctx, "u1")
	if err != nil {
		t.Fatalf("导出失败: %v", err)
	}
	if len(b.Records) != 1 || !b.Records[0].Deleted() {
		t.Fatalf("导出应含 1 条墓碑，实际 %+v", b.Records)
	}
	_ = mem
}

func TestPullPaginationReportsHasMore(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()
	for _, id := range []string{"t1", "t2", "t3", "t4", "t5"} {
		if _, err := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: id, UpdatedAt: base}}); err != nil {
			t.Fatalf("推送 %s 失败: %v", id, err)
		}
	}

	page, err := svc.Pull(ctx, "u1", "", 2)
	if err != nil {
		t.Fatalf("拉取失败: %v", err)
	}
	if len(page.Changes) != 2 {
		t.Fatalf("每页应为 2 条，实际 %d", len(page.Changes))
	}
	if !page.HasMore {
		t.Fatal("还有数据时必须标记 HasMore，否则客户端会以为同步完了")
	}

	// 一路拉到底，最终 HasMore 必须为 false。
	cursor := page.Cursor
	seen := len(page.Changes)
	for i := 0; i < 10; i++ {
		p, err := svc.Pull(ctx, "u1", cursor, 2)
		if err != nil {
			t.Fatalf("拉取失败: %v", err)
		}
		seen += len(p.Changes)
		cursor = p.Cursor
		if !p.HasMore {
			break
		}
	}
	if seen != 5 {
		t.Fatalf("应恰好拉到 5 条，实际 %d", seen)
	}
}

func TestExportOrderIsStable(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()
	for _, id := range []string{"z", "a", "m"} {
		if _, err := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: id, UpdatedAt: base}}); err != nil {
			t.Fatalf("推送失败: %v", err)
		}
	}
	b1, _ := svc.Export(ctx, "u1")
	b2, _ := svc.Export(ctx, "u1")
	if len(b1.Records) != len(b2.Records) {
		t.Fatal("两次导出条数应一致")
	}
	for i := range b1.Records {
		// 顺序不稳定会让用户以为数据变了，也会让备份无法做差异比对。
		if b1.Records[i].ID != b2.Records[i].ID {
			t.Fatalf("导出顺序不稳定: 第 %d 位 %s vs %s", i, b1.Records[i].ID, b2.Records[i].ID)
		}
	}
	if b1.Records[0].ID != "a" {
		t.Fatalf("导出应按 ID 排序，实际首位 %s", b1.Records[0].ID)
	}
}

func TestRejectEmptyUser(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()
	if _, err := svc.Push(ctx, "  ", []PushItem{{Type: store.EntityTask, ID: "t1"}}); err == nil {
		t.Fatal("空 userID 应被拒绝")
	}
	if _, err := svc.Pull(ctx, "", "", 10); err == nil {
		t.Fatal("空 userID 应被拒绝")
	}
	if _, err := svc.Export(ctx, ""); err == nil {
		t.Fatal("空 userID 应被拒绝")
	}
	if err := svc.Purge(ctx, ""); err == nil {
		t.Fatal("空 userID 应被拒绝")
	}
}

func TestPurgeRemovesUserData(t *testing.T) {
	svc, _ := newSvc(t)
	ctx := context.Background()
	if _, err := svc.Push(ctx, "u1", []PushItem{{Type: store.EntityTask, ID: "t1", UpdatedAt: base}}); err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("清除失败: %v", err)
	}
	b, err := svc.Export(ctx, "u1")
	if err != nil {
		t.Fatalf("导出失败: %v", err)
	}
	if len(b.Records) != 0 {
		t.Fatalf("清除后不应再有记录，实际 %d", len(b.Records))
	}
}
