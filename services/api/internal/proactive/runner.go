package proactive

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/push"
)

// Claim 是一条已被本进程认领的账本行（runner 视角）。
//
// 只带调度真正需要的字段：内容、去重键、时间。TargetRef 是冷却键，
// 不进入下发内容；设备由 runner 选好后另行记账。
type Claim struct {
	ID          string
	UserID      string
	Kind        string
	DedupeKey   string
	ScheduledAt time.Time
	ExpiresAt   *time.Time
	Title       string
	Body        string
	DeepLink    string
	Data        map[string]string
}

// HistoryFacts 是存储层给出的判定依据（尚未并入 runner 自己的占用）。
//
// ClaimedToday 含**所有**调度进程的占用，也含本 runner 刚认领的那些；
// runner 必须减掉自己这一批，否则刚认领的消息会把额度算成已消费，导致整批被误抑制。
type HistoryFacts struct {
	DeliveredToday        int
	ClaimedToday          int
	LastDeliveredSameKey  time.Time
	LastDeliveredSameKind time.Time
	SameKeyDeliveredToday bool
}

// ProactiveLedger 是 runner 访问账本的窄接口（端口）。
//
// 刻意在 proactive 包内定义、不 import internal/store：调度编排只依赖这组语义，
// 将来换存储实现（或测试替身）不必改这里，也不会形成 proactive <-> store 的双向依赖。
type ProactiveLedger interface {
	ClaimDueProactive(ctx context.Context, now time.Time, limit int) ([]Claim, error)
	ReleaseProactive(ctx context.Context, id string, reason string, at time.Time) error
	MarkProactiveResult(ctx context.Context, id string, state string, suppressReason string, deliveredAt *time.Time, at time.Time) error
	ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (HistoryFacts, error)
	MarkDeviceInvalid(ctx context.Context, userID string, deviceID string, at time.Time) error
	CancelPendingForDevice(ctx context.Context, userID string, deviceID string, at time.Time) (int, error)
	AssignProactiveDevice(ctx context.Context, id string, deviceID string, at time.Time) error
}

// DeviceLister 列出某用户当前可投递的设备。
//
// 返回 push.DeviceTarget 而不是 store.Device：调度只需要"发到哪台"，
// 传整条设备记录会把 capabilities、last_seen_at 之类无关状态带进编排层。
type DeviceLister interface {
	DevicesForUser(ctx context.Context, userID string) ([]push.DeviceTarget, error)
}

// RunReport 汇总一轮调度的账目，让日志能直接回答"这一轮到底发生了什么"。
type RunReport struct {
	// Claimed 是本轮认领到的行数。
	Claimed int
	// Sent 是已提交给推送服务（accepted/delivered）的条数。
	Sent int
	// Suppressed 是按策略放弃的条数（含过期）。
	Suppressed int
	// Deferred 是推迟/释放后保持 pending 的条数，下一轮会重试。
	Deferred int
	// Failed 是投递失败的条数（可重试与不可重试都算）。
	Failed int
	// DeviceInvalid 是因令牌失效而停用设备的条数。
	DeviceInvalid int
	// Cancelled 是落成 cancelled 的条数（不可重试失败、设备失效）。
	Cancelled int
	// Errors 是存储/设备访问等基础设施错误条数，不代表消息本身失败。
	Errors int
}

// Runner 把"账本、设备、调度器"编排成一轮可重跑的调度。
type Runner struct {
	// Ledger 是账本端口；必填。
	Ledger ProactiveLedger
	// Devices 是设备端口；必填。
	Devices DeviceLister
	// Scheduler 是已经接好推送通道的调度器；必填。
	Scheduler *Scheduler
	// LocationOf 给出用户时区；为空按 UTC。
	LocationOf func(userID string) *time.Location
	// Now 可注入，便于测试固定时间基准。
	Now func() time.Time
	// ClaimLimit 是单轮最多认领行数；<=0 时取默认 50。
	ClaimLimit int
	// Logger 为空时用 slog.Default()。
	Logger *slog.Logger
}

// DefaultClaimLimit 是单轮默认认领上限。
//
// 有上限而不是"能取多少取多少"：一轮太长会让同批后面的消息等太久，
// 也会让一次推送服务抖动放大成整批失败。
const DefaultClaimLimit = 50

// ErrRunnerNotConfigured 表示 runner 缺少必需端口。
var ErrRunnerNotConfigured = errors.New("proactive: runner 未配置完整")

// RunOnce 执行一轮调度：认领 -> 按用户选一台设备 -> 组装判定事实 -> 投递 -> 落库。
//
// 只有"整轮无法开始"（认领失败、端口缺失）才返回 error；单个用户/单条消息的失败
// 计入 RunReport，绝不因为一条失败就让整轮中断 —— 推送不是事务。
func (r *Runner) RunOnce(ctx context.Context) (RunReport, error) {
	var report RunReport
	if r.Ledger == nil || r.Devices == nil || r.Scheduler == nil {
		return report, ErrRunnerNotConfigured
	}
	now := r.now()
	claims, err := r.Ledger.ClaimDueProactive(ctx, now, r.claimLimit())
	if err != nil {
		return report, err
	}
	report.Claimed = len(claims)
	if len(claims) == 0 {
		return report, nil
	}

	groups := groupClaimsByUser(claims)
	for _, userID := range sortedUserIDs(groups) {
		if err := r.processUser(ctx, userID, groups[userID], &report, now); err != nil {
			// 单个用户失败不能吞掉其余用户；但已经把整批认领出去的这一组必须释放，
			// 否则会留下"认领了却永远轮不到"的假占用。
			r.logger().Error("主动推送：处理用户失败", "user_id", userID, "error", err.Error())
			r.releaseAll(ctx, groups[userID], "user_batch_failed", now, &report)
		}
	}
	return report, nil
}

// processUser 处理同一用户本轮的全部认领：路由去重后一次交给调度器。
func (r *Runner) processUser(ctx context.Context, userID string, claims []Claim, report *RunReport, now time.Time) error {
	devices, err := r.Devices.DevicesForUser(ctx, userID)
	if err != nil {
		// 设备查询失败属于基础设施故障，不是"这条不该发"：释放占用、保持 pending，下一轮再试。
		r.releaseAll(ctx, claims, "device_lookup_failed", now, report)
		return fmt.Errorf("查询设备失败: %w", err)
	}

	// 路由去重：一个账号无论有几台设备，同一轮只挑一台。主动提醒不是群发，
	// 每台都发会让用户被同一条消息打扰多次。
	target, ok := pickTarget(devices)
	if !ok {
		// 没有可投递设备（未登录/未上报令牌/平台未配置）不是"发失败"：
		// 直接 cancelled 会让提醒永久消失，所以释放后保持 pending，等设备出现再发。
		r.releaseAll(ctx, claims, "no_deliverable_device", now, report)
		return nil
	}

	// 先记下路由结果，后续令牌失效取消该设备其余 pending 行时才有据可依。
	for _, c := range claims {
		if err := r.Ledger.AssignProactiveDevice(ctx, c.ID, target.DeviceID, now); err != nil {
			r.recordError(report, "记录目标设备失败", c.ID, err)
		}
	}

	loc := r.locationOf(userID)
	items := make([]Item, 0, len(claims))
	byKey := make(map[string]Claim, len(claims))
	for _, c := range claims {
		facts, err := r.Ledger.ProactiveHistory(ctx, userID, c.DedupeKey, c.Kind, now, loc)
		if err != nil {
			return fmt.Errorf("读取判定事实失败: %w", err)
		}
		items = append(items, r.buildItem(c, facts, len(claims)))
		byKey[c.DedupeKey] = c
	}

	results, err := r.Scheduler.RunDue(ctx, target, items)
	if err != nil {
		// 调度器只在配置/编程错误时返回 error（例如没有发送通道）；
		// 已经发出去的那些必须按回执落库，未处理的才释放。
		r.releaseUnprocessed(ctx, claims, results, "scheduler_error", now, report)
		return err
	}
	for _, res := range results {
		claim, ok := byKey[res.DedupeKey]
		if !ok {
			report.Errors++
			r.logger().Error("主动推送：回执无法对应到认领行", "dedupe_key", res.DedupeKey)
			continue
		}
		r.applyResult(ctx, userID, target.DeviceID, claim, res, now, report)
	}
	return nil
}

// buildItem 把账本行 + 判定事实组装成调度器输入。
//
// own 是本轮同一用户认领的条数：它必须从 ClaimedToday 里扣除。
// ClaimedToday 统计的是"账本里此刻被占用的行"，包含本 runner 刚认领的这一批；
// 若不扣除，本批每条都会把额度算成已消费，日预算 3 条的用户可能一条都发不出。
// 扣除后剩下的就是"别的调度进程的占用"，这才是判定时应当计入的既有消费；
// 本批内部已发出的条数由 Scheduler.RunDue 的批内累积负责。
func (r *Runner) buildItem(c Claim, facts HistoryFacts, own int) Item {
	otherClaims := facts.ClaimedToday - own
	if otherClaims < 0 {
		otherClaims = 0
	}
	return Item{
		Candidate: Candidate{
			DedupeKey:   c.DedupeKey,
			ScheduledAt: c.ScheduledAt,
			ExpiresAt:   c.ExpiresAt,
		},
		History: History{
			DeliveredToday:        facts.DeliveredToday + otherClaims,
			LastDeliveredSameKey:  facts.LastDeliveredSameKey,
			LastDeliveredSameKind: facts.LastDeliveredSameKind,
			SameKeyDeliveredToday: facts.SameKeyDeliveredToday,
		},
		Kind: c.Kind,
		Message: push.Message{
			ID:          c.ID,
			Kind:        c.Kind,
			DedupeKey:   c.DedupeKey,
			Title:       c.Title,
			Body:        c.Body,
			DeepLink:    c.DeepLink,
			ScheduledAt: c.ScheduledAt,
			ExpiresAt:   c.ExpiresAt,
			Data:        c.Data,
		},
	}
}

// applyResult 按回执落库。每一支都刻意写死动作，避免"没报错就当发成功"。
func (r *Runner) applyResult(ctx context.Context, userID, deviceID string, c Claim, res DeliveryResult, now time.Time, report *RunReport) {
	switch {
	case res.Sent():
		// 只有真正交给推送服务（accepted/delivered）才写发出时间。
		// 把"已提交给供应商"写成用户已收到是虚报，但账本要记的是"这段额度已经消费"，
		// 所以 delivered_at 取回执时刻；它不代表用户读过。
		at := receiptTime(res, now)
		if err := r.Ledger.MarkProactiveResult(ctx, c.ID, "delivered", "", &at, now); err != nil {
			r.recordError(report, "写入送达结果失败", c.ID, err)
			return
		}
		report.Sent++

	case res.Outcome == OutcomeSuppressed:
		state := "suppressed"
		if res.Reason == ReasonExpired {
			// 过期是独立状态：它和"预算不够"的后续动作不同（预算还能等明天，过期永远不发）。
			state = "expired"
		}
		if err := r.Ledger.MarkProactiveResult(ctx, c.ID, state, string(res.Reason), nil, now); err != nil {
			r.recordError(report, "写入抑制结果失败", c.ID, err)
			return
		}
		report.Suppressed++

	case res.Outcome == OutcomeDeferred:
		// 推迟不是终态：释放占用、保持 pending，下次调度重新判定。
		if err := r.Ledger.ReleaseProactive(ctx, c.ID, string(res.Reason), now); err != nil {
			r.recordError(report, "释放推迟消息失败", c.ID, err)
			return
		}
		report.Deferred++

	case res.Failed():
		report.Failed++
		if res.DeviceInvalid() {
			report.DeviceInvalid++
			r.handleDeviceInvalid(ctx, userID, deviceID, c, now, report)
			return
		}
		if res.Retryable() {
			// 可重试失败保留 pending：释放占用而不是继续占着额度，
			// 否则"限流失败"会一直扣着当日预算，把后面的消息全压死。
			if err := r.Ledger.ReleaseProactive(ctx, c.ID, failureReason(res), now); err != nil {
				r.recordError(report, "释放可重试失败消息失败", c.ID, err)
			}
			return
		}
		// 不可重试的失败（参数非法、凭据被拒、未配置等）落 cancelled：
		// 无限重试只会放大问题，也不会让用户收到这条消息。
		if err := r.Ledger.MarkProactiveResult(ctx, c.ID, "cancelled", failureReason(res), nil, now); err != nil {
			r.recordError(report, "写入取消失败结果失败", c.ID, err)
			return
		}
		report.Cancelled++

	default:
		report.Errors++
		r.logger().Error("主动推送：未知投递结果", "message_id", c.ID, "outcome", string(res.Outcome))
	}
}

// handleDeviceInvalid 处理令牌失效：停用设备、取消该设备其余 pending、把当前这条落 cancelled。
//
// 顺序上先停用设备再取消其余 pending：即使取消失败，设备令牌也已作废，
// 下一轮不会再把消息路由到这台设备。
func (r *Runner) handleDeviceInvalid(ctx context.Context, userID, deviceID string, c Claim, now time.Time, report *RunReport) {
	if err := r.Ledger.MarkDeviceInvalid(ctx, userID, deviceID, now); err != nil {
		// 设备可能已被删除：这不算致命，但必须留下痕迹。
		r.logger().Warn("主动推送：停用失效设备失败", "user_id", userID, "device_id", deviceID, "error", err.Error())
		report.Errors++
	}
	if n, err := r.Ledger.CancelPendingForDevice(ctx, userID, deviceID, now); err != nil {
		r.logger().Warn("主动推送：取消失效设备待发消息失败", "user_id", userID, "device_id", deviceID, "error", err.Error())
		report.Errors++
	} else if n > 0 {
		report.Cancelled += n
		r.logger().Info("主动推送：已取消失效设备上尚未发出的消息", "user_id", userID, "device_id", deviceID, "count", n)
	}
	if err := r.Ledger.MarkProactiveResult(ctx, c.ID, "cancelled", "device_invalid", nil, now); err != nil {
		r.recordError(report, "写入设备失效取消结果失败", c.ID, err)
		return
	}
	report.Cancelled++
}

// releaseAll 释放一批认领（尚未有任何投递动作时使用）。
func (r *Runner) releaseAll(ctx context.Context, claims []Claim, reason string, now time.Time, report *RunReport) {
	for _, c := range claims {
		if err := r.Ledger.ReleaseProactive(ctx, c.ID, reason, now); err != nil {
			r.recordError(report, "释放认领失败", c.ID, err)
			continue
		}
		report.Deferred++
	}
}

// releaseUnprocessed 只释放没有出现在回执里的那些行。
//
// 调度器返回 error 时可能已经发出了一部分，把已发的也释放会报 ErrNotFound
// 并掩盖真实结果；按 DedupeKey 排除已处理行才是诚实的做法。
func (r *Runner) releaseUnprocessed(ctx context.Context, claims []Claim, results []DeliveryResult, reason string, now time.Time, report *RunReport) {
	handled := make(map[string]bool, len(results))
	for _, res := range results {
		handled[res.DedupeKey] = true
	}
	for _, c := range claims {
		if handled[c.DedupeKey] {
			continue
		}
		if err := r.Ledger.ReleaseProactive(ctx, c.ID, reason, now); err != nil {
			r.recordError(report, "释放未处理认领失败", c.ID, err)
			continue
		}
		report.Deferred++
	}
}

// Start 按 interval 循环调 RunOnce，ctx 取消即退出。
//
// 单轮错误只记日志：调度循环必须活着，数据库抖动或推送服务短暂不可用都会过去，
// 让循环因为一次错误退出等于让所有主动提醒静默停摆。
func (r *Runner) Start(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	select {
	case <-ctx.Done():
		return
	default:
	}
	r.runOnceLogged(ctx)

	for {
		select {
		case <-ctx.Done():
			r.logger().Info("主动推送调度已停止")
			return
		case <-ticker.C:
			r.runOnceLogged(ctx)
		}
	}
}

// runOnceLogged 执行一轮并把错误/账目写进日志，绝不把错误抛给循环。
func (r *Runner) runOnceLogged(ctx context.Context) {
	report, err := r.RunOnce(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		r.logger().Error("主动推送：本轮调度失败", "error", err.Error())
		return
	}
	// 空轮次不刷日志：多数轮次都没有到期消息，每轮打一行会淹没有用信息。
	if report.Claimed == 0 && report.Errors == 0 {
		return
	}
	r.logger().Info("主动推送：本轮调度完成",
		"claimed", report.Claimed,
		"sent", report.Sent,
		"suppressed", report.Suppressed,
		"deferred", report.Deferred,
		"failed", report.Failed,
		"device_invalid", report.DeviceInvalid,
		"cancelled", report.Cancelled,
		"errors", report.Errors,
	)
}

// pickTarget 从同一账号的多台设备里挑一台。
//
// 规则刻意简单且确定：先丢掉没有推送令牌的（发也发不出去），
// 再按 DeviceID 字典序取第一台。同一个用户多次运行、多个进程得到的选择一致，
// 不会因为 map 迭代顺序不同而一会儿发这台、一会儿发那台。
func pickTarget(devices []push.DeviceTarget) (push.DeviceTarget, bool) {
	candidates := make([]push.DeviceTarget, 0, len(devices))
	for _, d := range devices {
		if strings.TrimSpace(d.Token) == "" {
			continue
		}
		candidates = append(candidates, d)
	}
	if len(candidates) == 0 {
		return push.DeviceTarget{}, false
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].DeviceID < candidates[j].DeviceID })
	return candidates[0], true
}

// groupClaimsByUser 按用户分组，保证"同一用户本轮只路由到一台设备"。
func groupClaimsByUser(claims []Claim) map[string][]Claim {
	out := make(map[string][]Claim)
	for _, c := range claims {
		out[c.UserID] = append(out[c.UserID], c)
	}
	return out
}

// sortedUserIDs 让处理顺序稳定，日志与测试才可复现。
func sortedUserIDs(groups map[string][]Claim) []string {
	ids := make([]string, 0, len(groups))
	for id := range groups {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// receiptTime 取这次投递应当记入账本的时刻。
//
// delivered 优先用供应商回报的送达时刻；accepted 用受理时刻（两者都非零时才用）；
// 都没有就退回本轮基准时刻，绝不用系统时钟绕过注入的 now。
func receiptTime(res DeliveryResult, fallback time.Time) time.Time {
	if res.Outcome == OutcomeDelivered && res.Receipt.DeliveredAt != nil {
		return *res.Receipt.DeliveredAt
	}
	if !res.Receipt.AcceptedAt.IsZero() {
		return res.Receipt.AcceptedAt
	}
	return fallback
}

// failureReason 把失败分类变成可落库的稳定原因串；没有详情时给一个非空兜底，
// 避免 suppress_reason 为空让排障时看不出为什么取消。
func failureReason(res DeliveryResult) string {
	if res.Failure != nil && res.Failure.Kind != "" {
		return string(res.Failure.Kind)
	}
	return "unknown_failure"
}

func (r *Runner) claimLimit() int {
	if r.ClaimLimit > 0 {
		return r.ClaimLimit
	}
	return DefaultClaimLimit
}

func (r *Runner) locationOf(userID string) *time.Location {
	if r.LocationOf == nil {
		return time.UTC
	}
	if loc := r.LocationOf(userID); loc != nil {
		return loc
	}
	return time.UTC
}

func (r *Runner) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *Runner) logger() *slog.Logger {
	if r.Logger != nil {
		return r.Logger
	}
	return slog.Default()
}

// recordError 记一次基础设施错误并计数，同时保留 message_id 便于对账。
func (r *Runner) recordError(report *RunReport, what, messageID string, err error) {
	if report != nil {
		report.Errors++
	}
	r.logger().Error("主动推送："+what, "message_id", messageID, "error", err.Error())
}
