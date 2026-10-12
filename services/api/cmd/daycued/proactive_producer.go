package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/config"
	"github.com/jolaaa999/DayCue/services/api/internal/proactive"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// 主动候选生产者的装配。
//
// 单独一个文件而不是并进 proactive.go，是因为这条链路上只有一处需要看**客户端上报的能力**：
// 「这条提醒到底该由客户端本地投递还是由服务端推送」。把它隔离出来，
// 是为了让这条判断有唯一的落点，也让它能在没有数据库的情况下被单测覆盖。

// reminderCapabilityKey 是「这台设备有能力发出通知」的能力键。
//
// 取值与两个客户端实际上报的键一致（iOS DeviceCapabilities.notifications、
// Android CapabilityReport.notificationsAllowed）。刻意复用既有键而不是新造一个
// `server_fallback` 之类的偏好开关：那属于产品范围，本轮不新增。
const reminderCapabilityKey = "notifications"

// deviceLister 只暴露门控需要的那一个查询，便于用替身测试。
type deviceLister interface {
	DevicesByUser(ctx context.Context, userID string) ([]store.Device, error)
}

// deviceRouteOwner 依据客户端上报的设备能力判断投递执行方。
//
// 判定规则与理由：
//
//	只要该用户**有任何一台**设备上报了通知能力，就认定客户端会自己本地投递，
//	服务端必须让路——否则同一条提醒会在同一时刻响两次，而这正是要防的事。
//
//	只有当所有设备都没有上报该能力时，服务端才接管。这个条件不是形式主义：
//	iOS 客户端在能力未知时**如实省略**（DeviceCapabilities.unknown.wire 为空），
//	Android 也可能因为探测失败而不上报。也就是说「没有任何设备声称能投递」
//	是一个会真实出现的状态，此时客户端从未承诺过负责本地投递，
//	服务端不接管就等于这条提醒彻底没人发。
//
// 这条规则的边界（如实记录）：
//   - 它无法判断客户端**排上了但没有响**（权限被中途关掉、进程被杀）。
//     服务端看不到客户端本地的排期结果，这一类只能靠客户端下次启动时自愈。
//   - 「设备上报了通知能力」不等于「它真的排上了」。所以这里宁可漏发也不重发：
//     漏发是少打扰一次，重发是用户明确禁止的重复打扰，两者代价不对称。
type deviceRouteOwner struct {
	devices deviceLister
}

func (o deviceRouteOwner) ClientOwnsDelivery(ctx context.Context, userID string, _ time.Time) (bool, string, error) {
	devices, err := o.devices.DevicesByUser(ctx, userID)
	if err != nil {
		return false, "", fmt.Errorf("读取用户设备失败: %w", err)
	}
	if len(devices) == 0 {
		return false, "该用户没有登记任何设备，服务端是唯一可能的投递方", nil
	}
	for _, d := range devices {
		if d.Capabilities[reminderCapabilityKey] {
			return true, fmt.Sprintf("设备 %s 上报可自行投递（%s=true），服务端让路", d.ID, reminderCapabilityKey), nil
		}
	}
	return false, "所有设备都没有上报通知能力（能力未知或探测失败），服务端接管", nil
}

// storeEventSource 把存储层的到期事件翻译成编排层的事件。
//
// 两边的类型刻意不共用：存储层不该依赖编排层，映射只发生在装配层。
type storeEventSource struct {
	pg *store.Postgres
}

func (s storeEventSource) DueEvents(ctx context.Context, from, to time.Time, limit int) ([]proactive.DueEvent, error) {
	rows, err := s.pg.DueProactiveEvents(ctx, from, to, limit)
	if err != nil {
		return nil, err
	}
	out := make([]proactive.DueEvent, 0, len(rows))
	for _, r := range rows {
		out = append(out, proactive.DueEvent{
			UserID:     r.UserID,
			Kind:       r.Kind,
			Ref:        r.Ref,
			Title:      r.Title,
			Body:       r.Body,
			DeepLink:   r.DeepLink,
			OccurredAt: r.OccurredAt,
		})
	}
	return out, nil
}

// ledgerEnqueueSink 把候选写进账本。
//
// 幂等完全交给账本的 UNIQUE(user_id, dedupe_key)：生产者每轮轮询都会再调用一次，
// 靠的就是这里重复调用不会产生第二行。所以这里不做任何"先查再插"的判断——
// 那种写法在并发下反而会漏。
type ledgerEnqueueSink struct {
	pg  *store.Postgres
	now func() time.Time
}

func (s ledgerEnqueueSink) Enqueue(ctx context.Context, c proactive.OutgoingCandidate) error {
	now := s.now().UTC()
	msg := store.ProactiveMessage{
		ID:          newProactiveRowID(),
		UserID:      c.UserID,
		Kind:        c.Kind,
		DedupeKey:   c.DedupeKey,
		TargetRef:   c.TargetRef,
		State:       store.ProactiveStatePending,
		Title:       c.Title,
		Body:        c.Body,
		DeepLink:    c.DeepLink,
		ScheduledAt: c.ScheduledAt.UTC(),
		ExpiresAt:   c.ExpiresAt,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	return s.pg.EnqueueProactive(ctx, msg)
}

// newProactiveProducer 组装生产者。source 与 sink 共用同一个 Postgres。
func newProactiveProducer(cfg config.Config, pg *store.Postgres) (*proactive.Producer, error) {
	if pg == nil {
		return nil, fmt.Errorf("主动候选生产者需要数据库连接")
	}
	now := time.Now
	return &proactive.Producer{
		Source:   storeEventSource{pg: pg},
		Sink:     ledgerEnqueueSink{pg: pg, now: now},
		Owner:    deviceRouteOwner{devices: pg},
		Now:      now,
		Lookback: cfg.Push.ProduceLookback,
		Limit:    cfg.Push.ProduceLimit,
	}, nil
}

// newProactiveRowID 生成账本行的主键。
//
// 用随机值而不是「去重键的哈希」：去重键只保证 (user, dedupe_key) 唯一，
// 两台设备上的同 id 业务对象在同一个用户下本来就该是同一行；
// 而主键只需要唯一，不需要可推导。拿不到随机数就 panic——继续用一个可预测的
// 主键会造成静默的主键冲突，比当场崩掉难查得多（与 store.randomToken 同一取舍）。
func newProactiveRowID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		panic(fmt.Sprintf("daycued: 生成主动消息主键失败: %v", err))
	}
	return "pm_" + hex.EncodeToString(buf)
}
