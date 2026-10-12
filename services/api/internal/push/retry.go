package push

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// RetryPolicy 描述重试次数与退避。
//
// 之所以把 Sleep 做成可注入字段：测试必须能在零耗时下验证"重试了 3 次"，
// 而真实运行时又要真的退避。用真实时间做测试会让整套用例慢到没人愿意跑。
type RetryPolicy struct {
	// MaxAttempts 是包含首次尝试在内的总次数；<=1 表示不重试。
	MaxAttempts int
	// BaseDelay 是第一次重试前的等待，之后逐次翻倍。
	BaseDelay time.Duration
	// MaxDelay 是单次等待的上限，防止退避无限增长。
	MaxDelay time.Duration
	Sleep    func(ctx context.Context, d time.Duration) error
}

// DefaultRetryPolicy 给出保守默认：最多 3 次，0.5s 起、4s 封顶。
// 主动提醒对时效敏感，重试太久不如留给下一轮调度。
func DefaultRetryPolicy() RetryPolicy {
	return RetryPolicy{MaxAttempts: 3, BaseDelay: 500 * time.Millisecond, MaxDelay: 4 * time.Second}
}

// WithRetry 包装 Sender，只对可重试失败做有限退避重试。
//
// 关键点：**不可重试的失败必须立刻返回**。对令牌失效、未配置、请求非法做重试，
// 除了浪费配额与日志之外什么也得不到。
func WithRetry(next Sender, p RetryPolicy) Sender {
	if p.MaxAttempts <= 0 {
		p.MaxAttempts = 1
	}
	if p.BaseDelay < 0 {
		p.BaseDelay = 0
	}
	if p.MaxDelay <= 0 {
		p.MaxDelay = p.BaseDelay
	}
	if p.Sleep == nil {
		p.Sleep = sleepCtx
	}
	return &retrySender{next: next, policy: p}
}

type retrySender struct {
	next   Sender
	policy RetryPolicy
}

// Provider 透传下游供应商标识。
func (r *retrySender) Provider() string { return providerOf(r.next) }

func (r *retrySender) Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error) {
	var (
		lastReceipt Receipt
		lastErr     error
	)
	// 第一次尝试前不等待，退避从第二次开始。
	for attempt := 1; attempt <= r.policy.MaxAttempts; attempt++ {
		receipt, err := r.next.Send(ctx, target, msg)
		if err == nil {
			return receipt, nil
		}
		lastReceipt, lastErr = receipt, err

		f, ok := FailureOf(err)
		if !ok || !f.Retryable() {
			return receipt, err
		}
		if attempt == r.policy.MaxAttempts {
			break
		}
		if serr := r.policy.Sleep(ctx, r.delay(attempt)); serr != nil {
			// 中断时把"最后一次推送失败"与"中断原因"都保留：
			// 只报中断会让排查者以为问题出在推送；只报推送失败又会丢掉取消这一事实。
			return lastReceipt, errors.Join(lastErr, fmt.Errorf("push: 重试等待被中断: %w", serr))
		}
	}
	return lastReceipt, lastErr
}

// delay 返回第 attempt 次尝试之后的等待时长，按指数退避并封顶。
func (r *retrySender) delay(attempt int) time.Duration {
	d := r.policy.BaseDelay
	for i := 1; i < attempt && d > 0; i++ {
		d *= 2
		if d > r.policy.MaxDelay {
			return r.policy.MaxDelay
		}
	}
	if d > r.policy.MaxDelay {
		return r.policy.MaxDelay
	}
	return d
}

// sleepCtx 在等待与取消之间二选一：可取消的退避才能让关机流程及时结束。
func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
