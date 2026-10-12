package push

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// SenderFunc 让普通函数满足 Sender。
//
// 组装层与测试都经常只需要一条临时通道；没有它就得为每种情形定义一个具名类型。
type SenderFunc func(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error)

// Send 实现 Sender。
func (f SenderFunc) Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error) {
	return f(ctx, target, msg)
}

// DeviceInvalidator 接收"这台设备的推送令牌已失效"的通知。
//
// 单独抽一个接口，是因为"停用设备"属于存储层的事：
// 推送包不该知道设备表长什么样，也不该直接依赖 store。
type DeviceInvalidator interface {
	MarkDeviceInvalid(ctx context.Context, userID, deviceID string, at time.Time) error
}

// Router 按平台把消息分发给对应通道，并把令牌失效上报为设备失效。
//
// 之所以需要这一层：一个账号可能同时有 iOS 与 Android 设备，
// 而 APNs 与 FCM 的失败语义完全不同。把"选通道"和"处理失效"集中在这里，
// 调度层就只需要面对一个 Sender。
type Router struct {
	senders     map[Platform]Sender
	invalidator DeviceInvalidator
	now         func() time.Time
}

// NewRouter 构造路由器；now 为空时使用系统时钟。
func NewRouter(now func() time.Time) *Router {
	return &Router{
		senders: map[Platform]Sender{},
		now:     orDefaultNow(now),
	}
}

// Register 登记某平台的通道。
//
// 传 nil 视为"该平台没有可用通道"，直接忽略：
// 让调用方后续拿到 unsupported_platform，而不是一个会在运行期 panic 的对象。
func (r *Router) Register(p Platform, s Sender) *Router {
	if s == nil {
		return r
	}
	r.senders[p] = s
	return r
}

// WithInvalidator 设置设备失效回调。
//
// 不设置也不会丢失失效信息：失败回执里仍然带着 invalid_token，
// 只是需要调用方自己处理。设置了则由路由器自动上报，避免调用方漏掉。
func (r *Router) WithInvalidator(i DeviceInvalidator) *Router {
	r.invalidator = i
	return r
}

// SenderFor 返回某平台已登记的通道。
func (r *Router) SenderFor(p Platform) (Sender, bool) {
	s, ok := r.senders[p]
	return s, ok
}

// Provider 实现 Named：路由器自身的失败（例如没有通道）用这个标识。
func (r *Router) Provider() string { return "router" }

// Send 选择通道并投递。
func (r *Router) Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error) {
	at := r.now()
	sender, ok := r.senders[target.Platform]
	if !ok {
		return failureReceipt(target, &Failure{
			Kind: FailureUnsupportedPlatform, Provider: r.Provider(),
			Detail: "没有登记该平台的推送通道: " + string(target.Platform),
		}, at)
	}

	receipt, err := sender.Send(ctx, target, msg)
	// 供应商没回填的信息由路由器补齐，保证回执始终能定位到设备。
	if receipt.DeviceID == "" {
		receipt.DeviceID = target.DeviceID
	}
	if receipt.Provider == "" {
		receipt.Provider = providerOf(sender)
	}

	if !receipt.DeviceInvalid() || r.invalidator == nil {
		return receipt, err
	}

	// 令牌失效时必须上报，否则调度会一直对着一台不存在的设备重试。
	// 上报失败不能吞掉原始推送失败：两者都要保留，排查时才知道到底哪一步坏了。
	if ierr := r.invalidator.MarkDeviceInvalid(ctx, target.UserID, target.DeviceID, at); ierr != nil {
		return receipt, errors.Join(err, fmt.Errorf("push: 上报设备失效失败: %w", ierr))
	}
	return receipt, err
}
