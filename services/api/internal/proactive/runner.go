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
	// ClaimToken 是本次领取的凭证，结算时必须原样带回。
	// 少了它，一个"租约已经被回收给别人"的旧执行者就能提交结果，把新租约的结论覆盖掉。
	ClaimToken string
	// LeaseExpiresAt 是本次租约截止时刻。
	LeaseExpiresAt time.Time
	// AttemptCount 是累计领取次数（含本次），退避与上限都按它算。
	AttemptCount int
	// DeliveryID 是稳定投递标识，随通知一起下发，便于与供应商按同一标识对账。
	DeliveryID string
}

// ClaimBatch 是一次领取的结果。
type ClaimBatch struct {
	Claims []Claim
	// OverBudgetUsers 是"还有到期行、但当日额度已经用完"的用户。
	// 它与"没有到期行"是两件事：前者说明策略在生效，后者说明没活可干。
	OverBudgetUsers []string
}

// ClaimRequest 是一次领取请求。
type ClaimRequest struct {
	// Now 是时间基准。
	Now time.Time
	// Limit 是单轮最多领取行数。
	Limit int
	// ClaimedBy 是本执行者的稳定标识，写进租约便于排障。
	ClaimedBy string
	// Lease 是租约时长。
	Lease time.Duration
	// MaxAttempts 是单条消息允许被领取的最大次数。
	MaxAttempts int
	// DailyLimitFor 返回某用户当日允许发出的条数；<=0 时用存储层的兜底上限。
	DailyLimitFor func(userID string) int
	// LocationFor 返回某用户时区；为 nil 时按 UTC 计算自然日边界。
	LocationFor func(userID string) *time.Location
}

// SettleRequest 是一次结算请求。
//
// Token 是必填：存储层会校验它与租约，不匹配或已过期一律拒绝且不改任何状态。
type SettleRequest struct {
	ID             string
	Token          string
	State          string
	SuppressReason string
	DeliveredAt    *time.Time
	// DeliveryStatus 记录本次的交付确定性（见 store 的 0003 迁移说明）。
	DeliveryStatus string
	At             time.Time
	// RetryAfter 只在 State=pending（重新排队）时有意义。
	RetryAfter time.Duration
}

// RecoverResult 是一次租约回收的账目。
type RecoverResult struct {
	Requeued int
	Expired  int
	Extended int
}

// HistoryFacts 是存储层给出的判定依据（尚未并入 runner 自己的占用）。
//
// ClaimedToday 含**所有**调度进程的占用，也含本 runner 刚认领的那些；
// runner 必须减掉自己这一批，否则刚认领的消息会把额度算成已消费，导致整批被误抑制。
type HistoryFacts struct {
	DeliveredToday int
	// ClaimedToday 是当日已被领取（在途）的条数；ReservedToday 是预算窗口里的预留计数。
	// 两者都按"用户当日窗口"统计，改时区不会让它们漂移。
	ClaimedToday int
	// ReservedToday 是当日预算窗口已预留的条数（含调用方自己刚领的）。
	// 它是"在途占用"的唯一权威口径：判定当日已消费必须用它，而不是现算 claimed_at。
	ReservedToday int
	// UnknownToday 是当日"投递结果不明"的条数，只用于排障与审计。
	UnknownToday          int
	LastDeliveredSameKey  time.Time
	LastDeliveredSameKind time.Time
	SameKeyDeliveredToday bool
}

// ProactiveLedger 是 runner 访问账本的窄接口（端口）。
//
// 刻意在 proactive 包内定义、不 import internal/store：调度编排只依赖这组语义，
// 将来换存储实现（或测试替身）不必改这里，也不会形成 proactive <-> store 的双向依赖。
type ProactiveLedger interface {
	ClaimDueProactive(ctx context.Context, req ClaimRequest) (ClaimBatch, error)
	SettleProactive(ctx context.Context, req SettleRequest) error
	RecoverExpiredProactive(ctx context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int) (RecoverResult, error)
	// BeginProactiveDelivery 必须在真正调用供应商**之前**调用。
	// 顺序反了的话，崩在发送调用中间的消息会被恢复者当成"还没发过"而重发。
	BeginProactiveDelivery(ctx context.Context, id string, token string, at time.Time) error
	ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (HistoryFacts, error)
	UserLocation(ctx context.Context, userID string) (*time.Location, error)
	MarkDeviceInvalid(ctx context.Context, userID, deviceID string, at time.Time) error
	CancelPendingForDevice(ctx context.Context, userID, deviceID string, at time.Time) (int, error)
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
	// Ambiguous 是"投递已发起但结果不明"的条数。它必须能单独看出来：
	// 这类消息既不是已发出、也不是确定失败，需要人工或后续对账收口。
	Ambiguous int
	// OverBudget 是"还有到期行、但当日额度已经用完"的用户数。
	OverBudget int
	// Recovered 是本轮回收的过期租约条数（重新入队 + 逾期作废 + 延长租约）。
	Recovered int
	// Stale 是被拒的迟到回执条数：租约已被回收/接管，或租约已过期。
	// 它非零说明有执行者干活太慢，是容量问题而不是数据问题。
	Stale int
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
	// ClaimedBy 是本执行者的稳定标识（例如主机名 + pid），写进租约便于排障。
	// 为空时用 "daycued"：空标识会让"这条是谁领的"永远无法回答。
	ClaimedBy string
	// Lease 是租约时长；<=0 时用 DefaultLease。
	Lease time.Duration
	// MaxAttempts 是单条消息允许被领取的最大次数；<=0 时用 DefaultMaxAttempts。
	MaxAttempts int
	// DailyBudgetFor 返回某用户当日允许发出的条数；为 nil 时按调度策略的 DailyBudget。
	//
	// 领取阶段就要按它原子预留额度：只在调度器里判定预算是不够的，
	// 两个并发调度进程各自判定时都看不到对方刚领走的行。
	DailyBudgetFor func(userID string) int
	// RecoverLimit 是单轮最多回收的过期租约条数；<=0 时用 ClaimLimit。
	RecoverLimit int
	// LocationSource 用于在缺少按用户时区的直接入口时取用户时区（可空）。
	LocationSource func(ctx context.Context, userID string) (*time.Location, error)
}

// 租约与重试上限的默认值。
const (
	// DefaultLease 是默认租约时长。
	//
	// 15 分钟远大于一轮正常调度（秒级），又足够短，让"进程崩溃后能在 15 分钟内
	// 被回收"这件事真正成立。
	DefaultLease = 15 * time.Minute
	// DefaultMaxAttempts 是默认最大领取次数：一次正常投递 + 三次重试。
	DefaultMaxAttempts = 4
	// DefaultRetryBackoff 是失败重试的最小退避。
	DefaultRetryBackoff = 30 * time.Second
	// MaxRetryBackoff 是失败重试的退避上限。
	MaxRetryBackoff = 30 * time.Minute
)

// DefaultClaimLimit 是单轮默认认领上限。
//
// 有上限而不是"能取多少取多少"：一轮太长会让同批后面的消息等太久，
// 也会让一次推送服务抖动放大成整批失败。
const DefaultClaimLimit = 50

// ErrRunnerNotConfigured 表示 runner 缺少必需端口。
var ErrRunnerNotConfigured = errors.New("proactive: runner 未配置完整")

// RunOnce 执行一轮调度：回收过期租约 -> 领取 -> 按用户选一台设备 -> 组装判定事实 -> 投递 -> 带凭证结算。
//
// 只有"整轮无法开始"（领取失败、端口缺失）才返回 error；单个用户/单条消息的失败
// 计入 RunReport，绝不因为一条失败就让整轮中断 —— 推送不是事务。
func (r *Runner) RunOnce(ctx context.Context) (RunReport, error) {
	var report RunReport
	if r.Ledger == nil || r.Devices == nil || r.Scheduler == nil {
		return report, ErrRunnerNotConfigured
	}
	now := r.now()

	// 先回收过期租约再领取：上一轮崩溃留下的租约如果能回收，本轮就能接着把它发出去；
	// 放在领取之后做，那些行要白等一整轮。
	if rec, err := r.Ledger.RecoverExpiredProactive(ctx, now, r.recoverLimit(), r.lease(), r.maxAttempts()); err != nil {
		// 回收失败不是"本轮不能调度"：新消息的投递不该被旧租约的清理问题挡住。
		r.logger().Error("主动推送：回收过期租约失败", "error", err.Error())
		report.Errors++
	} else {
		report.Recovered = rec.Requeued + rec.Expired + rec.Extended
		if report.Recovered > 0 {
			r.logger().Info("主动推送：回收过期租约",
				"requeued", rec.Requeued, "expired", rec.Expired, "extended", rec.Extended)
		}
	}

	batch, err := r.Ledger.ClaimDueProactive(ctx, ClaimRequest{
		Now:           now,
		Limit:         r.claimLimit(),
		ClaimedBy:     r.claimedBy(),
		Lease:         r.lease(),
		MaxAttempts:   r.maxAttempts(),
		DailyLimitFor: r.dailyBudgetFor,
		LocationFor:   r.locationLookup(ctx),
	})
	if err != nil {
		return report, err
	}
	report.Claimed = len(batch.Claims)
	report.OverBudget = len(batch.OverBudgetUsers)
	if report.Claimed == 0 {
		return report, nil
	}

	groups := groupClaimsByUser(batch.Claims)
	for _, userID := range sortedUserIDs(groups) {
		if err := r.processUser(ctx, userID, groups[userID], &report, now); err != nil {
			// 单个用户失败不能吞掉其余用户；但已经把整批领取出去的这一组必须释放，
			// 否则会留下"领取了却永远轮不到"的假占用。
			r.logger().Error("主动推送：处理用户失败", "user_id", userID, "error", err.Error())
			r.releaseAll(ctx, groups[userID], "user_batch_failed", now, &report)
		}
	}
	return report, nil
}

// processUser 处理同一用户本轮的全部领取：路由去重后一次交给调度器。
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
		// 直接落终态会让提醒永久消失，所以释放后保持 pending，等设备出现再发。
		r.releaseAll(ctx, claims, "no_deliverable_device", now, report)
		return nil
	}

	// 先记下路由结果，后续令牌失效取消该设备其余 pending 行时才有据可依。
	for _, c := range claims {
		if err := r.Ledger.AssignProactiveDevice(ctx, c.ID, target.DeviceID, now); err != nil {
			r.recordError(report, "记录目标设备失败", c.ID, err)
		}
	}

	loc := r.locationOf(ctx, userID)
	items := make([]Item, 0, len(claims))
	byKey := make(map[string]Claim, len(claims))
	deliveries := make([]preparedDelivery, 0, len(claims))
	for _, c := range claims {
		facts, err := r.Ledger.ProactiveHistory(ctx, userID, c.DedupeKey, c.Kind, now, loc)
		if err != nil {
			return fmt.Errorf("读取判定事实失败: %w", err)
		}
		// 在发起任何投递之前登记"本次已发起投递"。
		//
		// 为什么必须在调用供应商之前：进程若崩在发送调用中间，恢复者看到的应当是
		// "结果不明"而不是"还没发过"——后者会导致对一条可能已经被用户收到的消息再发一次。
		// 登记失败（租约已被回收/接管）说明这条已经不属于本执行者，必须整条跳过。
		if err := r.Ledger.BeginProactiveDelivery(ctx, c.ID, c.ClaimToken, now); err != nil {
			report.Stale++
			r.recordError(report, "登记发起投递失败（本条已不属于本执行者）", c.ID, err)
			continue
		}
		items = append(items, r.buildItem(c, facts, len(claims)))
		byKey[c.DedupeKey] = c
		deliveries = append(deliveries, preparedDelivery{claim: c})
	}
	if len(items) == 0 {
		return nil
	}
	results, err := r.Scheduler.RunDue(ctx, target, items)
	if err != nil {
		// 调度器只在配置/编程错误时返回 error（例如没有发送通道）；
		// 已经发出去了的那些必须按回执落库，未处理的才释放。
		r.releaseUnprocessed(ctx, deliveries, results, "scheduler_error", now, report)
		return err
	}
	for _, res := range results {
		claim, ok := byKey[res.DedupeKey]
		if !ok {
			report.Errors++
			r.logger().Error("主动推送：回执无法对应到领取行", "dedupe_key", res.DedupeKey)
			continue
		}
		r.applyResult(ctx, userID, target.DeviceID, claim, res, now, report)
	}
	return nil
}

// preparedDelivery 是本轮已经登记过"发起投递"的领取行。
//
// 之所以需要它：释放未处理的行时必须按**去重键**匹配，而 Claim 里的去重键可能在
// 回执里被补齐/改写；用它把"已登记"这件事显式带下来，比在下游再猜一次可靠。
type preparedDelivery struct {
	claim Claim
}

// settleStatus 把"这次投递处于什么状态"翻译成存储层的交付确定性取值。
//
// 三个取值必须字符串一致地出现在这里：它们是账本的公开语义，不是内部魔法值。
const (
	deliveryNotAttempted = "not_attempted"
	deliverySending      = "sending"
	deliveryUnknown      = "attempted_unknown"
)

// applyResult 按回执落库。每一支都刻意写死动作，避免"没报错就当发成功"。
//
// 所有写入都带 ClaimToken：存储层会校验凭证与租约，一个"租约已被回收"的旧执行者
// 提交的结果会被明确拒绝，而不是悄悄覆盖新租约的结论。
func (r *Runner) applyResult(ctx context.Context, userID, deviceID string, c Claim, res DeliveryResult, now time.Time, report *RunReport) {
	switch {
	case res.Sent():
		// 只有真正交给推送服务（accepted/delivered）才写发出时间。
		// 把"已提交给供应商"写成用户已收到是虚报，但账本要记的是"这段额度已经消费"，
		// 所以 delivered_at 取回执时刻；它不代表用户读过。
		at := receiptTime(res, now)
		if err := r.settle(ctx, c, "delivered", "", &at, deliveryNotAttempted, now, 0, report); err != nil {
			return
		}
		report.Sent++

	case res.Outcome == OutcomeSuppressed:
		state := "suppressed"
		if res.Reason == ReasonExpired {
			// 过期是独立状态：它和"预算不够"的后续动作不同（预算还能等明天，过期永远不发）。
			state = "expired"
		}
		if err := r.settle(ctx, c, state, string(res.Reason), nil, deliveryNotAttempted, now, 0, report); err != nil {
			return
		}
		report.Suppressed++

	case res.Outcome == OutcomeDeferred:
		// 推迟不是终态：重新排队、进入退避，下次调度重新判定。
		//
		// 注意推迟仍然占着当日预留（结算保持 pending 时预留不回退），这正是"在途"的含义：
		// 这条今天很可能还会发出去，不能把额度让给别的消息，否则用户当天实际会多发。
		if err := r.settle(ctx, c, "pending", string(res.Reason), nil, deliveryNotAttempted, now, r.retryAfter(c), report); err != nil {
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
			//
			// 但"限流/供应商故障"里有两种性质不同的情形，必须分开：
			//   * 供应商明确回了 429（限流）：请求确定被拒，没发出去，重试是安全的；
			//   * 网络中断 / 5xx：**无法确定供应商是否已经受理**。盲目重发就是重复打扰，
			//     所以标成"结果不明"并落终态，交给人工或后续按 delivery_id 对账收口。
			if r.deliveryAmbiguous(res) {
				report.Ambiguous++
				r.logger().Warn("主动推送：投递结果不明，不再自动重发",
					"message_id", c.ID, "delivery_id", c.DeliveryID, "failure", failureReason(res))
				if err := r.settle(ctx, c, "suppressed", "delivery_unknown", nil, deliveryUnknown, now, 0, report); err != nil {
					return
				}
				return
			}
			if err := r.settle(ctx, c, "pending", failureReason(res), nil, deliveryNotAttempted, now, r.retryAfter(c), report); err != nil {
				return
			}
			return
		}
		// 不可重试的失败（参数非法、凭据被拒、未配置等）落 cancelled：
		// 无限重试只会放大问题，也不会让用户收到这条消息。
		if err := r.settle(ctx, c, "cancelled", failureReason(res), nil, deliveryNotAttempted, now, 0, report); err != nil {
			return
		}
		report.Cancelled++

	default:
		report.Errors++
		r.logger().Error("主动推送：未知投递结果", "message_id", c.ID, "outcome", string(res.Outcome))
	}
}

// settle 是全部结算写入的唯一入口。
//
// 集中在一处的理由：每一种投递结局都必须带凭证、都必须能识别"回执迟到"，
// 散开写就一定会漏掉某一种，而漏掉的那一种就是"旧执行者覆盖新租约"。
func (r *Runner) settle(ctx context.Context, c Claim, state, reason string, deliveredAt *time.Time, status string, now time.Time, retryAfter time.Duration, report *RunReport) error {
	err := r.Ledger.SettleProactive(ctx, SettleRequest{
		ID:             c.ID,
		Token:          c.ClaimToken,
		State:          state,
		SuppressReason: reason,
		DeliveredAt:    deliveredAt,
		DeliveryStatus: status,
		At:             now,
		RetryAfter:     retryAfter,
	})
	if err != nil {
		// 迟到的回执（租约已被回收/接管）不是"消息发失败"，而是"本执行者太慢"。
		// 分开计数：把它算进 Errors 会让容量问题看起来像数据问题。
		if isStaleClaimError(err) {
			report.Stale++
		}
		r.recordError(report, "结算主动消息失败", c.ID, err)
		return err
	}
	return nil
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
	// 当前这条已经发起过投递（BeginProactiveDelivery 在投递前就写了），
	// 因此这里如实标成结果不明；只有当它确实没发出去时才按普通取消处理。
	status := deliveryUnknown
	if err := r.settle(ctx, c, "cancelled", "device_invalid", nil, status, now, 0, report); err != nil {
		return
	}
	report.Cancelled++
}

// releaseAll 释放一批领取（尚未有任何投递动作时使用）。
func (r *Runner) releaseAll(ctx context.Context, claims []Claim, reason string, now time.Time, report *RunReport) {
	for _, c := range claims {
		if err := r.settle(ctx, c, "pending", reason, nil, deliveryNotAttempted, now, r.retryAfter(c), report); err != nil {
			continue
		}
		report.Deferred++
	}
}

// releaseUnprocessed 只释放没有出现在回执里的那些行。
//
// 调度器返回 error 时可能已经发出了一部分，把已发的也释放会报"凭证不匹配"
// 并掩盖真实结果；按 DedupeKey 排除已处理行才是诚实的做法。
func (r *Runner) releaseUnprocessed(ctx context.Context, deliveries []preparedDelivery, results []DeliveryResult, reason string, now time.Time, report *RunReport) {
	handled := make(map[string]bool, len(results))
	for _, res := range results {
		handled[res.DedupeKey] = true
	}
	for _, d := range deliveries {
		if handled[d.claim.DedupeKey] {
			continue
		}
		if err := r.settle(ctx, d.claim, "pending", reason, nil, deliveryNotAttempted, now, r.retryAfter(d.claim), report); err != nil {
			continue
		}
		report.Deferred++
	}
}

// buildItem 把一条领取与判定事实翻译成调度器输入。
//
// own 是本轮该用户领取到的总条数。
//
// 为什么用 DeliveredToday + ReservedToday - own 而不是只传 DeliveredToday：
// 调度器看到的 History.DeliveredToday 语义是"当日已经消费掉的额度"，而在途预留
// （含别的调度进程刚领走、以及本进程这一批）必须一并计入——否则两个并发调度进程
// 都会以为额度还有余量。减掉 own 是因为本批自己刚领的这些正要被判定，
// 把它们算成"已消费"会让整批被预算误抑制。
//
// 为什么不再单独加 UnknownToday：结果不明的行保持 pending 且持有租约，
// 本来就落在 ReservedToday 里；重复计入等于把一次不确定的消息算成两次消费。
func (r *Runner) buildItem(c Claim, facts HistoryFacts, own int) Item {
	otherClaims := facts.ReservedToday - own
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
			ID:        c.ID,
			Kind:      c.Kind,
			DedupeKey: c.DedupeKey,
			// DeliveryID 是稳定投递标识：重试同一条时它不变，供应商侧按它做幂等/对账。
			DeliveryID:  c.DeliveryID,
			Title:       c.Title,
			Body:        c.Body,
			DeepLink:    c.DeepLink,
			ScheduledAt: c.ScheduledAt,
			ExpiresAt:   c.ExpiresAt,
			Data:        c.Data,
		},
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

// locationOf 返回用户时区：优先用显式注入的 LocationOf（测试与单一来源场景），
// 否则回退到存储层的按用户查询。
//
// 取不到时必须回退 **UTC** 而不是服务器本地时区：服务器时区与用户无关，
// 同一份数据在不同机房会算出不同的"今天"，那是不可审计的。
func (r *Runner) locationOf(ctx context.Context, userID string) *time.Location {
	if r.LocationOf != nil {
		if loc := r.LocationOf(userID); loc != nil {
			return loc
		}
		return time.UTC
	}
	if r.LocationSource != nil {
		if loc, err := r.LocationSource(ctx, userID); err == nil && loc != nil {
			return loc
		}
	}
	return time.UTC
}

// locationLookup 把"按用户取时区"包成存储层领取请求需要的纯函数形式。
//
// 领取查询是同步的，不能在里面做 I/O；这里**只使用已经注入的 LocationOf**，
// 拿不到就返回 nil（存储层按 UTC 算边界）。之所以不在这里回落到 LocationSource：
// 那会把一次网络查询塞进每个用户的领取路径里，且错误无从上报。
// 生产装配同时提供 LocationOf，因此不存在"只有 LocationSource"的情形。
func (r *Runner) locationLookup(_ context.Context) func(string) *time.Location {
	if r.LocationOf != nil {
		return r.LocationOf
	}
	return nil
}

// retryAfter 按已领取次数给出退避：30s、1m、2m、4m……封顶 30 分钟。
//
// 固定短退避会让供应商抖动期间每条消息每轮都重试一次，把额度与供应商配额一起烧掉；
// 指数退避让重试密度随失败次数下降。
func (r *Runner) retryAfter(c Claim) time.Duration {
	d := DefaultRetryBackoff
	for i := 1; i < c.AttemptCount; i++ {
		d *= 2
		if d >= MaxRetryBackoff {
			return MaxRetryBackoff
		}
	}
	return d
}

// isStaleClaimError 判断错误是否属于"这条已经不属于本执行者"。
//
// 按错误文本匹配是刻意的：proactive 包不 import internal/store（端口隔离），
// 拿不到 store 的错误值；文案由 store 层固定，单点定义在 store.ErrProactiveClaimMismatch /
// ErrProactiveLeaseExpired 上，改文案会同时改这里的匹配串（有测试覆盖）。
func isStaleClaimError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "领取凭证不匹配") || strings.Contains(msg, "领取租约已过期")
}

// deliveryAmbiguous 判断这次可重试失败是否"供应商可能已经受理"。
//
// 只有明确被供应商拒绝（限流 429 / 供应商凭据被拒）才算确定没发出去；
// 网络错误与 5xx 无法确定请求是否已经到达，必须当成"结果不明"。
func (r *Runner) deliveryAmbiguous(res DeliveryResult) bool {
	if res.Failure == nil {
		return true
	}
	switch res.Failure.Kind {
	case push.FailureRateLimited:
		// 供应商明确回了限流：请求被拒，没发出去。
		return false
	case push.FailureProviderUnavailable:
		// 5xx / 网络不可达：无法确定供应商是否已经受理。
		return true
	default:
		return true
	}
}

// claimedBy 给出本执行者标识。
func (r *Runner) claimedBy() string {
	if strings.TrimSpace(r.ClaimedBy) != "" {
		return r.ClaimedBy
	}
	return "daycued"
}

// lease 归一化租约时长。
func (r *Runner) lease() time.Duration {
	if r.Lease > 0 {
		return r.Lease
	}
	return DefaultLease
}

// maxAttempts 归一化重试上限。
func (r *Runner) maxAttempts() int {
	if r.MaxAttempts > 0 {
		return r.MaxAttempts
	}
	return DefaultMaxAttempts
}

// recoverLimit 归一化单轮回收上限。
func (r *Runner) recoverLimit() int {
	if r.RecoverLimit > 0 {
		return r.RecoverLimit
	}
	return r.claimLimit()
}

// dailyBudgetFor 返回某用户当日允许发出的条数。
//
// 优先用显式的 DailyBudgetFor；否则按调度策略的 DailyBudget。策略为 0（不限）时
// 返回 0，存储层会取自己的兜底上限——绝不返回"不限"，那等于放弃限额保护。
func (r *Runner) dailyBudgetFor(userID string) int {
	if r.DailyBudgetFor != nil {
		return r.DailyBudgetFor(userID)
	}
	if r.Scheduler == nil {
		return 0
	}
	return r.Scheduler.Policy.DailyBudget
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
