package push

import (
	"context"
	"time"
)

// Guard 在真正调用供应商之前做本地预检。
//
// 预检放在装饰器里而不是各供应商实现里，是为了让所有通道判定完全一致：
// 只要有**一条**通道漏判"已过期"，用户就会在提醒过期之后才收到它，
// 而这种错误在真实设备上几乎不可能靠人工发现。
//
// 职责边界：Guard 只看"这条消息本身能不能发"（令牌、内容、过期），
// 不看平台路由 —— 那是 Router 的职责，拆开才不会出现两处各判一半。
func Guard(next Sender, now func() time.Time) Sender {
	if now == nil {
		now = time.Now
	}
	return &guardSender{next: next, now: now}
}

type guardSender struct {
	next Sender
	now  func() time.Time
}

// Provider 透传下游供应商标识，让失败回执仍能定位到具体通道。
func (g *guardSender) Provider() string { return providerOf(g.next) }

func (g *guardSender) Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error) {
	at := g.now()
	provider := providerOf(g.next)

	// 没有下游通道时按"未配置"处理，而不是 panic：
	// 组装层配错通道不应该让整个服务崩掉，但必须如实报出未配置。
	if g.next == nil {
		return failureReceipt(target, NewNotConfigured(provider, "没有可用的推送通道实现"), at)
	}
	if target.Platform == PlatformUnknown {
		return failureReceipt(target, &Failure{
			Kind: FailureUnsupportedPlatform, Provider: provider,
			Detail: "设备平台未知，无法选择推送通道",
		}, at)
	}
	if target.Token == "" {
		// 没有令牌时**不要**发请求：那只会拿到一个供应商的 400，
		// 把"这台设备没登记令牌"这个明确事实淹没在无关的错误里。
		return failureReceipt(target, &Failure{
			Kind: FailureMissingToken, Provider: provider,
			Detail: "设备未上报推送令牌",
		}, at)
	}
	if msg.ExpiresAt != nil && !at.Before(*msg.ExpiresAt) {
		return failureReceipt(target, &Failure{
			Kind: FailureExpired, Provider: provider,
			Detail: "消息已过期，过期提醒比不提醒更糟",
		}, at)
	}
	if msg.Title == "" && msg.Body == "" {
		// 标题正文都空的通知在设备上表现为"看不见的打扰"。
		return failureReceipt(target, &Failure{
			Kind: FailureEmptyMessage, Provider: provider,
			Detail: "标题与正文均为空",
		}, at)
	}

	receipt, err := g.next.Send(ctx, target, msg)
	if receipt.Provider == "" {
		receipt.Provider = provider
	}
	if receipt.DeviceID == "" {
		receipt.DeviceID = target.DeviceID
	}
	return receipt, err
}
