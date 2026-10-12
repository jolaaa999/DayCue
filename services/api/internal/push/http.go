package push

import (
	"net/http"
	"time"
)

// Doer 抽象 HTTP 客户端。
//
// 之所以不直接用 *http.Client：没有真实 APNs / FCM 凭据的机器上，
// 唯一能验证"状态码怎么映射成失败分类"的办法就是注入一个假 Doer。
// 不引入这层抽象就只能对着真供应商发请求，那在 CI 里永远跑不起来。
type Doer interface {
	Do(req *http.Request) (*http.Response, error)
}

// defaultHTTPClient 是所有通道共用的默认客户端。
//
// 超时是必须的：推送供应商偶发挂起时，没有超时的请求会一直占着调度协程，
// 后面的提醒全部错过时间窗。
var defaultHTTPClient = &http.Client{Timeout: 15 * time.Second}

// orDefaultClient 返回注入的客户端；没注入时用默认客户端而不是 nil。
func orDefaultClient(c Doer) Doer {
	if c == nil {
		return defaultHTTPClient
	}
	return c
}

// orDefaultNow 返回注入的时钟；没注入时用系统时钟。
func orDefaultNow(now func() time.Time) func() time.Time {
	if now == nil {
		return time.Now
	}
	return now
}

// truncateRunes 按字符（而不是字节）截断，避免把 UTF-8 字符切成半个。
func truncateRunes(s string, max int) string {
	if max <= 0 {
		return s
	}
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max])
}
