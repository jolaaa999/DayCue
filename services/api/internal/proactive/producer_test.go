package proactive

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// 全部用替身，不碰数据库：这一层要证明的是「什么该变成候选、什么不该、会不会重复」，
// 与存储实现无关。存储的过滤条件由 store 包自己的测试负责。

var produceNow = time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)

type fakeSource struct {
	events []DueEvent
	err    error
	// 记录最后一次收到的窗口，用于验证回溯窗口真的传下去了。
	lastFrom  time.Time
	lastTo    time.Time
	lastLimit int
}

func (f *fakeSource) DueEvents(_ context.Context, from, to time.Time, limit int) ([]DueEvent, error) {
	f.lastFrom, f.lastTo, f.lastLimit = from, to, limit
	if f.err != nil {
		return nil, f.err
	}
	return f.events, nil
}

type fakeSink struct {
	got  []OutgoingCandidate
	fail map[string]error
}

func (f *fakeSink) Enqueue(_ context.Context, c OutgoingCandidate) error {
	if err, ok := f.fail[c.DedupeKey]; ok {
		return err
	}
	f.got = append(f.got, c)
	return nil
}

func (f *fakeSink) keys() []string {
	out := make([]string, 0, len(f.got))
	for _, c := range f.got {
		out = append(out, c.DedupeKey)
	}
	return out
}

type fakeOwner struct {
	owned map[string]bool
	err   map[string]error
	calls []string
}

func (f *fakeOwner) ClientOwnsDelivery(_ context.Context, userID string, _ time.Time) (bool, string, error) {
	f.calls = append(f.calls, userID)
	if err, ok := f.err[userID]; ok {
		return false, "", err
	}
	if f.owned[userID] {
		return true, "该用户有近期活跃且能自己投递的设备", nil
	}
	return false, "该用户没有能自己投递的设备，服务端接管", nil
}

func newProducer(src CandidateSource, sink EnqueueSink, owner RouteOwner) *Producer {
	return &Producer{
		Source: src,
		Sink:   sink,
		Owner:  owner,
		Now:    func() time.Time { return produceNow },
	}
}

func reminderEvent(userID, taskID, title string) DueEvent {
	return DueEvent{
		UserID:     userID,
		Kind:       KindReminder,
		Ref:        taskID,
		Title:      title,
		DeepLink:   "daycue://task/" + taskID,
		OccurredAt: produceNow.Add(-5 * time.Minute),
	}
}

func TestProducerEnqueuesWhenClientCannotDeliver(t *testing.T) {
	src := &fakeSource{events: []DueEvent{reminderEvent("u1", "t1", "交操作系统作业")}}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{"u1": false}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if rep.Enqueued != 1 || len(sink.got) != 1 {
		t.Fatalf("应当入队一条，实际 Enqueued=%d got=%d", rep.Enqueued, len(sink.got))
	}
	got := sink.got[0]
	if got.DedupeKey != "reminder:t1" {
		t.Fatalf("去重键应为稳定业务键，实际 %q", got.DedupeKey)
	}
	if got.TargetRef != "t1" {
		t.Fatalf("冷却键应等于业务对象 id，实际 %q", got.TargetRef)
	}
	if got.Title != "交操作系统作业" {
		t.Fatalf("标题应原样带过去，实际 %q", got.Title)
	}
	if got.ExpiresAt == nil || !got.ExpiresAt.Equal(produceNow.Add(-5*time.Minute).Add(DefaultLookback)) {
		t.Fatalf("过期时刻应为业务时刻加回溯窗口，实际 %v", got.ExpiresAt)
	}
}

func TestProducerYieldsWhenClientOwnsDelivery(t *testing.T) {
	src := &fakeSource{events: []DueEvent{reminderEvent("u1", "t1", "交作业")}}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{"u1": true}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	// 这一条是「同一提醒不得两边同时安排」的直接断言：客户端会投递时服务端一条都不许入队。
	if rep.Enqueued != 0 || len(sink.got) != 0 {
		t.Fatalf("客户端自己会投递时服务端不该入队，实际 Enqueued=%d", rep.Enqueued)
	}
	if rep.ClientOwned != 1 {
		t.Fatalf("应当记一条让路，实际 %d", rep.ClientOwned)
	}
}

func TestProducerDoesNotRepeatAcrossPolls(t *testing.T) {
	src := &fakeSource{events: []DueEvent{reminderEvent("u1", "t1", "交作业")}}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{"u1": false}}
	p := newProducer(src, sink, owner)

	for i := 0; i < 5; i++ {
		if _, err := p.ProduceOnce(context.Background()); err != nil {
			t.Fatalf("第 %d 轮报错: %v", i, err)
		}
	}
	// 每轮都会调用 Enqueue（去重由账本的幂等保证），但键必须完全一样；
	// 只要键里掺了时间，这里就会变成 5 个不同的键，用户会被重复打扰。
	if len(sink.got) != 5 {
		t.Fatalf("五轮应当各调用一次入队，实际 %d", len(sink.got))
	}
	for _, k := range sink.keys() {
		if k != "reminder:t1" {
			t.Fatalf("去重键跨轮必须稳定，实际出现 %q", k)
		}
	}
}

func TestProducerRejectsEmptyTitle(t *testing.T) {
	src := &fakeSource{events: []DueEvent{reminderEvent("u1", "t1", "   ")}}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{"u1": false}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if rep.Enqueued != 0 || rep.Skipped != 1 {
		t.Fatalf("空标题应当跳过而不是发空消息，实际 Enqueued=%d Skipped=%d", rep.Enqueued, rep.Skipped)
	}
}

func TestProducerNeverProducesGeoOrFollowUp(t *testing.T) {
	// 服务端没有位置证据，也看不到追问；这两类必须被白名单挡掉。
	// 这不是「还没实现」，而是刻意的边界：硬造出来就是在编造位置结论、
	// 或者和客户端本地已经排好的追问打架。
	src := &fakeSource{events: []DueEvent{
		{UserID: "u1", Kind: "geo", Ref: "rule1", Title: "你到学校了", OccurredAt: produceNow},
		{UserID: "u1", Kind: "follow_up", Ref: "fu1", Title: "这节课怎么样", OccurredAt: produceNow},
	}}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{"u1": false}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if rep.Enqueued != 0 || len(sink.got) != 0 {
		t.Fatalf("geo 与 follow_up 不该由服务端生产，实际入队 %d 条", len(sink.got))
	}
	if rep.Skipped != 2 {
		t.Fatalf("两条都应记为跳过，实际 %d", rep.Skipped)
	}
}

func TestProducerSkipsUserWhenOwnershipUnknown(t *testing.T) {
	src := &fakeSource{events: []DueEvent{reminderEvent("u1", "t1", "交作业")}}
	sink := &fakeSink{}
	owner := &fakeOwner{err: map[string]error{"u1": errors.New("设备表查询失败")}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("单个用户判定失败不该让整轮报错: %v", err)
	}
	// 判不出执行方时宁可漏发：漏发只是少打扰一次，两边同时发是用户明确禁止的。
	if rep.Enqueued != 0 {
		t.Fatalf("判定失败时不该入队，实际 %d", rep.Enqueued)
	}
	if len(rep.Errors) == 0 {
		t.Fatal("判定失败必须留下可排查的记录")
	}
}

func TestProducerAsksOwnershipOncePerUser(t *testing.T) {
	src := &fakeSource{events: []DueEvent{
		reminderEvent("u1", "t1", "作业一"),
		reminderEvent("u1", "t2", "作业二"),
		reminderEvent("u2", "t3", "作业三"),
	}}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{"u1": false, "u2": false}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if rep.Enqueued != 3 {
		t.Fatalf("三条都应入队，实际 %d", rep.Enqueued)
	}
	// 逐条判定等于把同一件事问很多遍，设备查询会被放大成 N 倍。
	if len(owner.calls) != 2 {
		t.Fatalf("应当每个用户只判定一次，实际调用 %v", owner.calls)
	}
}

func TestProducerPassesLookbackWindowToSource(t *testing.T) {
	src := &fakeSource{}
	sink := &fakeSink{}
	owner := &fakeOwner{owned: map[string]bool{}}
	p := newProducer(src, sink, owner)
	p.Lookback = 90 * time.Minute
	p.Limit = 7

	if _, err := p.ProduceOnce(context.Background()); err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if !src.lastFrom.Equal(produceNow.Add(-90*time.Minute)) || !src.lastTo.Equal(produceNow) {
		t.Fatalf("窗口应为 [now-90m, now]，实际 [%v, %v]", src.lastFrom, src.lastTo)
	}
	if src.lastLimit != 7 {
		t.Fatalf("条数上限应传下去，实际 %d", src.lastLimit)
	}
}

func TestProducerReportsSourceFailure(t *testing.T) {
	src := &fakeSource{err: errors.New("数据库不可用")}
	_, err := newProducer(src, &fakeSink{}, &fakeOwner{}).ProduceOnce(context.Background())
	if err == nil {
		t.Fatal("来源查询失败必须冒泡，否则「一条都没发」会被当成正常")
	}
	if !strings.Contains(err.Error(), "数据库不可用") {
		t.Fatalf("错误应保留原因，实际 %v", err)
	}
}

func TestProducerRequiresAllDependencies(t *testing.T) {
	if _, err := (&Producer{}).ProduceOnce(context.Background()); !errors.Is(err, ErrProducerNotConfigured) {
		t.Fatalf("依赖缺失应返回 ErrProducerNotConfigured，实际 %v", err)
	}
}

func TestProducerOneUserFailureDoesNotBlockAnother(t *testing.T) {
	src := &fakeSource{events: []DueEvent{
		reminderEvent("u1", "t1", "作业一"),
		reminderEvent("u2", "t2", "作业二"),
	}}
	sink := &fakeSink{fail: map[string]error{"reminder:t1": errors.New("写入冲突")}}
	owner := &fakeOwner{owned: map[string]bool{"u1": false, "u2": false}}

	rep, err := newProducer(src, sink, owner).ProduceOnce(context.Background())
	if err != nil {
		t.Fatalf("单条入队失败不该让整轮报错: %v", err)
	}
	if rep.Enqueued != 1 {
		t.Fatalf("u2 应当照常入队，实际 Enqueued=%d", rep.Enqueued)
	}
	if len(rep.Errors) == 0 {
		t.Fatal("入队失败必须留下记录")
	}
}

func TestDedupeKeyHasNoTimestamp(t *testing.T) {
	a := dedupeKeyFor(DueEvent{Kind: KindReminder, Ref: "t1"})
	b := dedupeKeyFor(DueEvent{Kind: KindReminder, Ref: "t1", OccurredAt: produceNow.Add(72 * time.Hour)})
	if a != b {
		t.Fatalf("去重键不能受时间影响，否则每轮轮询都会重复入队: %q vs %q", a, b)
	}
	// 精确等值：键只能是「种类:业务 id」。业务 id 本身可能含数字（如 t1），
	// 所以不能用「有没有数字」来判断，那会把合法的业务 id 误判成时间戳。
	if a != "reminder:t1" {
		t.Fatalf("去重键应恰好是「种类:业务 id」，实际 %q", a)
	}
	if review := dedupeKeyFor(DueEvent{Kind: KindReview, Ref: "t1"}); review == a {
		t.Fatal("不同种类的同一 id 不应撞键")
	}
}
