package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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
	// 以下字段属于领取协议，详见本文件顶部与 0003 迁移的说明。
	ClaimedBy         string
	ClaimToken        string
	LeaseExpiresAt    *time.Time
	AttemptCount      int
	DeliveryID        string
	DeliveryStatus    string
	DeliveryUnknownAt *time.Time
	BudgetWinStart    *time.Time
	// BudgetReserved 表示这一行当前占着预算窗口里的一个预留名额。
	// 显式布尔而不是"BudgetWinStart 非空"：一条从未被领取就被取消的行也会带窗口起点，
	// 用它推断会回退一个不存在的预留，把当天的额度账算坏。
	BudgetReserved bool
}

// ProactiveClaim 是一条已经被调用方领取到租约的到期消息。
//
// 三个字段是完整回执协议的核心，缺一不可：
//   - ClaimToken 是本次领取的凭证，调用方必须在结算时原样带回；
//   - LeaseExpiresAt 是租约截止，超时后的写入一律被拒；
//   - DeliveryID 是稳定投递标识，重试同一条时保持不变，可交给供应商做幂等/对账。
//
// ClaimedAt 仍是**首次占用时刻**（与 0002 的语义一致，租约回收不覆盖它），
// 便于回答"这条第一次被认领是什么时候"；本次租约的截止时刻看 LeaseExpiresAt。
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
	// ClaimToken 见上。
	ClaimToken string
	// ClaimedBy 是本次租约的持有者标识（调度进程自报），供排障与对账。
	ClaimedBy string
	// LeaseExpiresAt 是本次租约的截止时刻（UTC）。
	LeaseExpiresAt time.Time
	// AttemptCount 是累计领取次数（含本次）。
	AttemptCount int
	// DeliveryID 见上。
	DeliveryID string
	// DeliveryStatus 是领取时的交付确定性；正常领取总是"尚未发送"。
	DeliveryStatus string
	// UserOverBudget 表示该用户此刻还有到期行、但当日额度已经用完。
	// 它与"没有到期行"是两件事：前者说明策略在生效，后者说明没活可干。
	UserOverBudget bool
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
	// ClaimedToday 是当日窗口内已被领取（在途）的条数（含调用方自己认领的）。
	ClaimedToday int
	// ReservedToday 是当日预算窗口里的预留计数（delivered+reserved 中的后者），
	// 与 ClaimedToday 的区别：它按**预算窗口**统计，改时区不会让它漂移。
	ReservedToday int
	// UnknownToday 是当日"投递结果不明"的条数。它必须计入已消费额度：
	// 一条可能已经被供应商接受的消息，绝不能再占一次预算去发第二条。
	UnknownToday int
	// LastDeliveredSameKey / LastDeliveredSameKind 是最近一次发出时刻；零值表示没发过。
	LastDeliveredSameKey  time.Time
	LastDeliveredSameKind time.Time
	// SameKeyDeliveredToday 表示同一去重键今天已经真正发出过。
	SameKeyDeliveredToday bool
}

// 交付确定性取值，与 0003 迁移的 ck_proactive_delivery_status 逐一对应。
//
// 为什么要这一列，而不是继续只靠 state：state 的五个取值表达的是**业务终态**，
// 而"这条消息有没有可能已经被供应商接受"是**投递事实**，两者正交。
// 把它们混进 state 就得新增取值，那会同时牵动客户端、契约与数据库 CHECK；
// 更重要的是，它会掩盖一个必须被单独表达的事实——失败重试里有两种完全不同的失败：
// 一种是"确定没发出去"（限流、参数非法），另一种是"不知道发没发出去"（超时、5xx）。
// 后者盲目重发就是在打扰用户。
const (
	// ProactiveDeliveryNotAttempted 表示本次租约下尚未把消息交给供应商，可以安全重发。
	ProactiveDeliveryNotAttempted = "not_attempted"
	// ProactiveDeliverySending 表示本次已经发起投递、但结果还没回来。
	// 它必须**先于**那次调用写入，否则进程崩在调用中间时，恢复者会以为根本没发过。
	ProactiveDeliverySending = "sending"
	// ProactiveDeliveryUnknown 表示投递已发起但结果不可知，不得自动重发。
	ProactiveDeliveryUnknown = "attempted_unknown"
)

// proactiveDeliveryStatuses 是允许写入的交付确定性取值。
var proactiveDeliveryStatuses = map[string]bool{
	ProactiveDeliveryNotAttempted: true,
	ProactiveDeliverySending:      true,
	ProactiveDeliveryUnknown:      true,
}

// 结算状态：除了 pending（重新排队等待下次领取）之外，其余都必须是账本允许的终态。
const (
	// proactiveSettlePending 表示这次结算不落终态，把行放回待领取并进入退避。
	proactiveSettlePending = ProactiveStatePending
)

// 领取协议的错误。分成三个可判定入口，而不是一个笼统的"更新失败"：
// 调用方对它们的处置完全不同——凭证不符说明租约已经被别人接管（本进程必须放弃这条，
// 而不是重试），租约过期说明本进程干活太慢（可以重新领取），两者都不是"数据坏了"。
var (
	// ErrProactiveClaimMismatch 表示凭证与库里不匹配：这条已经不属于本执行者。
	//
	// 触发场景就是"旧执行者提交新租约的结果"——租约被回收后重新领取会换发 token，
	// 于是原执行者手里的凭证立刻失效。必须报错而不是静默成功，否则旧执行者会覆盖
	// 新租约的结论（例如把一条已经发出去的记成 pending，再发一次）。
	ErrProactiveClaimMismatch = errors.New("store: 领取凭证不匹配（租约已被他人接管）")
	// ErrProactiveLeaseExpired 表示凭证对得上但租约已经过期，拒绝写入。
	//
	// 为什么过期也要拒：过期意味着"这段时间里谁都不知道这条怎么了"，
	// 允许迟到的回执落库会让账本记录一个事后无法归因的结果。
	ErrProactiveLeaseExpired = errors.New("store: 领取租约已过期")
	// ErrProactiveNotClaimed 表示目标行当前没有有效租约（未被领取，或已落终态）。
	ErrProactiveNotClaimed = errors.New("store: 目标行当前未被领取")
	// ErrProactiveDeliveryStatus 表示传入了未知的交付确定性取值。
	ErrProactiveDeliveryStatus = errors.New("store: 交付确定性取值非法")
	// ErrProactiveTimeZone 表示传入的时区名不是合法的 IANA 时区。
	ErrProactiveTimeZone = errors.New("store: 时区名非法")
)

// ProactiveClaimRequest 是一次领取请求。
//
// 把参数收进结构体而不是继续加位置参数：领取需要的不只是 now 与 limit，
// 还有"谁在领"（领取者标识）、租约时长、重试上限与按用户的每日预算。
// 位置参数到第 6 个之后，调用点已经无法自查有没有传错。
type ProactiveClaimRequest struct {
	// Now 是本次领取的时间基准（UTC 或任意时区，内部统一按 UTC 处理）。
	Now time.Time
	// Limit 是单轮最多领取条数；<=0 视为不领取。
	Limit int
	// ClaimedBy 是领取者标识（例如 "daycued@host:pid"）。允许为空，但为空时排障会很难。
	ClaimedBy string
	// Lease 是租约时长；<=0 时用 DefaultProactiveLease。
	Lease time.Duration
	// MaxAttempts 是单条消息允许被领取的最大次数；<=0 时用 DefaultMaxAttempts。
	// 超过上限的行不再被领取，由 RecoverExpiredProactive 落成 expired。
	MaxAttempts int
	// DailyLimitFor 返回某用户当日允许发出的条数；<=0 时取 DefaultDailyLimit。
	// 为 nil 表示所有用户都用 DefaultDailyLimit。
	DailyLimitFor func(userID string) int
	// LocationFor 返回某用户时区；为 nil 或返回 nil 时按 UTC 计算自然日边界。
	// 领取必须按用户时区定"今天是哪一天"，否则跨时区用户的当日额度会算错一整天。
	LocationFor func(userID string) *time.Location
}

// 领取协议的默认参数。
const (
	// DefaultProactiveLease 是默认租约时长。
	//
	// 取值理由：一轮调度通常是秒级，但一次推送在重试策略下最长可能到分钟级；
	// 15 分钟既能让"进程崩溃后 15 分钟内自动回收"成立，又远大于正常一轮的耗时，
	// 不至于把还在干活的执行者的租约判过期。
	DefaultProactiveLease = 15 * time.Minute
	// DefaultMaxAttempts 是默认最大领取次数。
	//
	// 为什么是 4：一次正常投递 + 三次重试足够跨过供应商抖动；再多就说明问题不在抖动，
	// 继续重试只会反复占用当日额度。超过后落到 expired（明确终态），不再无限重试。
	DefaultMaxAttempts = 4
	// DefaultRetryBackoff 是失败重试的最小退避。
	DefaultRetryBackoff = 30 * time.Second
	// MaxRetryBackoff 是失败重试的退避上限。
	MaxRetryBackoff = 30 * time.Minute
	// DefaultDailyLimit 在调用方没有给出策略时的兜底每日上限。
	DefaultDailyLimit = 3
)

// 命名沿用 DefaultMaxAttempts 的写法，供调用方引用。
const (
	DefaultProactiveMaxAttempts = DefaultMaxAttempts
)

// ProactiveClaimBatch 是一次领取的结果。
//
// 为什么要返回 OverBudgetUsers：领取被预算挡住与"库里没有到期行"是两件不同的事。
// 前者说明策略生效了（不是故障），后者说明没活可干；把两者混成一个空列表，
// 排障时就无法回答"今天到底是因为预算不发、还是因为没消息"。
type ProactiveClaimBatch struct {
	// Claims 是本次成功领取到的行。
	Claims []ProactiveClaim
	// OverBudgetUsers 是"还有到期行、但当日额度已经用完"的用户。
	OverBudgetUsers []string
}

// ProactiveSettleRequest 是一次结算请求（落终态或重新排队）。
type ProactiveSettleRequest struct {
	// ID 是账本行 id。
	ID string
	// Token 是领取时拿到的凭证；必须原样带回。
	Token string
	// State 是目标状态：allowed 的账本状态，或 pending（表示重新排队）。
	State string
	// SuppressReason 只作审计，不改变可发送性。
	SuppressReason string
	// DeliveredAt 只在 state=delivered 时允许非空。
	DeliveredAt *time.Time
	// DeliveryStatus 是本次结算记录的交付确定性。
	DeliveryStatus string
	// At 是本次结算的时间基准。
	At time.Time
	// RetryAfter 是重新排队时的退避时长；只在 State=pending 时有意义。
	// <=0 时退避为 0（立即可以再次领取），调用方应传显式退避，避免热循环。
	RetryAfter time.Duration
}

// ProactiveRecoverResult 是一次租约回收的账目。
//
// 三个计数刻意分开：重新入队是正常回收，逾期作废是收敛，延长租约是"结果不明"的兜底。
// 合成一个数字会让"今天回收了 100 条"这种日志完全无法判断系统是否健康。
type ProactiveRecoverResult struct {
	// Requeued 是被放回待领取的行数（原执行者尚未发起投递）。
	Requeued int
	// Expired 是因超过重试上限而落成 expired 的行数。
	Expired int
	// Extended 是"结果不明"、只延长租约等待确认的行数。
	Extended int
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
//
// 领取协议的不变式（实现与测试都必须遵守）：
//  1. 一次领取在同一事务里完成"按用户限额预留额度 + 写租约 + attempt_count+1"；
//  2. 只有 (claim_token 匹配 且 租约未过期) 的写入才被接受，否则返回可判定错误；
//  3. 行上的 budget_win_start 记住预留发生在哪个预算窗口，释放/结算按它精确回退，
//     用户改时区不会让预留值泄漏。
type ProactiveStore interface {
	// EnqueueProactive 幂等入队：同一 (user_id, dedupe_key) 重复入队不产生第二行，也不报错。
	EnqueueProactive(ctx context.Context, m ProactiveMessage) error
	// ClaimDueProactive 领取到期行：原子地按用户当日限额预留额度，并写下一段有主、
	// 有期限的租约，返回领取凭证。并发的调度进程既不会领到同一行，也不会合计超发。
	ClaimDueProactive(ctx context.Context, req ProactiveClaimRequest) (ProactiveClaimBatch, error)
	// SettleProactive 结算一条已领取的行。
	//
	// Token 必须与库中一致且租约未过期，否则返回 ErrProactiveClaimMismatch /
	// ErrProactiveLeaseExpired，且**不改动任何状态**——旧执行者不得提交新租约的结果。
	// State 为 pending 表示重新排队（配合 RetryAfter 退避），其余按终态处理并回退预留额度。
	SettleProactive(ctx context.Context, req ProactiveSettleRequest) error
	// RecoverExpiredProactive 回收过期租约：
	// 尚未发起投递的行放回待领取；已达重试上限的落 expired；
	// 投递结果不明的只延长租约（宁可暂时不发，也不重复打扰）。
	RecoverExpiredProactive(ctx context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int) (ProactiveRecoverResult, error)
	// RenewProactiveLease 续租（仅限凭证匹配且当前租约未过期）。长时间批量发送时可以中途续，
	// 但**不允许**复活已经过期的租约：那会让"过期即可回收"的保证失效。
	RenewProactiveLease(ctx context.Context, id string, token string, now time.Time, lease time.Duration) (time.Time, error)
	// BeginProactiveDelivery 在把消息交给供应商**之前**记录"本次已发起投递"。
	//
	// 必须先写后发：进程若崩在发送调用中间，恢复者看到的应当是"结果不明"而不是
	// "还没发过"——后者会导致盲目重发。
	BeginProactiveDelivery(ctx context.Context, id string, token string, at time.Time) error
	// ProactiveHistory 汇总判定所需事实。loc 为空按 UTC，now 用于定当天的自然日边界。
	ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (ProactiveHistoryFacts, error)
	// UserLocation 返回用户时区；未知或非法时回退 UTC（见 0003 迁移的说明）。
	UserLocation(ctx context.Context, userID string) (*time.Location, error)
	// SetUserTimeZone 写入用户 IANA 时区名；空串表示清空为"未知"（读时回退 UTC）。
	SetUserTimeZone(ctx context.Context, userID string, tz string, at time.Time) error
	// MarkDeviceInvalid 停用一台令牌失效的设备；满足 push.DeviceInvalidator。
	MarkDeviceInvalid(ctx context.Context, userID, deviceID string, at time.Time) error
	// CancelPendingForDevice 把某台设备上**尚未发送**的 pending 行落成 cancelled，返回条数。
	// 已经发起投递（含结果不明）的行不会在这里被抹掉，它们必须走结算路径收口。
	CancelPendingForDevice(ctx context.Context, userID, deviceID string, at time.Time) (int, error)
	// AssignProactiveDevice 记录一条已领取消息实际路由到哪台设备，
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

// validateDeliveryStatus 拒绝未知的交付确定性取值，防止绕过 0003 迁移的 CHECK 约束。
func validateDeliveryStatus(status string) error {
	if !proactiveDeliveryStatuses[status] {
		return fmt.Errorf("%w: %q", ErrProactiveDeliveryStatus, status)
	}
	return nil
}

// claimLease 归一化租约时长：0 或负数取默认值。
//
// 归一化放在这里而不是各实现里各写一遍：租约为 0 会让"立即过期"，等于没有租约，
// 于是刚领取的行立刻可被第二个调度进程抢走并重复发送。
func claimLease(d time.Duration) time.Duration {
	if d <= 0 {
		return DefaultProactiveLease
	}
	return d
}

// claimMaxAttempts 归一化重试上限。上限必须有界，否则"封顶"这件事根本不成立。
func claimMaxAttempts(n int) int {
	if n <= 0 {
		return DefaultMaxAttempts
	}
	return n
}

// retryBackoff 按已领取次数给出退避时长：30s、1m、2m、4m……封顶 30 分钟。
//
// 为什么要指数退避而不是固定一小段：一次供应商抖动期间，固定短退避会让每条消息
// 每轮都重试一次，把额度与供应商配额一起烧掉；指数退避让重试密度随失败次数下降。
func retryBackoff(attempt int) time.Duration {
	if attempt <= 1 {
		return DefaultRetryBackoff
	}
	d := DefaultRetryBackoff
	for i := 1; i < attempt; i++ {
		d *= 2
		if d >= MaxRetryBackoff {
			return MaxRetryBackoff
		}
	}
	return d
}

// newClaimToken 生成一次领取的凭证。
//
// 用随机值而不是"行 id + 尝试次数"这类可推导的值：凭证是**唯一的持有证明**，
// 可推导的值意味着第三方只要知道 id 就能伪造出当前有效的凭证。
// 它不需要不可猜（没有对外暴露面），但也没有理由做成可推导的。
func newClaimToken() string {
	return "ctk_" + randomToken(16)
}

// newDeliveryID 生成稳定投递标识，"del_" 前缀让日志里一眼能与领取凭证区分。
func newDeliveryID() string {
	return "del_" + randomToken(16)
}

// randomToken 读取 n 字节随机数并编码成十六进制；读不到随机数时直接 panic。
//
// 为什么 panic 而不是退回时间戳：拿不到随机数说明运行环境已经坏了，
// 用可预测的值继续生成凭证会造成"两个执行者拿到同一凭证"的静默错误，
// 那比当场崩掉难查得多。
func randomToken(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		panic(fmt.Sprintf("store: 生成随机标识失败: %v", err))
	}
	return hex.EncodeToString(buf)
}

// normalizeTimeZone 校验并规范化 IANA 时区名。
//
// 空串是合法的，语义是"未知"，读的时候回退 UTC；非空则必须是系统能识别的时区名，
// 否则写进库的值在读取时会被静默忽略，用户以为自己设了时区、实际按 UTC 计算。
func normalizeTimeZone(tz string) (string, error) {
	name := strings.TrimSpace(tz)
	if name == "" {
		return "", nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil || loc == nil {
		return "", fmt.Errorf("%w: %q", ErrProactiveTimeZone, name)
	}
	return loc.String(), nil
}

// resolveTimeZone 把库里的时区名解析成 *time.Location，无法识别时回退 UTC。
//
// 回退而不是报错：已知坏数据的账号不该让整个调度循环失败并波及所有其他用户；
// 但回退必须**可观测**（调用方按 UTC 计算时能得到确定的结论），而不是猜一个时区。
func resolveTimeZone(tz string) *time.Location {
	name := strings.TrimSpace(tz)
	if name == "" {
		return time.UTC
	}
	loc, err := time.LoadLocation(name)
	if err != nil || loc == nil {
		return time.UTC
	}
	return loc
}
