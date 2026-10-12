package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ProactiveMessage 是主动消息账本里的一行，字段与 0001_init.sql + 0002 迁移的列一一对应。
//
// 为什么内容（Title/Body/DeepLink/Data）也落在服务端账本里：客户端账本可以不存标题正文
// （它在本地渲染），但服务端要发推送就必须知道发什么，否则组装出的 push.Message 是空内容，
// 会被 push.Guard 以 empty_message 拒绝。
// 特别注意 TargetRef 的真实语义是**冷却键**（例如 geo_rule 的 id），既不是设备、也不是正文；
// 设备由 DeviceID 承载。把正文塞进 TargetRef 会让冷却判定读到一段通知文案，属于误用。
type ProactiveMessage struct {
	ID             string
	UserID         string
	Kind           string
	DedupeKey      string
	TargetRef      string
	DeviceID       string
	State          string
	SuppressReason string
	Title          string
	Body           string
	DeepLink       string
	Data           map[string]string
	ScheduledAt    time.Time
	DeliveredAt    *time.Time
	ExpiresAt      *time.Time
	ClaimedAt      *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// ProactiveClaim 是一条已经被调用方占用的到期消息。
//
// ClaimedAt 是占用时刻，调用方据此排查"这条为什么一直没发出去"；
// 它只是标记，不带自动过期（见 0002 迁移的边界说明）。
type ProactiveClaim struct {
	ID          string
	UserID      string
	Kind        string
	DedupeKey   string
	TargetRef   string
	DeviceID    string
	Title       string
	Body        string
	DeepLink    string
	Data        map[string]string
	ScheduledAt time.Time
	ExpiresAt   *time.Time
	ClaimedAt   time.Time
}

// ProactiveHistoryFacts 是预算/冷却/去重判定所需的既有事实。
//
// 刻意用本包自己的扁平结构，而不是返回 proactive.History：
// internal/store 是最底层的数据访问包（与 internal/push 不反向依赖同样的理由），
// 让它 import internal/proactive 会把领域判定类型灌进存储层，也会让存储层依赖推送领域。
// 翻译成 proactive.History 由组装层负责。
//
// ClaimedToday 是**已被任何调度进程占用**的条数（含调用方自己刚认领的）：
// 它是"预算预留"在判定侧可见的唯一入口，调用方必须把它并入当日已消费额度，
// 否则并发的另一个调度进程看不见这次占用，两边都会以为额度还有余量。
type ProactiveHistoryFacts struct {
	// DeliveredToday 是该自然日已发出的条数（delivered_at 落在当天）。
	DeliveredToday int
	// ClaimedToday 是 claimed_at 落在当天的占用条数（含调用方自己认领的）。
	ClaimedToday int
	// LastDeliveredSameKey / LastDeliveredSameKind 是最近一次发出时刻；零值表示没发过。
	LastDeliveredSameKey  time.Time
	LastDeliveredSameKind time.Time
	// SameKeyDeliveredToday 表示同一去重键今天已经真正发出过。
	SameKeyDeliveredToday bool
}

// 账本状态取值，与 0001_init.sql 的 CHECK 约束逐一对应；不要在这里新增取值，
// 那会绕过数据库约束并让客户端、契约与存储三层说法不一致。
const (
	ProactiveStatePending    = "pending"
	ProactiveStateDelivered  = "delivered"
	ProactiveStateSuppressed = "suppressed"
	ProactiveStateExpired    = "expired"
	ProactiveStateCancelled  = "cancelled"
)

// proactiveStates 是允许写入账本的全部状态。
var proactiveStates = map[string]bool{
	ProactiveStatePending:    true,
	ProactiveStateDelivered:  true,
	ProactiveStateSuppressed: true,
	ProactiveStateExpired:    true,
	ProactiveStateCancelled:  true,
}

// ErrProactiveState 表示传入了账本不允许的状态取值。
var ErrProactiveState = errors.New("store: 主动消息状态非法")

// ErrProactiveDeliveredAt 表示试图在非 delivered 状态下写发出时间。
//
// 单独造一个错误而不是复用 ErrProactiveState：把"状态写错"与"宣称已送达"分开报，
// 后者更严重——它会让预算统计把一个从未发出的时刻算成已消费。
var ErrProactiveDeliveredAt = errors.New("store: 只有 delivered 状态才允许写发出时间")

// ProactiveStore 是主动消息账本的存储边界。
//
// 依赖方向：本接口只使用本包类型，绝不 import internal/proactive 或 internal/push。
// 与 UserStore/SyncStore 一样，内存测试替身与 PostgreSQL 实现都实现同一组语义。
type ProactiveStore interface {
	// EnqueueProactive 幂等入队：同一 (user_id, dedupe_key) 重复入队不产生第二行，也不报错。
	EnqueueProactive(ctx context.Context, m ProactiveMessage) error
	// ClaimDueProactive 在单个事务里取到期行、占用额度并标记已认领。
	// 并发的两个调度循环不会认领到同一行；limit 为单轮最多认领条数。
	ClaimDueProactive(ctx context.Context, now time.Time, limit int) ([]ProactiveClaim, error)
	// ReleaseProactive 释放占用但保留 pending，供被推迟/未到点/可重试失败重来。
	ReleaseProactive(ctx context.Context, id string, reason string, at time.Time) error
	// MarkProactiveResult 落终态；只有 delivered 才允许同时写 deliveredAt。
	MarkProactiveResult(ctx context.Context, id string, state string, suppressReason string, deliveredAt *time.Time, at time.Time) error
	// ProactiveHistory 汇总判定所需事实。loc 为空按 UTC，now 用于定当天的自然日边界。
	ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (ProactiveHistoryFacts, error)
	// MarkDeviceInvalid 停用一台令牌失效的设备；满足 push.DeviceInvalidator。
	MarkDeviceInvalid(ctx context.Context, userID, deviceID string, at time.Time) error
	// CancelPendingForDevice 把某台设备上尚未发出的 pending 行落成 cancelled，返回条数。
	CancelPendingForDevice(ctx context.Context, userID, deviceID string, at time.Time) (int, error)
	// AssignProactiveDevice 记录一条已认领消息实际路由到哪台设备，
	// 让后续的 CancelPendingForDevice 有据可依。
	AssignProactiveDevice(ctx context.Context, id string, deviceID string, at time.Time) error
}

// 编译期确认接口被实现；接口一旦改动这里会先编译失败，而不是等运行期。
var _ ProactiveStore = (*Postgres)(nil)

// validateProactiveState 拒绝未知状态，防止绕过数据库 CHECK 约束把脏值写进账本。
func validateProactiveState(state string) error {
	if !proactiveStates[state] {
		return fmt.Errorf("%w: %q", ErrProactiveState, state)
	}
	return nil
}

// validateProactiveResult 校验一次结果写入。
//
// 抽出独立函数是为了在没有真实数据库时也能对"只有 delivered 才允许写 delivered_at"
// 这条关键规则做回归：它一旦写错，预算会把从未发出的时刻算成已消费。
func validateProactiveResult(state string, deliveredAt *time.Time) error {
	if err := validateProactiveState(state); err != nil {
		return err
	}
	if deliveredAt != nil && state != ProactiveStateDelivered {
		return fmt.Errorf("%w: state=%s", ErrProactiveDeliveredAt, state)
	}
	return nil
}

// marshalProactiveData 把附加字段序列化成 JSONB 参数。
//
// 返回 string 而不是 []byte：lib/pq 会把 []byte 当 bytea 发送，写 jsonb 列会直接报类型错误。
func marshalProactiveData(data map[string]string) (string, error) {
	if len(data) == 0 {
		return "{}", nil
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return "", fmt.Errorf("store: 序列化主动消息附加字段失败: %w", err)
	}
	return string(raw), nil
}

// unmarshalProactiveData 读取 JSONB 附加字段；空值按空 map 处理，绝不返回 nil 让调用方空指针。
func unmarshalProactiveData(raw []byte) (map[string]string, error) {
	out := map[string]string{}
	if len(raw) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("store: 主动消息附加字段不是合法 JSON: %w", err)
	}
	return out, nil
}

// validateEnqueue 校验一条待入队消息的最小完整性。
//
// 入队是生产者的入口，脏数据一旦进账本就永远发不出去；宁可在这里拒绝。
func validateEnqueue(m ProactiveMessage) error {
	missing := make([]string, 0, 4)
	if strings.TrimSpace(m.ID) == "" {
		missing = append(missing, "id")
	}
	if strings.TrimSpace(m.UserID) == "" {
		missing = append(missing, "user_id")
	}
	if strings.TrimSpace(m.Kind) == "" {
		missing = append(missing, "kind")
	}
	if strings.TrimSpace(m.DedupeKey) == "" {
		missing = append(missing, "dedupe_key")
	}
	if m.ScheduledAt.IsZero() {
		missing = append(missing, "scheduled_at")
	}
	if len(missing) > 0 {
		return fmt.Errorf("store: 主动消息缺少必填字段 %s", strings.Join(missing, ", "))
	}
	return nil
}

// localDayBounds 返回 now 在 loc 时区下所在自然日的半开区间 [start, end)，两端都是 UTC。
//
// 用 AddDate 而不是加 24 小时：夏令时切换当天并不是 86400 秒，硬加会让边界错一小时。
func localDayBounds(now time.Time, loc *time.Location) (time.Time, time.Time) {
	if loc == nil {
		loc = time.UTC
	}
	local := now.In(loc)
	start := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
	return start.UTC(), start.AddDate(0, 0, 1).UTC()
}
