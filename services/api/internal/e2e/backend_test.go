// Package e2e 在**服务层**做跨模块集成测试：认证 + 同步 + 媒体 + 主动规则组合在一起，
// 走一遍用户真实会走的路径。
//
// 为什么要有这一层：各模块单测全绿，并不代表它们拼起来是对的。
// 例如"删除必须清派生索引""多设备同步不能复活已删数据"这类性质，
// 只有在多个模块一起动的时候才看得出来。
//
// 这里刻意**不起 HTTP 服务**（那属于 internal/api 的职责），
// 直接用内存实现串起来，因此不依赖数据库、不依赖网络，能在任意机器上跑。
package e2e

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/authn"
	"github.com/jolaaa999/DayCue/services/api/internal/media"
	"github.com/jolaaa999/DayCue/services/api/internal/proactive"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

var (
	base = time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)
	sh   = mustLoc("Asia/Shanghai")
)

func mustLoc(n string) *time.Location {
	l, err := time.LoadLocation(n)
	if err != nil {
		panic(err)
	}
	return l
}

func fixed() time.Time { return base }

type backend struct {
	store *store.Memory
	sync  *syncsvc.Service
	media *media.FS
}

func newBackend(t *testing.T) *backend {
	t.Helper()
	mem := store.NewMemory(fixed)
	ms, err := media.NewFS(t.TempDir(), media.NewMemoryCatalog(), 1<<20, fixed)
	if err != nil {
		t.Fatalf("构造媒体存储失败: %v", err)
	}
	return &backend{
		store: mem,
		sync:  &syncsvc.Service{Sync: mem, Exporter: mem, Now: fixed},
		media: ms,
	}
}

// register 模拟注册：建用户、生成口令哈希、签发令牌。
func (b *backend) register(t *testing.T, email, password string) (userID, token string) {
	t.Helper()
	hash, err := authn.HashPassword(password)
	if err != nil {
		t.Fatalf("口令哈希失败: %v", err)
	}
	u := store.User{
		ID: "u_" + strings.ReplaceAll(email, "@", "_"), Email: email,
		PasswordHash: hash, CreatedAt: base, UpdatedAt: base,
	}
	if err := b.store.CreateUser(context.Background(), u); err != nil {
		t.Fatalf("建用户失败: %v", err)
	}
	iss, err := authn.NewIssuer(strings.Repeat("k", 32), fixed)
	if err != nil {
		t.Fatalf("构造签发器失败: %v", err)
	}
	tok, err := iss.Issue(u.ID, time.Hour)
	if err != nil {
		t.Fatalf("签发令牌失败: %v", err)
	}
	return u.ID, tok
}

func TestRegisterThenAuthenticate(t *testing.T) {
	b := newBackend(t)
	uid, tok := b.register(t, "a@example.com", "正确口令")

	iss, _ := authn.NewIssuer(strings.Repeat("k", 32), fixed)
	got, err := iss.Verify(tok)
	if err != nil {
		t.Fatalf("令牌应有效: %v", err)
	}
	if got != uid {
		t.Fatalf("令牌里的 userID 应为 %s，实际 %s", uid, got)
	}

	// 口令校验必须能通过，且错误口令必须被拒。
	u, err := b.store.UserByID(context.Background(), uid)
	if err != nil {
		t.Fatalf("读用户失败: %v", err)
	}
	if err := authn.VerifyPassword(u.PasswordHash, "正确口令"); err != nil {
		t.Fatalf("正确口令应通过: %v", err)
	}
	if err := authn.VerifyPassword(u.PasswordHash, "错误口令"); !errors.Is(err, authn.ErrInvalidCredentials) {
		t.Fatalf("错误口令应被拒，实际 %v", err)
	}
}

// TestTwoDevicesSyncAndDeletionPropagates 是本文件最重要的用例：
// 两台设备，一台离线，另一台删了数据；离线那台上线后必须学到"它被删了"，
// 而不能把已删数据当成自己的新改动又推回服务端。
func TestTwoDevicesSyncAndDeletionPropagates(t *testing.T) {
	b := newBackend(t)
	uid, _ := b.register(t, "a@example.com", "pw")
	ctx := context.Background()

	// 设备 A 第一次上线：推两条任务。
	res, err := b.sync.Push(ctx, uid, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "t1", Payload: []byte(`{"title":"交作业"}`), UpdatedAt: base},
		{Type: store.EntityTask, ID: "t2", Payload: []byte(`{"title":"买牛奶"}`), UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("设备 A 推送失败: %v", err)
	}
	for i, r := range res {
		if r.Outcome != syncsvc.OutcomeAccepted {
			t.Fatalf("第 %d 条应被接受，实际 %+v", i, r)
		}
	}

	// 设备 B 上线，拉到全部数据，并记住游标（此后它"离线"了）。
	snap, err := b.sync.Pull(ctx, uid, "", 100)
	if err != nil {
		t.Fatalf("设备 B 拉取失败: %v", err)
	}
	if len(snap.Changes) != 2 {
		t.Fatalf("设备 B 应看到 2 条，实际 %d", len(snap.Changes))
	}
	offlineCursor := snap.Cursor

	// 设备 B 离线期间，设备 A 删除了 t1。
	t1Version := int64(0)
	for _, c := range snap.Changes {
		if c.Record.ID == "t1" {
			t1Version = c.Record.Version
		}
	}
	if _, err := b.sync.Push(ctx, uid, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: t1Version, Deleted: true, UpdatedAt: base.Add(time.Hour)},
	}); err != nil {
		t.Fatalf("设备 A 删除失败: %v", err)
	}

	// 设备 B 带着旧游标上线：必须拿到 t1 的墓碑，而不是"什么都没有"。
	incremental, err := b.sync.Pull(ctx, uid, offlineCursor, 100)
	if err != nil {
		t.Fatalf("设备 B 增量拉取失败: %v", err)
	}
	if len(incremental.Changes) != 1 {
		t.Fatalf("设备 B 应看到 1 条变更，实际 %d", len(incremental.Changes))
	}
	got := incremental.Changes[0]
	if !got.Tombstone || got.Record.ID != "t1" {
		t.Fatalf("设备 B 应学到 t1 已被删除，实际 %+v", got)
	}
	// 墓碑不能带内容，否则"删了却还留着正文"。
	if len(got.Record.Payload) != 0 {
		t.Fatalf("墓碑不应携带内容，实际 %s", got.Record.Payload)
	}
}

// TestDeletePropagationBeatsStaleReplay 覆盖离线队列最容易出的错：
// 离线设备在不知情的情况下重放一条"基于旧版本的普通修改"，
// 不能把已经被删除的记录复活。
func TestDeletePropagationBeatsStaleReplay(t *testing.T) {
	b := newBackend(t)
	uid, _ := b.register(t, "a@example.com", "pw")
	ctx := context.Background()

	first, _ := b.sync.Push(ctx, uid, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "t1", Payload: []byte("v1"), UpdatedAt: base},
	})
	staleVersion := first[0].Version

	// 服务端把 t1 删了。
	if _, err := b.sync.Push(ctx, uid, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: staleVersion, Deleted: true, UpdatedAt: base.Add(time.Hour)},
	}); err != nil {
		t.Fatalf("删除失败: %v", err)
	}

	// 离线设备重放旧版本的修改：必须冲突，不能复活。
	res, err := b.sync.Push(ctx, uid, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "t1", BaseVersion: staleVersion, Payload: []byte("stale-edit"), UpdatedAt: base},
	})
	if err != nil {
		t.Fatalf("重放失败: %v", err)
	}
	// 内存实现采用"当前状态 + 单调版本"，删除后版本继续前进，
	// 因此旧版本推送必然冲突。
	if res[0].Outcome != syncsvc.OutcomeConflict {
		t.Fatalf("基于已删除版本的修改必须冲突，实际 %+v", res[0])
	}

	// 而且服务端状态仍然是"已删除"，没被复活。
	after, _ := b.sync.Pull(ctx, uid, "", 100)
	for _, c := range after.Changes {
		if c.Record.ID == "t1" && !c.Tombstone {
			t.Fatalf("t1 被旧版本重放复活了: %+v", c)
		}
	}
}

// TestUserIsolationAcrossModules 确认隔离不是"某个模块记得过滤"，而是处处成立。
func TestUserIsolationAcrossModules(t *testing.T) {
	b := newBackend(t)
	alice, _ := b.register(t, "alice@example.com", "pw")
	bob, _ := b.register(t, "bob@example.com", "pw")
	ctx := context.Background()

	if _, err := b.sync.Push(ctx, alice, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "secret", Payload: []byte("alice 的私事"), UpdatedAt: base},
	}); err != nil {
		t.Fatalf("alice 推送失败: %v", err)
	}

	// Bob 拉取时绝不能看到 alice 的数据。
	bobPull, err := b.sync.Pull(ctx, bob, "", 100)
	if err != nil {
		t.Fatalf("bob 拉取失败: %v", err)
	}
	if len(bobPull.Changes) != 0 {
		t.Fatalf("bob 不应看到任何数据，实际 %+v", bobPull.Changes)
	}

	// 媒体同理。
	obj, err := b.media.Put(ctx, alice, "capture", "c1", "image/png", strings.NewReader("alice 的照片"))
	if err != nil {
		t.Fatalf("alice 上传失败: %v", err)
	}
	if _, _, err := b.media.Open(ctx, bob, obj.ID); !errors.Is(err, media.ErrNotFound) {
		t.Fatalf("bob 不应读到 alice 的媒体，实际 %v", err)
	}
}

// TestMediaCascadeOnRecordDeletion 覆盖隐私要求：删记录必须连媒体一起删。
func TestMediaCascadeOnRecordDeletion(t *testing.T) {
	b := newBackend(t)
	uid, _ := b.register(t, "a@example.com", "pw")
	ctx := context.Background()

	o1, _ := b.media.Put(ctx, uid, "capture", "cap-1", "image/png", bytes.NewReader([]byte("照片")))
	o2, _ := b.media.Put(ctx, uid, "capture", "cap-1", "audio/m4a", bytes.NewReader([]byte("录音")))
	other, _ := b.media.Put(ctx, uid, "capture", "cap-2", "image/png", bytes.NewReader([]byte("另一张")))

	if err := b.media.DeleteByOwner(ctx, uid, "capture", "cap-1"); err != nil {
		t.Fatalf("级联删除失败: %v", err)
	}
	for _, id := range []string{o1.ID, o2.ID} {
		if _, _, err := b.media.Open(ctx, uid, id); !errors.Is(err, media.ErrNotFound) {
			t.Errorf("对象 %s 应已随记录删除，实际 %v", id, err)
		}
	}
	rc, _, err := b.media.Open(ctx, uid, other.ID)
	if err != nil {
		t.Fatalf("其它记录不应被牵连: %v", err)
	}
	rc.Close()
}

// TestExportThenPurge 覆盖"数据可导出、账号可删除"这条合规路径。
func TestExportThenPurge(t *testing.T) {
	b := newBackend(t)
	uid, _ := b.register(t, "a@example.com", "pw")
	ctx := context.Background()

	if _, err := b.sync.Push(ctx, uid, []syncsvc.PushItem{
		{Type: store.EntityTask, ID: "t1", Payload: []byte("任务"), UpdatedAt: base},
		{Type: store.EntityNote, ID: "n1", Payload: []byte("笔记"), UpdatedAt: base},
	}); err != nil {
		t.Fatalf("推送失败: %v", err)
	}
	if _, err := b.media.Put(ctx, uid, "note", "n1", "image/png", strings.NewReader("图")); err != nil {
		t.Fatalf("上传失败: %v", err)
	}

	exported, err := b.sync.Export(ctx, uid)
	if err != nil {
		t.Fatalf("导出失败: %v", err)
	}
	if len(exported.Records) != 2 {
		t.Fatalf("导出应含 2 条，实际 %d", len(exported.Records))
	}

	if err := b.sync.Purge(ctx, uid); err != nil {
		t.Fatalf("清除失败: %v", err)
	}
	after, err := b.sync.Export(ctx, uid)
	if err != nil {
		t.Fatalf("清除后导出失败: %v", err)
	}
	if len(after.Records) != 0 {
		t.Fatalf("清除后不应还有数据，实际 %d", len(after.Records))
	}
}

// TestProactiveBudgetAcrossSyncBackedDay 把主动规则判定与用户时区连起来：
// 跨零点必须重置预算，静默时段必须推迟而不是丢弃。
func TestProactiveBudgetAcrossSyncBackedDay(t *testing.T) {
	p := proactive.DefaultPolicy()

	// 上海 10-12 23:50：已经在静默时段内。
	late := time.Date(2026, 10, 12, 23, 50, 0, 0, sh)
	d := proactive.Decide(p, proactive.Candidate{ScheduledAt: late.Add(-time.Minute)}, proactive.History{}, late, sh)
	if !d.Deferred || d.Reason != proactive.ReasonQuietDeferred {
		t.Fatalf("深夜应推迟，实际 %+v", d)
	}

	// 次日 09:00：新的一天，预算重置，可以发。
	next := time.Date(2026, 10, 13, 9, 0, 0, 0, sh)
	if proactive.DayKey(late, sh) == proactive.DayKey(next, sh) {
		t.Fatal("跨零点后日键必须变化")
	}
	d = proactive.Decide(p, proactive.Candidate{ScheduledAt: next.Add(-time.Minute)}, proactive.History{}, next, sh)
	if !d.Send {
		t.Fatalf("新的一天应能发送，实际 %+v", d)
	}
}

// TestDeletedUserCannotSync 确认软删除用户之后不能再读写。
func TestDeletedUserCannotSync(t *testing.T) {
	b := newBackend(t)
	uid, _ := b.register(t, "a@example.com", "pw")
	ctx := context.Background()

	if err := b.store.SoftDeleteUser(ctx, uid, base.Add(time.Hour)); err != nil {
		t.Fatalf("删除用户失败: %v", err)
	}
	if _, err := b.store.UserByID(ctx, uid); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("已删除用户应查不到，实际 %v", err)
	}
	// 拉取不应报错，但也不应返回任何内容。
	got, err := b.sync.Pull(ctx, uid, "", 100)
	if err != nil {
		t.Fatalf("拉取失败: %v", err)
	}
	if len(got.Changes) != 0 {
		t.Fatalf("已删除用户不应有数据，实际 %d", len(got.Changes))
	}
}

var _ = io.Discard
