package proactive

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/push"
)

// ledgerFake 是账本端口的测试替身。
//
// 用函数字段而不是固定行为：每条用例只需要替换它关心的那一个方法，
// 其余保持零值即可，避免为了测一个分支写一整套假实现。
type ledgerFake struct {
	claims       []Claim
	claimErr     error
	claimFn      func(ctx context.Context, req ClaimRequest) (ClaimBatch, error)
	historyFn    func(ctx context.Context, userID, dedupeKey, kind string, now time.Time, loc *time.Location) (HistoryFacts, error)
	settleFn     func(ctx context.Context, req SettleRequest) error
	beginFn      func(ctx context.Context, id, token string, at time.Time) error
	recoverFn    func(ctx context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int, unknownGrace time.Duration) (RecoverResult, error)
	locationFn   func(ctx context.Context, userID string) (*time.Location, error)
	markDeviceFn func(ctx context.Context, userID, deviceID string, at time.Time) error
	cancelFn     func(ctx context.Context, userID, deviceID string, at time.Time) (int, error)
	assignFn     func(ctx context.Context, id, deviceID string, at time.Time) error

	claimCalls  int
	released    []releasedCall
	marked      []markedCall
	settles     []SettleRequest
	begun       []string
	invalidated []string
	cancelled   []string
	assigned    []string
}

type releasedCall struct {
	id     string
	reason string
}

type markedCall struct {
	id          string
	state       string
	reason      string
	deliveredAt *time.Time
}

func (f *ledgerFake) ClaimDueProactive(ctx context.Context, req ClaimRequest) (ClaimBatch, error) {
	f.claimCalls++
	if f.claimFn != nil {
		return f.claimFn(ctx, req)
	}
	return ClaimBatch{Claims: f.claims}, f.claimErr
}

func (f *ledgerFake) SettleProactive(ctx context.Context, req SettleRequest) error {
	f.settles = append(f.settles, req)
	// 把结算同时投影到 released / marked 两个视图：
	// released 表达"回到了待领取"，marked 表达"落了某个状态"，两条用例各自只读自己关心的那个。
	if req.State == "pending" {
		f.released = append(f.released, releasedCall{id: req.ID, reason: req.SuppressReason})
	} else {
		f.marked = append(f.marked, markedCall{id: req.ID, state: req.State, reason: req.SuppressReason, deliveredAt: req.DeliveredAt})
	}
	if f.settleFn != nil {
		return f.settleFn(ctx, req)
	}
	return nil
}

func (f *ledgerFake) RecoverExpiredProactive(ctx context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int, unknownGrace time.Duration) (RecoverResult, error) {
	if f.recoverFn != nil {
		return f.recoverFn(ctx, now, limit, lease, maxAttempts, unknownGrace)
	}
	return RecoverResult{}, nil
}

func (f *ledgerFake) BeginProactiveDelivery(ctx context.Context, id, token string, at time.Time) error {
	f.begun = append(f.begun, id)
	if f.beginFn != nil {
		return f.beginFn(ctx, id, token, at)
	}
	return nil
}

func (f *ledgerFake) ProactiveHistory(ctx context.Context, userID, dedupeKey, kind string, now time.Time, loc *time.Location) (HistoryFacts, error) {
	if f.historyFn != nil {
		return f.historyFn(ctx, userID, dedupeKey, kind, now, loc)
	}
	return HistoryFacts{}, nil
}

func (f *ledgerFake) UserLocation(ctx context.Context, userID string) (*time.Location, error) {
	if f.locationFn != nil {
		return f.locationFn(ctx, userID)
	}
	return time.UTC, nil
}

func (f *ledgerFake) MarkDeviceInvalid(ctx context.Context, userID, deviceID string, _ time.Time) error {
	f.invalidated = append(f.invalidated, userID+"|"+deviceID)
	if f.markDeviceFn != nil {
		return f.markDeviceFn(ctx, userID, deviceID, time.Time{})
	}
	return nil
}

func (f *ledgerFake) CancelPendingForDevice(ctx context.Context, userID, deviceID string, _ time.Time) (int, error) {
	f.cancelled = append(f.cancelled, userID+"|"+deviceID)
	if f.cancelFn != nil {
		return f.cancelFn(ctx, userID, deviceID, time.Time{})
	}
	return 0, nil
}

func (f *ledgerFake) AssignProactiveDevice(ctx context.Context, id, deviceID string, _ time.Time) error {
	f.assigned = append(f.assigned, id+"->"+deviceID)
	if f.assignFn != nil {
		return f.assignFn(ctx, id, deviceID, time.Time{})
	}
	return nil
}

// recordingSender 记录每一次投递，并按注入的函数返回回执。
// 与 scheduler_test.go 的 fakeSender 不同：它保留全部调用，才能断言"多设备时只发一台"。
type recordingSender struct {
	mu       sync.Mutex
	targets  []push.DeviceTarget
	messages []push.Message
	fn       func(target push.DeviceTarget, msg push.Message) (push.Receipt, error)
}

func (s *recordingSender) Send(_ context.Context, target push.DeviceTarget, msg push.Message) (push.Receipt, error) {
	s.mu.Lock()
	s.targets = append(s.targets, target)
	s.messages = append(s.messages, msg)
	fn := s.fn
	s.mu.Unlock()
	if fn != nil {
		return fn(target, msg)
	}
	return push.Receipt{Provider: "recording", DeviceID: target.DeviceID, Status: push.StatusAccepted, AcceptedAt: schedNow}, nil
}

func (s *recordingSender) Provider() string { return "recording" }

func (s *recordingSender) calls() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.targets)
}

// deviceListerFunc 让普通函数满足 DeviceLister，测试无需为每种设备组合定义具名类型。
type deviceListerFunc func(ctx context.Context, userID string) ([]push.DeviceTarget, error)

func (f deviceListerFunc) DevicesForUser(ctx context.Context, userID string) ([]push.DeviceTarget, error) {
	return f(ctx, userID)
}

// discardLogger 避免测试输出被调度日志淹没；这些日志在真实运行时才有价值。
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func runnerClaim(userID, id, key string) Claim {
	return Claim{
		ID: id, UserID: userID, Kind: "geo", DedupeKey: key,
		ScheduledAt: schedNow.Add(-time.Minute),
		Title:       "该复习了", Body: "还有 3 天考试",
		// 真实实现里每一条领取都必然带凭证与租约；替身也带上，
		// 否则"旧执行者的回执被拒"这条规则在单测里根本无从验证。
		ClaimToken:     "ctk_" + id,
		LeaseExpiresAt: schedNow.Add(DefaultLease),
		AttemptCount:   1,
		DeliveryID:     "del_" + id,
	}
}

func runnerDevice(userID, deviceID string, platform push.Platform) push.DeviceTarget {
	return push.DeviceTarget{UserID: userID, DeviceID: deviceID, Platform: platform, Token: "tok-" + deviceID}
}

func newRunnerForTest(t *testing.T, led *ledgerFake, sender push.Sender, devices ...push.DeviceTarget) *Runner {
	t.Helper()
	sch := newTestScheduler(t, testPolicy(3), sender)
	return &Runner{
		Ledger:     led,
		Devices:    deviceListerFunc(func(context.Context, string) ([]push.DeviceTarget, error) { return devices, nil }),
		Scheduler:  sch,
		Now:        schedClock(),
		ClaimLimit: 50,
		Logger:     discardLogger(),
	}
}

// TestRunnerRoutesToSingleDevicePerUser 防止的是：一个账号同时有 iOS 与 Android 设备时，
// 调度把同一条主动提醒群发到每台设备，用户被同一条消息打扰多次。
func TestRunnerRoutesToSingleDevicePerUser(t *testing.T) {
	led := &ledgerFake{claims: []Claim{runnerClaim("usr_1", "m1", "k1"), runnerClaim("usr_1", "m2", "k2")}}
	sender := &recordingSender{}
	// 故意按"较差的顺序"传入，证明选择不依赖入参顺序，而依赖稳定的字典序。
	runner := newRunnerForTest(t, led, sender,
		runnerDevice("usr_1", "dev-b", push.PlatformAndroid),
		runnerDevice("usr_1", "dev-a", push.PlatformIOS),
	)

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if sender.calls() != 2 {
		t.Fatalf("两条认领都该发出（同一台设备各一条），实际投递 %d 次", sender.calls())
	}
	for i, target := range sender.targets {
		if target.DeviceID != "dev-a" {
			t.Fatalf("第 %d 条应路由到字典序最小的可用设备 dev-a，实际 %s", i, target.DeviceID)
		}
	}
	if report.Sent != 2 {
		t.Fatalf("两条都应记为已发送，实际 sent=%d", report.Sent)
	}
}

// TestRunnerMarksDeliveredWithReceiptTime 防止的是：把"已提交给供应商"当成用户已收到，
// 或者写入 delivered_at 却用了调度开始时刻而不是回执时刻，导致预算对账对不上。
func TestRunnerMarksDeliveredWithReceiptTime(t *testing.T) {
	led := &ledgerFake{claims: []Claim{runnerClaim("usr_1", "m1", "k1")}}
	sender := &recordingSender{}
	runner := newRunnerForTest(t, led, sender, runnerDevice("usr_1", "dev-a", push.PlatformIOS))

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if report.Sent != 1 {
		t.Fatalf("应记 1 条已发送，实际 %d", report.Sent)
	}
	call := findMarked(t, led, "m1")
	if call.state != "delivered" {
		t.Fatalf("受理成功应落 delivered（账本用 delivered 表达额度已消费），实际 %s", call.state)
	}
	if call.deliveredAt == nil {
		t.Fatal("已发送必须写 delivered_at，否则预算统计不到这次消费")
	}
	if !call.deliveredAt.Equal(schedNow) {
		t.Fatalf("delivered_at 应取回执时刻 %s，实际 %s", schedNow, call.deliveredAt)
	}
}

// TestRunnerSuppressedReleasesReservation 防止的是：被预算挡下的消息继续占着 claimed_at，
// 让后续重试与当日额度统计永远堵在一条不会发的行上。
func TestRunnerSuppressedReleasesReservation(t *testing.T) {
	led := &ledgerFake{
		claims: []Claim{runnerClaim("usr_1", "m1", "k1")},
		historyFn: func(context.Context, string, string, string, time.Time, *time.Location) (HistoryFacts, error) {
			// 当日已发出 3 条，正好达到 testPolicy(3) 的预算上限。
			return HistoryFacts{DeliveredToday: 3, ReservedToday: 1}, nil
		},
	}
	sender := &recordingSender{}
	runner := newRunnerForTest(t, led, sender, runnerDevice("usr_1", "dev-a", push.PlatformIOS))

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if sender.calls() != 0 {
		t.Fatalf("预算已满不得投递，实际投递 %d 次", sender.calls())
	}
	if report.Suppressed != 1 {
		t.Fatalf("应记 1 条被抑制，实际 %d", report.Suppressed)
	}
	call := findMarked(t, led, "m1")
	if call.state != "suppressed" || call.reason != string(ReasonBudget) {
		t.Fatalf("应落 suppressed/daily_budget，实际 %s/%s", call.state, call.reason)
	}
	if call.deliveredAt != nil {
		t.Fatal("被抑制的消息绝不能写 delivered_at")
	}
}

// TestRunnerExpiredIsRecordedAsExpired 防止的是：过期消息被笼统写成 suppressed，
// 让排障分不清"今天额度用完（明天还能发）"与"这条永远不该发"。
func TestRunnerExpiredIsRecordedAsExpired(t *testing.T) {
	expired := runnerClaim("usr_1", "m1", "k1")
	past := schedNow.Add(-time.Hour)
	expired.ExpiresAt = &past
	led := &ledgerFake{claims: []Claim{expired}}
	runner := newRunnerForTest(t, led, &recordingSender{}, runnerDevice("usr_1", "dev-a", push.PlatformIOS))

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if report.Suppressed != 1 {
		t.Fatalf("过期应计入被抑制，实际 %d", report.Suppressed)
	}
	call := findMarked(t, led, "m1")
	if call.state != "expired" || call.reason != string(ReasonExpired) {
		t.Fatalf("过期应落 expired/expired，实际 %s/%s", call.state, call.reason)
	}
}

// TestRunnerRetryableFailureKeepsPending 防止的是：一次限流/供应商 5xx 就把提醒永久取消，
// 或者继续占着 claimed_at 不放，把后续消息的额度压死。
func TestRunnerRetryableFailureKeepsPending(t *testing.T) {
	led := &ledgerFake{claims: []Claim{runnerClaim("usr_1", "m1", "k1")}}
	sender := &recordingSender{fn: func(target push.DeviceTarget, _ push.Message) (push.Receipt, error) {
		f := &push.Failure{Kind: push.FailureRateLimited, Provider: "recording"}
		return push.Receipt{Provider: "recording", DeviceID: target.DeviceID, Status: push.StatusFailed, AcceptedAt: schedNow, Failure: f}, f
	}}
	runner := newRunnerForTest(t, led, sender, runnerDevice("usr_1", "dev-a", push.PlatformIOS))

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if report.Failed != 1 {
		t.Fatalf("应记 1 条失败，实际 %d", report.Failed)
	}
	if len(led.marked) != 0 {
		t.Fatalf("可重试失败不得落终态，实际 %+v", led.marked)
	}
	if len(led.released) != 1 || led.released[0].id != "m1" || led.released[0].reason != "rate_limited" {
		t.Fatalf("可重试失败应释放回 pending 且原因可查，实际 %+v", led.released)
	}
}

// TestRunnerPermanentFailureIsCancelled 防止的是：不可重试的失败被无限重试，
// 每一轮都再打一次供应商、再占一次额度。
func TestRunnerPermanentFailureIsCancelled(t *testing.T) {
	led := &ledgerFake{claims: []Claim{runnerClaim("usr_1", "m1", "k1")}}
	sender := &recordingSender{fn: func(target push.DeviceTarget, _ push.Message) (push.Receipt, error) {
		f := &push.Failure{Kind: push.FailurePermanent, Provider: "recording"}
		return push.Receipt{Provider: "recording", DeviceID: target.DeviceID, Status: push.StatusFailed, AcceptedAt: schedNow, Failure: f}, f
	}}
	runner := newRunnerForTest(t, led, sender, runnerDevice("usr_1", "dev-a", push.PlatformIOS))

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if report.Cancelled != 1 || report.Failed != 1 {
		t.Fatalf("不可重试失败应记 1 条取消、1 条失败，实际 cancelled=%d failed=%d", report.Cancelled, report.Failed)
	}
	if len(led.released) != 0 {
		t.Fatalf("不可重试失败不该释放回 pending，实际 %+v", led.released)
	}
	call := findMarked(t, led, "m1")
	if call.state != "cancelled" || call.reason != string(push.FailurePermanent) {
		t.Fatalf("应落 cancelled/permanent，实际 %s/%s", call.state, call.reason)
	}
}

// TestRunnerDeviceInvalidStopsDevice 防止的是：令牌失效后继续对着一台不存在的设备重试，
// 同时该设备上其它待发消息也一直挂着，永远等一台收不到推送的设备。
func TestRunnerDeviceInvalidStopsDevice(t *testing.T) {
	led := &ledgerFake{
		claims:   []Claim{runnerClaim("usr_1", "m1", "k1")},
		cancelFn: func(context.Context, string, string, time.Time) (int, error) { return 2, nil },
	}
	sender := &recordingSender{fn: func(target push.DeviceTarget, _ push.Message) (push.Receipt, error) {
		f := &push.Failure{Kind: push.FailureInvalidToken, Provider: "recording"}
		return push.Receipt{Provider: "recording", DeviceID: target.DeviceID, Status: push.StatusFailed, AcceptedAt: schedNow, Failure: f}, f
	}}
	runner := newRunnerForTest(t, led, sender, runnerDevice("usr_1", "dev-a", push.PlatformIOS))

	report, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce 不应报错: %v", err)
	}
	if report.DeviceInvalid != 1 {
		t.Fatalf("应记 1 条设备失效，实际 %d", report.DeviceInvalid)
	}
	if len(led.invalidated) != 1 || led.invalidated[0] != "usr_1|dev-a" {
		t.Fatalf("必须停用失效设备 usr_1|dev-a，实际 %+v", led.invalidated)
	}
	if len(led.cancelled) != 1 || led.cancelled[0] != "usr_1|dev-a" {
		t.Fatalf("必须取消该设备其余 pending 行，实际 %+v", led.cancelled)
	}
	if call := findMarked(t, led, "m1"); call.state != "cancelled" || call.reason != "device_invalid" {
		t.Fatalf("当前这条应落 cancelled/device_invalid，实际 %s/%s", call.state, call.reason)
	}
	// 2 条来自取消该设备其余 pending，1 条是当前这条。
	if report.Cancelled != 3 {
		t.Fatalf("应记 3 条取消（其余 2 条 + 当前 1 条），实际 %d", report.Cancelled)
	}
}

// TestRunnerStartSurvivesRoundErrors 防止的是：一轮认领失败（数据库抖动）就让整个调度循环退出，
// 之后所有主动提醒静默停摆，而日志里却只有一条错误。
func TestRunnerStartSurvivesRoundErrors(t *testing.T) {
	called := make(chan struct{}, 16)
	led := &ledgerFake{claimFn: func(context.Context, ClaimRequest) (ClaimBatch, error) {
		called <- struct{}{}
		return ClaimBatch{}, errors.New("数据库暂时不可用")
	}}
	runner := newRunnerForTest(t, led, &recordingSender{})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runner.Start(ctx, 5*time.Millisecond)
		close(done)
	}()

	for i := 0; i < 2; i++ {
		select {
		case <-called:
		case <-time.After(3 * time.Second):
			cancel()
			t.Fatal("单轮错误后调度循环停止运行了")
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("ctx 取消后 Start 未退出")
	}
}

func findMarked(t *testing.T, led *ledgerFake, id string) markedCall {
	t.Helper()
	for _, c := range led.marked {
		if c.id == id {
			return c
		}
	}
	t.Fatalf("没有找到 id=%s 的落库结果，实际 %+v", id, led.marked)
	return markedCall{}
}
