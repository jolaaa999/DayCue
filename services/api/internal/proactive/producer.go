package proactive

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"
)

// 候选生产者：把「服务端真实看得见的业务事件」翻译成主动消息候选并写进账本。
//
// 与 Runner 的分工是刻意的。Runner 只回答「这条已经入账的候选现在该不该发」，
// Producer 只回答「哪些业务事件值得变成候选」。分开之后，才能在不碰预算/冷却
// 判定的前提下单独测试「会不会重复入队」——而重复入队正是这一层最容易出的错。
//
// 先说清这一层**不**生产什么，避免下次有人顺手加进来：
//
//   - **不生产 geo 类候选。** 服务端没有位置证据：坐标与进出围栏事件只在设备本地
//     产生，服务端既收不到坐标也收不到围栏广播。仅凭「该用户有一条地点规则」推不出
//     「他现在到了」，那属于编造位置结论。地点提醒只能由设备本地投递。
//   - **不生产 follow_up 类候选。** 课后追问是纯客户端链路：两端客户端都不同步
//     follow_up / course_instance（Android 只推 task 与 capture，iOS 只推
//     task / note / capture / course / memory），服务端根本看不到追问的存在与状态，
//     也就无从判断它是否已由本地送出。要真正接上必须先改同步协议，那是协议变更，
//     不是接线。在协议改之前，任何「服务端追问生产者」都只能靠猜，会直接违反
//     「同一追问不得两边同时安排」。
//
// 所以本层目前只生产两种：到点的任务提醒（reminder）与到点的记忆回顾（review）。
// 这两类的事件载体（task、memory）两端客户端都会同步，是服务端真正看得见的东西。

const (
	// KindReminder 任务提醒。取值必须与客户端 proactive_message.kind 的
	// CHECK 约束一致（'follow_up','geo','schedule','review','reminder'）。
	KindReminder = "reminder"
	// KindReview 记忆回顾。
	KindReview = "review"
)

// DefaultLookback 默认只处理最近两小时内到期的事件。
//
// 这个值与客户端 FollowUpPolicy.pickupGraceMinutes(120) 同源：设备离线一整天后
// 重开时，补一堆昨天的提醒比不提醒更糟。超过这个窗口的事件直接不生成候选，
// 而不是生成一条早已过期的候选去占一次预算。
const DefaultLookback = 2 * time.Hour

// DefaultProduceLimit 单轮最多处理多少条到期事件，防止首次接入时一次性灌满账本。
const DefaultProduceLimit = 200

// ErrProducerNotConfigured 表示生产者缺少必需依赖。
var ErrProducerNotConfigured = errors.New("proactive: 候选生产者未配置完整")

// DueEvent 是一条「已经到点、且服务端看得见」的业务事件。
type DueEvent struct {
	// UserID 事件归属用户。账本按用户隔离，缺了它就没有租户边界。
	UserID string
	// Kind 见 KindReminder / KindReview。
	Kind string
	// Ref 业务对象 id（task / memory 的 id）。它参与拼稳定去重键。
	Ref string
	// Title 通知标题。为空表示这条事件没有可读内容，生产者会跳过，
	// 而不是发一条空消息——push.Guard 也会以 empty_message 拒绝。
	Title string
	// Body 通知正文，可为空（客户端会用标题兜底）。
	Body string
	// DeepLink 点开通知后的落地位置，可为空。
	DeepLink string
	// OccurredAt 业务时刻（任务的 remind_utc / 记忆的 review_at），UTC。
	OccurredAt time.Time
}

// CandidateSource 提供到期事件。实现方负责按用户隔离、过滤墓碑、按时间窗与
// 条数上限查询。把过滤放在实现方而不是这里，是因为不同存储的过滤代价差别很大：
// 内存实现可以直接遍历，SQL 实现必须让索引吃得下条件。
type CandidateSource interface {
	DueEvents(ctx context.Context, from, to time.Time, limit int) ([]DueEvent, error)
}

// OutgoingCandidate 是一条即将写进账本的候选，含下发内容。
//
// 刻意不直接复用 store.ProactiveMessage：那样会让编排层反向依赖存储层的具体结构，
// 存储层一加列这里就要跟着改。映射由装配层做，见 cmd/daycued。
type OutgoingCandidate struct {
	UserID string
	Kind   string
	// DedupeKey 是稳定去重键，见 dedupeKeyFor。
	DedupeKey string
	// TargetRef 是冷却键。这里用业务对象 id，与客户端「target_ref 就是冷却键」的
	// 既有语义一致（见 store.ProactiveMessage 的说明），不塞正文。
	TargetRef string
	Title     string
	Body      string
	DeepLink  string
	// ScheduledAt 业务时刻。它已经过去，调度器会立刻发出并把这次发出算进当日预算。
	ScheduledAt time.Time
	// ExpiresAt 过期时刻；越过之后不再发送，也不再推迟。
	ExpiresAt *time.Time
}

// EnqueueSink 把候选写进账本。幂等由实现方保证：同一 (user, dedupe_key) 重复入队
// 不产生第二行，也不报错。生产者依赖这条保证来做「每轮轮询都不会重复打扰」。
type EnqueueSink interface {
	Enqueue(ctx context.Context, c OutgoingCandidate) error
}

// RouteOwner 回答「这条提醒该由谁投递」。
//
// 为什么必须是注入的端口而不是写死的判断：客户端本来就会为任务的 remind_utc 排本地
// 通知（Android 的 ReminderScheduler、iOS 的 NotificationService）。服务端若无条件
// 再推一条，用户会在同一时刻收到两次；反过来，客户端在后台被杀、设备长期离线时，
// 又只有服务端够得着他。这个判断依赖设备能力与活跃度，属于本层不该知道的事。
type RouteOwner interface {
	// ClientOwnsDelivery 返回 true 表示该用户有能自己投递的设备，服务端必须让路。
	// 第二个返回值是原因文本，落进日志与报告，用户问「为什么服务端没发」时能答上来。
	ClientOwnsDelivery(ctx context.Context, userID string, at time.Time) (bool, string, error)
}

// Producer 把到期事件变成账本里的候选。
type Producer struct {
	Source CandidateSource
	Sink   EnqueueSink
	Owner  RouteOwner
	// Now 可注入，便于测试跨午夜与时间窗边界。
	Now func() time.Time
	// Lookback 只处理最近这么久之内到期的事件，见 DefaultLookback。
	Lookback time.Duration
	// Limit 单轮条数上限。
	Limit  int
	Logger *slog.Logger
}

// ProduceReport 是一轮生产的结果，用于日志与测试断言。
type ProduceReport struct {
	// Considered 本轮从来源读到的事件数（去重前）。
	Considered int
	// Enqueued 真正写进账本的候选数。
	Enqueued int
	// ClientOwned 因为客户端自己会投递而让路的条数。
	ClientOwned int
	// Skipped 内容为空等不值得变成候选的条数。
	Skipped int
	// Errors 逐条记录的失败原因。单条失败不中断整轮：
	// 一个用户的设备查询失败不该拖住其他用户的提醒。
	Errors []string
}

// Start 按固定间隔反复运行生产过程，直到 ctx 结束。
//
// 与 Runner.Start 同形：先立刻跑一轮（进程刚起来时不该干等一个间隔），
// 之后按 ticker 跑。单轮错误只记日志，绝不退出循环——否则一次数据库抖动
// 就会让生产者永久停摆，而且外面看不出来。
//
// 它与 Runner 各跑各的循环而不合并：生产者只管把事件变成账本行，
// Runner 只管把账本行发出去。合并会让"生产者慢了"直接拖住"发送"。
// 本轮产出的行会在 Runner 的下一次 tick 被认领，间隔差一轮，不影响语义。
func (p *Producer) Start(ctx context.Context, interval time.Duration) {
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
	p.produceOnceLogged(ctx)

	for {
		select {
		case <-ctx.Done():
			p.logger().Info("主动候选生产已停止")
			return
		case <-ticker.C:
			p.produceOnceLogged(ctx)
		}
	}
}

// produceOnceLogged 执行一轮并把账目写进日志。
func (p *Producer) produceOnceLogged(ctx context.Context) {
	report, err := p.ProduceOnce(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		p.logger().Error("主动候选生产失败", "error", err.Error())
		return
	}
	// 一条都没产出时不打日志：调度间隔是分钟级，每次都打会淹没真正的异常。
	if report.Enqueued == 0 && report.ClientOwned == 0 && report.Skipped == 0 {
		return
	}
	p.logger().Info("主动候选生产完成",
		"considered", report.Considered,
		"enqueued", report.Enqueued,
		"client_owned", report.ClientOwned,
		"skipped", report.Skipped,
		"errors", len(report.Errors),
	)
}

// ProduceOnce 跑一轮生产。
//
// 返回 error 只在「整轮没法开始」时非空（来源查询失败、依赖缺失）；
// 单条事件的失败记进 Report.Errors，不冒泡——否则一条坏数据会永久卡住整条链路。
func (p *Producer) ProduceOnce(ctx context.Context) (ProduceReport, error) {
	var rep ProduceReport
	if p.Source == nil || p.Sink == nil || p.Owner == nil {
		return rep, ErrProducerNotConfigured
	}
	now := p.now()
	lookback := p.Lookback
	if lookback <= 0 {
		lookback = DefaultLookback
	}
	events, err := p.Source.DueEvents(ctx, now.Add(-lookback), now, p.limit())
	if err != nil {
		return rep, fmt.Errorf("读取到期事件失败: %w", err)
	}
	rep.Considered = len(events)
	if len(events) == 0 {
		return rep, nil
	}

	// 按用户分组：执行方判定要查该用户的设备，逐条查等于把同一件事问很多遍。
	grouped := groupDueEventsByUser(events)
	for _, userID := range sortedDueUserIDs(grouped) {
		owned, reason, err := p.Owner.ClientOwnsDelivery(ctx, userID, now)
		if err != nil {
			// 判不出执行方时选择**不发**：漏发一条提醒只是少打扰一次，
			// 两边同时发则是用户明确禁止的重复打扰，两者代价不对称。
			rep.Errors = append(rep.Errors, fmt.Sprintf("用户 %s 执行方判定失败，本轮跳过: %v", userID, err))
			p.logger().Warn("执行方判定失败，本轮不下发该用户的候选", "user_id", userID, "error", err.Error())
			continue
		}
		if owned {
			rep.ClientOwned += len(grouped[userID])
			p.logger().Debug("客户端自己会投递，服务端让路", "user_id", userID, "reason", reason, "count", len(grouped[userID]))
			continue
		}
		for _, ev := range grouped[userID] {
			out, ok := outgoingCandidateFor(ev, lookback, rep.recordSkip)
			if !ok {
				continue
			}
			if err := p.Sink.Enqueue(ctx, out); err != nil {
				rep.Errors = append(rep.Errors, fmt.Sprintf("入队失败 %s/%s: %v", ev.Kind, ev.Ref, err))
				continue
			}
			rep.Enqueued++
		}
	}
	return rep, nil
}

// outgoingCandidateFor 把一条到期事件翻译成候选。
//
// 返回 false 表示这条事件不该变成候选（内容为空、身份缺失等），
// 并通过 onSkip 记一笔，方便排查「为什么这条提醒没来」。
func outgoingCandidateFor(ev DueEvent, window time.Duration, onSkip func(string)) (OutgoingCandidate, bool) {
	if strings.TrimSpace(ev.UserID) == "" || strings.TrimSpace(ev.Ref) == "" {
		onSkip("事件缺少用户或业务 id")
		return OutgoingCandidate{}, false
	}
	// 空标题不放行：一条没有内容的通知既是噪音，也会被 push.Guard 以
	// empty_message 拒绝，结果是白占一次预算还把行留在 pending 里。
	if strings.TrimSpace(ev.Title) == "" {
		onSkip("事件没有可读标题，不生成空消息")
		return OutgoingCandidate{}, false
	}
	if ev.Kind != KindReminder && ev.Kind != KindReview {
		// 白名单而不是黑名单：新增种类必须显式写进来，
		// 免得将来有人从上游带回一个客户端 CHECK 不认的 kind。
		onSkip("事件种类不在允许集合内: " + ev.Kind)
		return OutgoingCandidate{}, false
	}
	expires := ev.OccurredAt.Add(window)
	return OutgoingCandidate{
		UserID:      ev.UserID,
		Kind:        ev.Kind,
		DedupeKey:   dedupeKeyFor(ev),
		TargetRef:   ev.Ref,
		Title:       ev.Title,
		Body:        ev.Body,
		DeepLink:    ev.DeepLink,
		ScheduledAt: ev.OccurredAt,
		ExpiresAt:   &expires,
	}, true
}

// dedupeKeyFor 拼稳定去重键。
//
// **只由业务身份构成，绝不掺入时间。** 掺了时间的话每轮轮询都会算出一个新键，
// 幂等入队就形同虚设，同一件事会被反复打扰——这正是「不要每次轮询重复入队」
// 要防的东西。业务对象 id 已经是唯一身份，够用了。
func dedupeKeyFor(ev DueEvent) string {
	return ev.Kind + ":" + ev.Ref
}

func (p *Producer) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

func (p *Producer) limit() int {
	if p.Limit > 0 {
		return p.Limit
	}
	return DefaultProduceLimit
}

func (p *Producer) logger() *slog.Logger {
	if p.Logger != nil {
		return p.Logger
	}
	return slog.Default()
}

func groupDueEventsByUser(events []DueEvent) map[string][]DueEvent {
	grouped := make(map[string][]DueEvent, len(events))
	for _, ev := range events {
		grouped[ev.UserID] = append(grouped[ev.UserID], ev)
	}
	return grouped
}

// sortedDueUserIDs 让处理顺序确定，便于测试与日志比对（map 遍历顺序是随机的）。
func sortedDueUserIDs(grouped map[string][]DueEvent) []string {
	ids := make([]string, 0, len(grouped))
	for id := range grouped {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// recordSkip 把跳过原因写进报告。
func (r *ProduceReport) recordSkip(reason string) {
	r.Skipped++
	if len(r.Errors) < 20 {
		r.Errors = append(r.Errors, "跳过: "+reason)
	}
}
