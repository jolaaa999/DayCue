package proactive

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/push"
)

// 固定时间基准：2026-10-12 12:00 UTC —— 一个既不在默认静默时段、
// 也不跨零点的普通时刻，让用例只验证它真正想验证的那一条规则。
var schedNow = time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)

func schedClock() func() time.Time { return func() time.Time { return schedNow } }

// fakeSender 记录调用并返回预设回执；不需要网络也能覆盖全部结局映射。
type fakeSender struct {
	calls      int
	lastTarget push.DeviceTarget
	lastMsg    push.Message
	receipt    push.Receipt
	err        error
}

func (f *fakeSender) Send(_ context.Context, target push.DeviceTarget, msg push.Message) (push.Receipt, error) {
	f.calls++
	f.lastTarget, f.lastMsg = target, msg
	return f.receipt, f.err
}

func (f *fakeSender) Provider() string { return "fake" }

func acceptedReceipt() push.Receipt {
	return push.Receipt{
		Provider: "fake", DeviceID: "dev_1", Status: push.StatusAccepted, AcceptedAt: schedNow,
	}
}

func testTarget() push.DeviceTarget {
	return push.DeviceTarget{
		UserID: "usr_1", DeviceID: "dev_1", Platform: push.PlatformIOS, Token: "tok",
	}
}

// testPolicy 关掉静默与冷却，只留下预算，让用例一次只面对一条规则。
func testPolicy(budget int) Policy {
	return Policy{DailyBudget: budget, QuietStart: Clock{0, 0}, QuietEnd: Clock{0, 0}, Cooldown: 0}
}

func dueItem(key string) Item {
	return Item{
		Candidate: Candidate{DedupeKey: key, ScheduledAt: schedNow.Add(-time.Minute)},
		Kind:      "geo",
		Message:   push.Message{Title: "该复习了", Body: "还有 3 天考试"},
	}
}

func newTestScheduler(t *testing.T, p Policy, s push.Sender) *Scheduler {
	t.Helper()
	sch, err := NewScheduler(p, s, schedClock())
	if err != nil {
		t.Fatalf("构造调度器失败: %v", err)
	}
	return sch
}

// ---------- 构造期校验 ----------

func TestNewSchedulerRejectsInvalidPolicyAndMissingSender(t *testing.T) {
	if _, err := NewScheduler(Policy{DailyBudget: -1}, &fakeSender{}, schedClock()); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("非法策略必须在构造期被拒绝，实际: %v", err)
	}
	// 没有通道时必须显式传 push.Unconfigured，而不是传 nil：
	// 传 nil 说明组装层漏了接线，宁可在启动期报错。
	if _, err := NewScheduler(testPolicy(3), nil, schedClock()); !errors.Is(err, ErrNoSender) {
		t.Fatalf("缺少推送通道必须在构造期被拒绝，实际: %v", err)
	}
}

// ---------- 策略拦截 ----------

func TestSchedulerDefersInQuietHours(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	// 23:00 UTC 落在 22:30–07:30 的静默时段里。
	quietNow := time.Date(2026, 10, 12, 23, 0, 0, 0, time.UTC)
	sch := &Scheduler{
		Policy: DefaultPolicy(), Sender: sender,
		Now: func() time.Time { return quietNow },
	}
	res, err := sch.Deliver(context.Background(), testTarget(), dueItem("geo:1"))
	if err != nil {
		t.Fatalf("静默时段不该报错: %v", err)
	}
	if res.Outcome != OutcomeDeferred {
		t.Fatalf("静默时段应推迟而不是丢弃，实际: %s", res.Outcome)
	}
	if res.Reason != ReasonQuietDeferred {
		t.Fatalf("原因应为静默推迟，实际: %s", res.Reason)
	}
	if !res.Decision.DeliverAt.After(quietNow) {
		t.Fatal("推迟目标时刻必须晚于当前时刻")
	}
	if sender.calls != 0 {
		t.Fatal("被推迟的消息不得触达推送通道")
	}
	if res.Sent() {
		t.Fatal("被推迟不算已发送")
	}
}

func TestSchedulerDefersBeforeDueTime(t *testing.T) {
	sender := &fakeSender{}
	sch := newTestScheduler(t, testPolicy(3), sender)
	item := dueItem("geo:1")
	item.Candidate.ScheduledAt = schedNow.Add(time.Hour)

	res, err := sch.Deliver(context.Background(), testTarget(), item)
	if err != nil {
		t.Fatalf("未到点不该报错: %v", err)
	}
	if res.Outcome != OutcomeDeferred || res.Reason != ReasonNotYetDue {
		t.Fatalf("未到点应推迟，实际: %s/%s", res.Outcome, res.Reason)
	}
	if sender.calls != 0 {
		t.Fatal("未到点不得触达推送通道")
	}
}

func TestSchedulerSuppressesOverBudget(t *testing.T) {
	sender := &fakeSender{}
	sch := newTestScheduler(t, testPolicy(1), sender)
	item := dueItem("geo:1")
	item.History = History{DeliveredToday: 1}

	res, err := sch.Deliver(context.Background(), testTarget(), item)
	if err != nil {
		t.Fatalf("超预算不该报错: %v", err)
	}
	if res.Outcome != OutcomeSuppressed || res.Reason != ReasonBudget {
		t.Fatalf("超预算应放弃，实际: %s/%s", res.Outcome, res.Reason)
	}
	if sender.calls != 0 {
		t.Fatal("超预算不得触达推送通道")
	}
}

func TestSchedulerSuppressesExpired(t *testing.T) {
	sender := &fakeSender{}
	sch := newTestScheduler(t, testPolicy(3), sender)
	past := schedNow.Add(-time.Hour)
	item := dueItem("geo:1")
	item.Candidate.ExpiresAt = &past

	res, err := sch.Deliver(context.Background(), testTarget(), item)
	if err != nil {
		t.Fatalf("过期不该报错: %v", err)
	}
	if res.Outcome != OutcomeSuppressed || res.Reason != ReasonExpired {
		t.Fatalf("过期应放弃，实际: %s/%s", res.Outcome, res.Reason)
	}
	if sender.calls != 0 {
		t.Fatal("过期消息绝不能发出去：过期提醒比不提醒更糟")
	}
}

// ---------- 投递与结局映射 ----------

func TestSchedulerMapsProviderReceipts(t *testing.T) {
	cases := []struct {
		name    string
		receipt push.Receipt
		want    DeliveryOutcome
	}{
		{"供应商受理", acceptedReceipt(), OutcomeAccepted},
		{"设备已送达", push.Receipt{Provider: "fake", Status: push.StatusDelivered, AcceptedAt: schedNow}, OutcomeDelivered},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sender := &fakeSender{receipt: tc.receipt}
			sch := newTestScheduler(t, testPolicy(3), sender)
			res, err := sch.Deliver(context.Background(), testTarget(), dueItem("geo:1"))
			if err != nil {
				t.Fatalf("投递不该报错: %v", err)
			}
			if res.Outcome != tc.want {
				t.Fatalf("结局应为 %s，实际 %s", tc.want, res.Outcome)
			}
			if !res.Sent() {
				t.Fatal("accepted 与 delivered 都应算已发出")
			}
			if sender.calls != 1 {
				t.Fatalf("应当只调用一次推送，实际 %d 次", sender.calls)
			}
		})
	}
}

func TestSchedulerFillsMessageIdentifiers(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	sch := newTestScheduler(t, testPolicy(3), sender)
	item := dueItem("geo:place-1:2026-10-12")
	// 故意留空 ID 与 DedupeKey，验证调度器会从候选补齐。
	item.Message = push.Message{Title: "该复习了"}

	if _, err := sch.Deliver(context.Background(), testTarget(), item); err != nil {
		t.Fatalf("投递失败: %v", err)
	}
	if sender.lastMsg.ID == "" || sender.lastMsg.DedupeKey == "" {
		t.Fatal("缺少去重键会让同一条消息重试时发两遍，必须从候选补齐")
	}
	if sender.lastMsg.DedupeKey != item.Candidate.DedupeKey {
		t.Fatalf("去重键必须来自候选，实际: %q", sender.lastMsg.DedupeKey)
	}
	if !sender.lastMsg.ScheduledAt.Equal(item.Candidate.ScheduledAt) {
		t.Fatal("计划时刻必须从候选补齐")
	}
}

func TestSchedulerFailureIsOutcomeNotError(t *testing.T) {
	f := &push.Failure{Kind: push.FailureProviderUnavailable, Provider: "fake", StatusCode: 503}
	receipt := push.Receipt{Provider: "fake", DeviceID: "dev_1", Status: push.StatusFailed, Failure: f}
	sender := &fakeSender{receipt: receipt, err: f}
	sch := newTestScheduler(t, testPolicy(3), sender)

	res, err := sch.Deliver(context.Background(), testTarget(), dueItem("geo:1"))
	// 单条推送失败不该以 error 形式冒泡：批量调度会因此中断其余消息。
	if err != nil {
		t.Fatalf("推送失败不应表现为 Go error，实际: %v", err)
	}
	if !res.Failed() {
		t.Fatalf("结局应为 failed，实际: %s", res.Outcome)
	}
	if !res.Retryable() {
		t.Fatal("供应商 503 应标记为可重试")
	}
	if _, ok := push.FailureOf(err); ok {
		t.Fatal("这里不该有 error")
	}
}

func TestSchedulerSurfacesDeviceInvalidation(t *testing.T) {
	f := &push.Failure{Kind: push.FailureInvalidToken, Provider: "fake", StatusCode: 410}
	sender := &fakeSender{
		receipt: push.Receipt{Provider: "fake", DeviceID: "dev_1", Status: push.StatusFailed, Failure: f},
		err:     f,
	}
	sch := newTestScheduler(t, testPolicy(3), sender)
	res, err := sch.Deliver(context.Background(), testTarget(), dueItem("geo:1"))
	if err != nil {
		t.Fatalf("不该报 error: %v", err)
	}
	if !res.DeviceInvalid() {
		t.Fatal("令牌失效必须能透出去，否则失效设备会一直被重试")
	}
	if res.Retryable() {
		t.Fatal("令牌失效不得标记为可重试")
	}
}

// ---------- 批量调度 ----------

func TestSchedulerRunDueIsOldestFirst(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	sch := newTestScheduler(t, testPolicy(10), sender)

	newest := dueItem("geo:new")
	newest.Candidate.ScheduledAt = schedNow.Add(-time.Minute)
	oldest := dueItem("geo:old")
	oldest.Candidate.ScheduledAt = schedNow.Add(-3 * time.Hour)
	middle := dueItem("geo:mid")
	middle.Candidate.ScheduledAt = schedNow.Add(-2 * time.Hour)

	results, err := sch.RunDue(context.Background(), testTarget(), []Item{newest, oldest, middle})
	if err != nil {
		t.Fatalf("批量调度失败: %v", err)
	}
	got := []string{results[0].DedupeKey, results[1].DedupeKey, results[2].DedupeKey}
	want := []string{"geo:old", "geo:mid", "geo:new"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("应按计划时刻升序，实际 %v", got)
		}
	}
}

func TestSchedulerRunDueAccumulatesBudgetWithinBatch(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	sch := newTestScheduler(t, testPolicy(1), sender)

	results, err := sch.RunDue(context.Background(), testTarget(), []Item{
		dueItem("geo:1"), dueItem("geo:2"), dueItem("geo:3"),
	})
	if err != nil {
		t.Fatalf("批量调度失败: %v", err)
	}
	if sender.calls != 1 {
		t.Fatalf("日预算 1 条时一批里最多只能发 1 条，实际 %d 条", sender.calls)
	}
	if results[0].Outcome != OutcomeAccepted {
		t.Fatalf("第一条应发出，实际: %s", results[0].Outcome)
	}
	for _, r := range results[1:] {
		if r.Outcome != OutcomeSuppressed || r.Reason != ReasonBudget {
			t.Fatalf("后续条目应因预算被压掉，实际: %s/%s", r.Outcome, r.Reason)
		}
	}
}

func TestSchedulerRunDueAccumulatesDedupeWithinBatch(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	sch := newTestScheduler(t, testPolicy(10), sender)

	results, err := sch.RunDue(context.Background(), testTarget(), []Item{
		dueItem("geo:same"), dueItem("geo:same"),
	})
	if err != nil {
		t.Fatalf("批量调度失败: %v", err)
	}
	if sender.calls != 1 {
		t.Fatalf("同一去重键一批里只能发一次，实际 %d 次", sender.calls)
	}
	if results[1].Outcome != OutcomeSuppressed || results[1].Reason != ReasonDedupe {
		t.Fatalf("第二条应因去重被压掉，实际: %s/%s", results[1].Outcome, results[1].Reason)
	}
}

func TestSchedulerRunDueContinuesAfterFailure(t *testing.T) {
	f := &push.Failure{Kind: push.FailureProviderUnavailable, Provider: "fake"}
	state := 0
	sender := push.SenderFunc(func(_ context.Context, target push.DeviceTarget, _ push.Message) (push.Receipt, error) {
		state++
		if state == 1 {
			return push.Receipt{Provider: "fake", DeviceID: target.DeviceID, Status: push.StatusFailed, Failure: f}, f
		}
		return acceptedReceipt(), nil
	})
	sch := newTestScheduler(t, testPolicy(10), sender)

	results, err := sch.RunDue(context.Background(), testTarget(), []Item{dueItem("geo:1"), dueItem("geo:2")})
	if err != nil {
		t.Fatalf("一条失败不该中断整批: %v", err)
	}
	if !results[0].Failed() {
		t.Fatalf("第一条应失败，实际: %s", results[0].Outcome)
	}
	if results[1].Outcome != OutcomeAccepted {
		t.Fatalf("第二条仍应发出，实际: %s", results[1].Outcome)
	}
	// 失败不计入预算，否则一次供应商抖动会白白吃掉用户当天的额度。
	if results[1].Decision.Send != true {
		t.Fatal("失败不应影响后续条目的判定")
	}
}

func TestSchedulerDeferredDoesNotConsumeBudget(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	quarter := Policy{DailyBudget: 1, QuietStart: Clock{0, 0}, QuietEnd: Clock{0, 0}, Cooldown: 0}
	sch := newTestScheduler(t, quarter, sender)

	future := dueItem("geo:later")
	future.Candidate.ScheduledAt = schedNow.Add(2 * time.Hour)
	results, err := sch.RunDue(context.Background(), testTarget(), []Item{future, dueItem("geo:now")})
	if err != nil {
		t.Fatalf("批量调度失败: %v", err)
	}
	// 升序后第一条是 geo:now（更早），应先发出去。
	if results[0].Outcome != OutcomeAccepted {
		t.Fatalf("到点的那条应发出，实际: %s", results[0].Outcome)
	}
	if results[1].Outcome != OutcomeDeferred {
		t.Fatalf("未到点的仍应推迟，实际: %s", results[1].Outcome)
	}
}

// ---------- 时区 ----------

func TestSchedulerUsesUserLocationForQuietHours(t *testing.T) {
	sender := &fakeSender{receipt: acceptedReceipt()}
	// UTC 12:00 在 Asia/Shanghai 是 20:00，仍不在静默时段；
	// 但若按 UTC 判断而用户在 +8，某些时刻会判错，这里用 15:00 UTC = 23:00 本地来验证。
	utcNow := time.Date(2026, 10, 12, 15, 0, 0, 0, time.UTC)
	shanghai, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	sch := &Scheduler{
		Policy: DefaultPolicy(), Sender: sender,
		Now:        func() time.Time { return utcNow },
		LocationOf: func(string) *time.Location { return shanghai },
	}
	res, err := sch.Deliver(context.Background(), testTarget(), dueItem("geo:1"))
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if res.Outcome != OutcomeDeferred {
		t.Fatalf("用户本地 23:00 属于静默时段，应推迟，实际: %s", res.Outcome)
	}
	if sender.calls != 0 {
		t.Fatal("静默时段不得触达推送通道")
	}
}

func TestSchedulerDescribeIsHumanReadable(t *testing.T) {
	res := DeliveryResult{Outcome: OutcomeSuppressed, Reason: ReasonBudget}
	if res.Describe() != "已达今日主动消息上限" {
		t.Fatalf("说明文案应可直接展示，实际: %q", res.Describe())
	}
	failed := DeliveryResult{
		Outcome: OutcomeFailed,
		Failure: &push.Failure{Kind: push.FailureNotConfigured, Provider: "apns"},
	}
	if failed.Describe() == "" {
		t.Fatal("失败也必须有可展示的说明")
	}
	accepted := DeliveryResult{Outcome: OutcomeAccepted}
	if accepted.Describe() == "" {
		t.Fatal("成功也必须有可展示的说明")
	}
}

// TestSchedulerNeverClaimsAcceptedWithoutAcceptedReceipt 锁死回执语义：
// 只有回执明确写 accepted 才允许报"已提交给推送服务"；
// 自称失败但没有 error、以及空/未知状态，都必须如实归为失败，不能兜成 accepted。
func TestSchedulerNeverClaimsAcceptedWithoutAcceptedReceipt(t *testing.T) {
	cases := []struct {
		name    string
		receipt push.Receipt
	}{
		{"回执自称失败但没有 error", push.Receipt{Provider: "fake", Status: push.StatusFailed}},
		{"回执状态为空", push.Receipt{Provider: "fake"}},
		{"回执状态未知", push.Receipt{Provider: "fake", Status: push.Status("sent")}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sender := &fakeSender{receipt: tc.receipt}
			sch := newTestScheduler(t, testPolicy(3), sender)
			res, err := sch.Deliver(context.Background(), testTarget(), dueItem("geo:1"))
			if err != nil {
				t.Fatalf("推送失败属于结局而不是 error: %v", err)
			}
			if res.Outcome != OutcomeFailed {
				t.Fatalf("没有可信回执时必须归为失败，实际 %s", res.Outcome)
			}
			if res.Sent() {
				t.Fatal("没有可信回执不得算作已发送")
			}
			if res.Failure == nil {
				t.Fatal("归为失败时必须给出失败详情")
			}
			if res.Describe() == "已提交给推送服务" {
				t.Fatal("不得在未知回执下宣称已提交")
			}
		})
	}
}
