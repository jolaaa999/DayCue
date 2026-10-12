// Package push 把"用户该收到的一条主动消息"投递给具体设备通道（APNs / FCM）。
//
// 设计取舍：
//   - 供应商只负责传输。**"供应商已受理"与"用户已读"是两件完全不同的事**，
//     所以回执状态只有 accepted / delivered / failed 三种：服务端没有能力知道
//     用户是否读过，凭空造一个 read 状态就是欺骗用户。
//   - 没有凭据时返回明确的"未配置"错误（ErrNotConfigured），绝不静默成功 ——
//     静默成功会让用户以为提醒已经发出，实际什么都没发生。
//   - "能不能重试"只在 FailureKind 上判定一次，不散落到各家供应商实现里：
//     同一类失败在 APNs 与 FCM 上必须得到相同的结论。
//   - 令牌失效（APNs 410 Unregistered / FCM UNREGISTERED）不算"发送失败"，
//     而是"这台设备不该再收推送"。它必须能被上报出去，让调用方停用该设备，
//     否则每次调度都会对着一台不存在的设备重试。
package push

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Platform 是设备平台。取值与 store.Device.Platform、0001_init.sql 的 CHECK 约束一致，
// 这里单独定义一份是为了让 push 包不依赖存储层（换存储实现时不用改推送代码）。
type Platform string

const (
	PlatformIOS     Platform = "ios"
	PlatformAndroid Platform = "android"
	PlatformMacOS   Platform = "macos"
	PlatformUnknown Platform = "unknown"
)

// ParsePlatform 把存储层的平台字符串转成 Platform。
// 认不出的值一律归为 unknown，由调用方决定 unknown 算不算"通道未配置"。
func ParsePlatform(s string) Platform {
	switch Platform(strings.TrimSpace(strings.ToLower(s))) {
	case PlatformIOS:
		return PlatformIOS
	case PlatformAndroid:
		return PlatformAndroid
	case PlatformMacOS:
		return PlatformMacOS
	default:
		return PlatformUnknown
	}
}

// DeviceTarget 描述一条通知要发到哪台设备。
//
// 没有把 store.Device 直接搬过来：调度层只需要这四个字段，
// 传整条设备记录会把 last_seen_at、capabilities 之类无关状态带进推送实现。
type DeviceTarget struct {
	UserID   string
	DeviceID string
	Platform Platform
	// Token 是 APNs device token 或 FCM registration token。
	// 为空表示这台设备从未上报过推送令牌，属于"不可投递"，不是"发送失败"。
	Token string
}

// Message 是一条待下发的通知内容。
type Message struct {
	// ID 是服务端账本里的消息标识（proactive_message.id），供应商回执据此对账。
	ID string
	// Kind 是消息种类，仅用于日志与排查，不参与投递判定。
	Kind string
	// DedupeKey 用于幂等：同一条消息重试时供应商侧不应产生两条通知。
	// APNs 映射到 apns-collapse-id，FCM 映射到 android.collapse_key。
	DedupeKey string
	Title     string
	Body      string
	// DeepLink 是点击后打开的客户端路由。
	DeepLink string
	// ScheduledAt 是业务希望发出的时刻，仅作为供应商侧的展示依据。
	ScheduledAt time.Time
	// ExpiresAt 为空表示不过期。过期之后**不得投递**：一条过期的提醒比不提醒更糟。
	ExpiresAt *time.Time
	// Data 是随通知下发的附加字段。值必须是字符串：APNs 自定义字段与 FCM data
	// 都只接受字符串，放别的类型会被供应商直接拒绝，届时很难归因。
	Data map[string]string
}

// Status 是投递状态。**没有 read**，见包注释。
type Status string

const (
	// StatusAccepted 表示供应商已受理请求。这不等于设备收到，更不等于用户看到。
	StatusAccepted Status = "accepted"
	// StatusDelivered 表示供应商回报设备侧已确认送达。只有供应商明确给出这个信号才能用。
	StatusDelivered Status = "delivered"
	StatusFailed    Status = "failed"
)

// FailureKind 是一次投递失败的原因分类。
type FailureKind string

const (
	// FailureNotConfigured 表示这条通道没有可用凭据。原因是缺少运维配置，
	// 不是用户设备的问题：重试一万次也不会成功，但绝不能谎报成功。
	FailureNotConfigured FailureKind = "not_configured"
	// FailureUnsupportedPlatform 表示没有任何 Sender 认领该平台。
	FailureUnsupportedPlatform FailureKind = "unsupported_platform"
	// FailureMissingToken 表示设备没有推送令牌。
	FailureMissingToken FailureKind = "missing_token"
	// FailureInvalidToken 表示供应商明确告知令牌失效。需要连带停用设备。
	FailureInvalidToken FailureKind = "invalid_token"
	// FailureEmptyMessage 表示标题与正文都为空 —— 发出去是一条看不见的通知。
	FailureEmptyMessage FailureKind = "empty_message"
	// FailureExpired 表示消息已经过期。
	FailureExpired FailureKind = "expired"
	// FailureRateLimited 表示被供应商限流，稍后重试有意义。
	FailureRateLimited FailureKind = "rate_limited"
	// FailureProviderUnavailable 表示供应商侧故障（5xx / 网络不可达），可重试。
	FailureProviderUnavailable FailureKind = "provider_unavailable"
	// FailureProviderAuth 表示服务端凭据被供应商拒绝（密钥错、过期、topic 不匹配）。
	// 这是运维问题，重试同一次请求没有意义，必须先把凭据修好。
	FailureProviderAuth FailureKind = "provider_auth"
	// FailurePermanent 表示确定不可恢复的请求错误（例如负载过大、参数非法）。
	FailurePermanent FailureKind = "permanent"
)

// Retryable 判断这类失败是否值得重试。
//
// 只有限流与供应商故障可以重试：其余情况重试只会放大问题 ——
// 令牌失效重试会一直打不存在的设备，未配置重试会一直空转。
func (k FailureKind) Retryable() bool {
	switch k {
	case FailureRateLimited, FailureProviderUnavailable:
		return true
	default:
		return false
	}
}

// DeviceInvalid 表示该设备的令牌已经失效，调用方应当停用这台设备。
func (k FailureKind) DeviceInvalid() bool { return k == FailureInvalidToken }

// Chinese 给出面向用户/运维的中文说明，让日志与界面不必匹配自由文本。
func (k FailureKind) Chinese() string {
	switch k {
	case FailureNotConfigured:
		return "推送通道未配置"
	case FailureUnsupportedPlatform:
		return "该平台没有可用的推送通道"
	case FailureMissingToken:
		return "设备没有推送令牌"
	case FailureInvalidToken:
		return "推送令牌已失效，需要重新登记设备"
	case FailureEmptyMessage:
		return "通知内容为空"
	case FailureExpired:
		return "提醒已过期，不再发送"
	case FailureRateLimited:
		return "推送服务限流"
	case FailureProviderUnavailable:
		return "推送服务暂时不可用"
	case FailureProviderAuth:
		return "推送服务拒绝了服务端凭据"
	case FailurePermanent:
		return "推送服务拒绝了这条请求"
	default:
		return string(k)
	}
}

// Failure 描述一次失败。
//
// Detail **不得包含推送令牌明文或通知正文**：令牌等同于凭据，正文属于用户隐私。
type Failure struct {
	Kind       FailureKind
	Provider   string
	StatusCode int
	Detail     string
}

func (f *Failure) Error() string {
	if f == nil {
		return "push: 未知失败"
	}
	parts := []string{f.Kind.Chinese()}
	if f.Provider != "" {
		parts = append(parts, "provider="+f.Provider)
	}
	if f.StatusCode > 0 {
		parts = append(parts, fmt.Sprintf("status=%d", f.StatusCode))
	}
	msg := "push: " + strings.Join(parts, " ")
	if f.Detail != "" {
		msg += ": " + f.Detail
	}
	return msg
}

// Retryable 见 FailureKind.Retryable。
func (f *Failure) Retryable() bool {
	if f == nil {
		return false
	}
	return f.Kind.Retryable()
}

// DeviceInvalid 见 FailureKind.DeviceInvalid。
func (f *Failure) DeviceInvalid() bool {
	if f == nil {
		return false
	}
	return f.Kind.DeviceInvalid()
}

// ErrNotConfigured 是"这条推送通道缺少凭据"的稳定判断入口。
//
// 调用方（组装层 / 监控）应当用 errors.Is 判断它，从而把"没配置"与"发失败"分开：
// 前者要报配置缺失，后者要报投递异常。
var ErrNotConfigured = errors.New("push: 推送通道未配置")

// NewNotConfigured 构造一个"未配置"失败，供各供应商实现与组装层复用，
// 避免各处手写错误文案导致判断入口失效。
func NewNotConfigured(provider, detail string) *Failure {
	return &Failure{Kind: FailureNotConfigured, Provider: provider, Detail: detail}
}

// Receipt 是一次投递的回执。
//
// 无论成功失败都返回回执：调用方需要按设备记账，失败也要知道是哪台设备。
type Receipt struct {
	Provider string
	// MessageID 是供应商侧的标识（APNs 的 apns-id / FCM 的 name），用于对账。
	MessageID string
	// DeviceID 回填目标设备，便于调用方记录"这台设备这次是什么结果"。
	DeviceID   string
	Status     Status
	AcceptedAt time.Time
	// DeliveredAt 只在供应商确实回报送达时才有值。
	DeliveredAt *time.Time
	// Failure 在 Status 为 StatusFailed 时非空。
	Failure *Failure
}

// Failed 判断这次投递是否失败。
func (r Receipt) Failed() bool { return r.Status == StatusFailed || r.Failure != nil }

// DeviceInvalid 表示这次失败意味着设备令牌失效，调用方应停用设备。
func (r Receipt) DeviceInvalid() bool { return r.Failure.DeviceInvalid() }

// Sender 是一条推送通道。
//
// 约定：失败时同时返回回执与 error，且两者的 Failure 是同一个指针，
// 保证"看 error"和"看回执"的调用方得到完全一致的结论。
type Sender interface {
	Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error)
}

// Named 是可选接口：实现它的 Sender 能让失败回执带上供应商标识。
type Named interface {
	// Provider 返回稳定的供应商标识（apns / fcm / ...）。
	Provider() string
}

// providerOf 读取供应商标识；没实现 Named 的返回空串，而不是编一个名字出来。
func providerOf(s Sender) string {
	if n, ok := s.(Named); ok {
		return n.Provider()
	}
	return ""
}

// failureReceipt 同时构造回执与错误，杜绝两者说法不一致。
func failureReceipt(target DeviceTarget, f *Failure, at time.Time) (Receipt, error) {
	return Receipt{
		Provider:   f.Provider,
		DeviceID:   target.DeviceID,
		Status:     StatusFailed,
		AcceptedAt: at,
		Failure:    f,
	}, f
}

// acceptedReceipt 构造成功回执。
func acceptedReceipt(target DeviceTarget, provider, messageID string, at time.Time) Receipt {
	return Receipt{
		Provider:   provider,
		MessageID:  messageID,
		DeviceID:   target.DeviceID,
		Status:     StatusAccepted,
		AcceptedAt: at,
	}
}

// FailureOf 从 error 中取出失败详情；不是推送失败时返回 false。
func FailureOf(err error) (*Failure, bool) {
	if err == nil {
		return nil, false
	}
	var f *Failure
	if errors.As(err, &f) && f != nil {
		return f, true
	}
	return nil, false
}

// Unconfigured 是一个永远返回"未配置"的 Sender。
//
// 存在的意义：组装层在缺少凭据时必须**显式**选择"这条通道不存在"，
// 而不是让某个实现"尽力而为"地假装发出去。
type Unconfigured struct{ Name string }

// Provider 实现 Named。
func (u Unconfigured) Provider() string { return u.Name }

// Send 恒失败，并让错误同时满足两个判断入口：
// errors.Is(err, ErrNotConfigured) 供组装层识别"配置缺失"，
// errors.As(err, **Failure) 供调用方按统一方式读取失败分类。
func (u Unconfigured) Send(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
	f := NewNotConfigured(u.Name, "缺少推送凭据，未发起任何请求")
	r, _ := failureReceipt(target, f, time.Now())
	return r, fmt.Errorf("%w: %w", ErrNotConfigured, f)
}
