package proactive

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/push"
)

// DeliveryOutcome 是一条候选消息本次调度的结局。
//
// 刻意把 suppressed / deferred / failed 分开，而不是合并成"没发出去"：
// 三者的后续动作完全不同 —— 放弃、下次再来、以及需要排查或重试。
// 把它们糊在一起，用户会看到"发送失败"，而实际只是今天已经发够了。
type DeliveryOutcome string

const (
	// OutcomeAccepted 表示推送服务已受理。**不是**用户已收到，更不是已读。
	OutcomeAccepted DeliveryOutcome = "accepted"
	// OutcomeDelivered 表示推送服务回报设备已确认送达。
	OutcomeDelivered DeliveryOutcome = "delivered"
	// OutcomeSuppressed 表示按策略彻底放弃（超预算、冷却、重复、过期）。
	OutcomeSuppressed DeliveryOutcome = "suppressed"
	// OutcomeDeferred 表示只是推迟（未到点、静默时段），之后仍应重试。
	OutcomeDeferred DeliveryOutcome = "deferred"
	// OutcomeFailed 表示已经尝试投递但失败了。
	OutcomeFailed DeliveryOutcome = "failed"
)

// ErrNoSender 表示调度器没有可用的推送通道。
var ErrNoSender = errors.New("proactive: 未配置推送通道")

// Item 是一条待调度的候选消息。
type Item struct {
	// Candidate 是待判定的消息本体。
	Candidate Candidate
	// History 是判定所需事实，由调用方从存储读出。
	History History
	// Kind 是消息种类。Candidate 本身不含种类，而冷却判定是按种类做的，
	// 所以种类由调用方在 Item 上给出。
	Kind string
	// Message 是下发给客户端的通知内容。
	// ID / DedupeKey 留空时会从 Candidate 补齐，避免两处对不上导致去重失效。
	Message push.Message
}

// DeliveryResult 是一次调度的结果。
type DeliveryResult struct {
	Outcome DeliveryOutcome
	// Reason 在 suppressed / deferred 时说明原因，直接来自 Decide 的判定。
	Reason SuppressReason
	// Decision 保留完整判定，便于审计"为什么现在发/不发"。
	Decision Decision
	// DedupeKey / Kind 回填自入参，供调用方记账与批内累加。
	DedupeKey string
	Kind      string
	// Receipt 是推送回执；Outcome 为 OutcomeFailed 时 Failure 非空。
	Receipt push.Receipt
	Failure *push.Failure
}

// Sent 判断这次调度是否已经把消息交给了推送服务。
func (r DeliveryResult) Sent() bool {
	return r.Outcome == OutcomeAccepted || r.Outcome == OutcomeDelivered
}

// Failed 判断是否已经尝试但失败。
func (r DeliveryResult) Failed() bool { return r.Outcome == OutcomeFailed }

// Retryable 判断失败是否值得重试；只有失败且分类可重试时才为 true。
func (r DeliveryResult) Retryable() bool { return r.Failed() && r.Failure.Retryable() }

// DeviceInvalid 表示这次失败意味着设备令牌失效，调用方应停用该设备。
//
// 调度器把它透出来而不是自己处理：停用设备属于存储层的事，
// 让调度器直接改库会把推送重试和账号数据搅在一起。
func (r DeliveryResult) DeviceInvalid() bool { return r.Receipt.DeviceInvalid() }

// Scheduler 把"候选消息 + 策略判定"与"经推送通道真正发出"接在一起。
//
// 为什么必须有这一层：internal/proactive 原来只有纯函数 Decide，
// 判定完没有任何东西能真的把消息发出去；而 internal/push 只懂"发一条"，
// 不懂预算、静默时段与去重。调度器是这两半之间唯一缺失的环节：
//
//	候选 + 策略 --Decide--> 该不该发 --Sender--> 供应商回执 --> DeliveryResult
type Scheduler struct {
	Policy Policy
	// Sender 是推送通道。组装层在没有凭据时应显式传入 push.Unconfigured，
	// 让每次调度都得到明确的"未配置"失败，而不是静默什么都不做。
	Sender push.Sender
	// Now 可注入，便于测试固定时间基准。
	Now func() time.Time
	// LocationOf 给出用户所在时区：预算与静默时段都按用户本地自然日计算，
	// 用服务器时区会让跨时区用户的"今天"算错一整天。
	LocationOf func(userID string) *time.Location
}

// NewScheduler 校验策略与通道后构造调度器。
//
// 启动期就拒绝非法策略：宁可服务起不来，也不要在运行期给用户多发打扰。
func NewScheduler(p Policy, sender push.Sender, now func() time.Time) (*Scheduler, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	if sender == nil {
		return nil, ErrNoSender
	}
	if now == nil {
		now = time.Now
	}
	return &Scheduler{Policy: p, Sender: sender, Now: now}, nil
}

// Deliver 判定并投递一条候选消息。
//
// 返回值约定：**只有配置/编程错误才通过 error 返回**；推送失败一律体现在
// DeliveryResult（Outcome=failed 且 Failure 非空）。这样批量调度不会因为
// 一台设备的一次失败就中断其余消息，调用方也不会误以为"没报错就是发出去了"。
func (s *Scheduler) Deliver(ctx context.Context, target push.DeviceTarget, item Item) (DeliveryResult, error) {
	decision := Decide(s.Policy, item.Candidate, item.History, s.now(), s.location(target.UserID))
	res := DeliveryResult{
		Decision:  decision,
		Reason:    decision.Reason,
		DedupeKey: item.Candidate.DedupeKey,
		Kind:      item.Kind,
	}
	switch {
	case decision.Suppressed:
		res.Outcome = OutcomeSuppressed
		return res, nil
	case decision.Deferred:
		res.Outcome = OutcomeDeferred
		return res, nil
	}

	if s.Sender == nil {
		return res, ErrNoSender
	}

	msg := item.Message
	// 补齐标识：少了它，同一条消息重试时供应商侧会产出两条通知，
	// 用户会在同一件事上被打扰两次。
	if msg.ID == "" {
		msg.ID = item.Candidate.DedupeKey
	}
	if msg.DedupeKey == "" {
		msg.DedupeKey = item.Candidate.DedupeKey
	}
	if msg.DedupeKey == "" {
		msg.DedupeKey = msg.ID
	}
	if msg.ScheduledAt.IsZero() {
		msg.ScheduledAt = item.Candidate.ScheduledAt
	}
	if msg.ExpiresAt == nil {
		msg.ExpiresAt = item.Candidate.ExpiresAt
	}

	receipt, err := s.Sender.Send(ctx, target, msg)
	res.Receipt = receipt
	if err != nil {
		res.Failure, _ = push.FailureOf(err)
		if res.Failure == nil {
			// 不是推送失败（例如上层取消），如实归类为不可重试的普通失败。
			res.Failure = &push.Failure{Kind: push.FailurePermanent, Detail: err.Error()}
		}
		res.Outcome = OutcomeFailed
		return res, nil
	}

	switch receipt.Status {
	case push.StatusDelivered:
		res.Outcome = OutcomeDelivered
	default:
		// 供应商只回报"受理"时就是 accepted：不把它抬成 delivered，
		// 否则界面会显示"已送达"，而用户手机可能根本没亮过屏。
		res.Outcome = OutcomeAccepted
	}
	return res, nil
}

// RunDue 遍历一批候选消息，按 ScheduledAt 升序依次判定与投递。
//
// 三处顺序与状态是刻意的，不要随意改：
//  1. 按 ScheduledAt 升序：老提醒先发，否则源源不断产生的新消息会把旧提醒饿死。
//  2. 批内累加已发出的条数：Decide 是纯函数，若每条都用入参 History，
//     日预算 1 条的账号会在同一批里被发出多条。
//  3. 单条失败不影响其余：推送不是事务，一条失败就让整批中止，
//     等于让用户连本来能收到的提醒也一起错过。
func (s *Scheduler) RunDue(ctx context.Context, target push.DeviceTarget, items []Item) ([]DeliveryResult, error) {
	ordered := append([]Item(nil), items...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].Candidate.ScheduledAt.Before(ordered[j].Candidate.ScheduledAt)
	})

	results := make([]DeliveryResult, 0, len(ordered))
	for _, it := range ordered {
		effective := it
		effective.History = accumulateHistory(it.History, results, it.Candidate.DedupeKey, it.Kind, s.now())
		res, err := s.Deliver(ctx, target, effective)
		if err != nil {
			// 只有配置类错误才会走到这里；已经发出的消息结果必须带回去，
			// 否则调用方会以为整批都没发。
			return results, err
		}
		results = append(results, res)
	}
	return results, nil
}

// accumulateHistory 把本批次已经发出的消息并入判定事实。
//
// 只累加"确实发出去了"的那些（accepted / delivered）：
// 把失败或推迟也算成已发，会让同一批里后面的消息被无谓地压下去。
func accumulateHistory(base History, results []DeliveryResult, candidateKey, kind string, now time.Time) History {
	out := base
	for _, r := range results {
		if !r.Sent() {
			continue
		}
		out.DeliveredToday++
		if candidateKey != "" && r.DedupeKey == candidateKey {
			out.SameKeyDeliveredToday = true
		}
		if kind != "" && r.Kind == kind {
			out.LastDeliveredSameKind = now
		}
	}
	return out
}

// location 解析用户时区；取不到时退回 UTC（与 Decide 的默认一致），
// 而不是用服务器本地时区 —— 服务器时区与用户时区无关，用错会让预算在错误的时刻重置。
func (s *Scheduler) location(userID string) *time.Location {
	if s.LocationOf == nil {
		return time.UTC
	}
	if loc := s.LocationOf(userID); loc != nil {
		return loc
	}
	return time.UTC
}

func (s *Scheduler) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Describe 返回面向用户的中文说明，供界面直接显示。
func (r DeliveryResult) Describe() string {
	switch r.Outcome {
	case OutcomeAccepted:
		return "已提交给推送服务"
	case OutcomeDelivered:
		return "已送达设备"
	case OutcomeSuppressed:
		if r.Reason.Chinese() != "" {
			return r.Reason.Chinese()
		}
		return "已按策略取消"
	case OutcomeDeferred:
		return fmt.Sprintf("已推迟到 %s（%s）", r.Decision.DeliverAt.Format(time.RFC3339), r.Reason.Chinese())
	case OutcomeFailed:
		if r.Failure != nil {
			return r.Failure.Error()
		}
		return "推送失败"
	default:
		return string(r.Outcome)
	}
}
