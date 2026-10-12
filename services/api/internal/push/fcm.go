package push

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// FCMEndpoint 是 Firebase Cloud Messaging 的 HTTP v1 端点。
const FCMEndpoint = "https://fcm.googleapis.com"

// fcmProvider 是回执与失败里使用的稳定供应商标识。
const fcmProvider = "fcm"

// TokenSource 提供访问 FCM 所需的 OAuth2 访问令牌。
//
// 做成接口而不是直接读环境变量：服务账号密钥的获取方式（本地文件 / 工作负载身份）
// 属于部署环境的事，推送实现不该绑定其中一种。缺少实现即视为"未配置"。
type TokenSource interface {
	Token(ctx context.Context) (string, error)
}

// FCMConfig 是 FCM 通道的配置。
type FCMConfig struct {
	// ProjectID 是 Firebase 项目 ID，出现在 v1 端点路径里。
	ProjectID string
	// TokenSource 通常由服务账号密钥换取；为空表示未配置。
	TokenSource TokenSource
	// Endpoint 为空时使用官方端点。
	Endpoint   string
	HTTPClient Doer
	Now        func() time.Time
}

// FCM 是 FCM（Android）通道实现。
type FCM struct {
	project  string
	endpoint string
	tokens   TokenSource
	client   Doer
	now      func() time.Time
}

// NewFCM 构造 FCM 通道；缺 ProjectID 或 TokenSource 直接报未配置。
func NewFCM(cfg FCMConfig) (*FCM, error) {
	var missing []string
	if strings.TrimSpace(cfg.ProjectID) == "" {
		missing = append(missing, "ProjectID")
	}
	if cfg.TokenSource == nil {
		missing = append(missing, "TokenSource")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("%w: FCM 缺少 %v", ErrNotConfigured, missing)
	}
	endpoint := cfg.Endpoint
	if endpoint == "" {
		endpoint = FCMEndpoint
	}
	return &FCM{
		project:  cfg.ProjectID,
		endpoint: endpoint,
		tokens:   cfg.TokenSource,
		client:   orDefaultClient(cfg.HTTPClient),
		now:      orDefaultNow(cfg.Now),
	}, nil
}

// Provider 实现 Named。
func (f *FCM) Provider() string { return fcmProvider }

// Send 投递一条通知。
//
// 与 APNs 同理：v1 接口返回 200 只代表"已受理"，成功状态固定是 accepted。
func (f *FCM) Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error) {
	at := f.now()
	token, err := f.tokens.Token(ctx)
	if err != nil || strings.TrimSpace(token) == "" {
		// 拿不到访问令牌是服务端凭据问题，不是用户设备的问题，
		// 更不能归到 invalid_token —— 那会误停用所有 Android 设备。
		return failureReceipt(target, &Failure{
			Kind: FailureProviderAuth, Provider: fcmProvider,
			Detail: "获取 FCM 访问令牌失败",
		}, at)
	}

	body, err := f.buildPayload(target, msg, at)
	if err != nil {
		return failureReceipt(target, &Failure{
			Kind: FailurePermanent, Provider: fcmProvider, Detail: err.Error(),
		}, at)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		f.endpoint+"/v1/projects/"+f.project+"/messages:send", bytes.NewReader(body))
	if err != nil {
		return failureReceipt(target, &Failure{
			Kind: FailurePermanent, Provider: fcmProvider, Detail: "构造请求失败",
		}, at)
	}
	req.Header.Set("authorization", "Bearer "+token)
	req.Header.Set("content-type", "application/json")

	resp, err := f.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return failureReceipt(target, &Failure{
				Kind: FailurePermanent, Provider: fcmProvider,
				Detail: "请求被取消或超时",
			}, at)
		}
		return failureReceipt(target, &Failure{
			Kind: FailureProviderUnavailable, Provider: fcmProvider,
			Detail: "请求未送达",
		}, at)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxProviderBody))

	if resp.StatusCode == http.StatusOK {
		return acceptedReceipt(target, fcmProvider, fcmMessageName(raw), at), nil
	}
	return failureReceipt(target, classifyFCM(resp.StatusCode, fcmErrorOf(raw)), at)
}

// fcmError 是 FCM 错误体的可读投影。
type fcmError struct {
	Status    string
	Message   string
	ErrorCode string
}

// buildPayload 生成 FCM v1 消息体。
func (f *FCM) buildPayload(target DeviceTarget, msg Message, at time.Time) ([]byte, error) {
	// FCM 的 data 只接受字符串值：塞入数字或对象会被整条拒绝。
	data := map[string]string{}
	for k, v := range msg.Data {
		data[k] = v
	}
	if msg.ID != "" {
		data["message_id"] = msg.ID
	}
	if msg.Kind != "" {
		data["kind"] = msg.Kind
	}
	if msg.DeepLink != "" {
		data["deep_link"] = msg.DeepLink
	}

	message := map[string]any{
		"token":        target.Token,
		"notification": map[string]string{"title": msg.Title, "body": msg.Body},
	}
	if len(data) > 0 {
		message["data"] = data
	}

	android := map[string]any{}
	if msg.DedupeKey != "" {
		// collapse_key 让同一条消息的重试在设备上合并成一条。
		android["collapse_key"] = truncateRunes(msg.DedupeKey, 64)
	}
	if msg.ExpiresAt != nil {
		remaining := msg.ExpiresAt.Sub(at)
		if remaining <= 0 {
			// 已经过期：Guard 通常会先拦下，这里再挡一次，避免真的发出去。
			return nil, errors.New("push: 消息已过期，拒绝构造 FCM 负载")
		}
		android["ttl"] = strconv.Itoa(int(remaining.Seconds())) + "s"
	}
	if len(android) > 0 {
		message["android"] = android
	}

	return json.Marshal(map[string]any{"message": message})
}

// fcmMessageName 取出 FCM 返回的 name（形如 projects/x/messages/y），用于对账。
func fcmMessageName(raw []byte) string {
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		return ""
	}
	name, _ := body["name"].(string)
	return name
}

// fcmError 解析 Google 标准错误体，取 status / message / details[].errorCode。
//
// details 里的 errorCode 才是可靠信号：只看 HTTP 状态码会把
// "404 项目不存在"和"404 令牌未注册"混为一谈，后者才该停用设备。
func fcmErrorOf(raw []byte) fcmError {
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		return fcmError{}
	}
	errObj, _ := body["error"].(map[string]any)
	out := fcmError{}
	if errObj == nil {
		return out
	}
	out.Status, _ = errObj["status"].(string)
	out.Message, _ = errObj["message"].(string)
	if details, ok := errObj["details"].([]any); ok {
		for _, d := range details {
			m, ok := d.(map[string]any)
			if !ok {
				continue
			}
			if code, ok := m["errorCode"].(string); ok {
				out.ErrorCode = code
			}
		}
	}
	return out
}

// classifyFCM 把 FCM 的响应映射成失败分类。
func classifyFCM(status int, e fcmError) *Failure {
	f := &Failure{Provider: fcmProvider, StatusCode: status, Detail: fcmDetail(e)}
	switch {
	case status == http.StatusNotFound:
		// v1 用 404 UNREGISTERED 表示令牌已失效。
		f.Kind = FailureInvalidToken
		return f
	case status == http.StatusTooManyRequests:
		f.Kind = FailureRateLimited
		return f
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		f.Kind = FailureProviderAuth
		return f
	case status >= 500:
		f.Kind = FailureProviderUnavailable
		return f
	}
	switch e.ErrorCode {
	case "UNREGISTERED", "INVALID_REGISTRATION_TOKEN":
		f.Kind = FailureInvalidToken
	case "QUOTA_EXCEEDED", "DEVICE_MESSAGE_RATE_EXCEEDED", "TOPICS_MESSAGE_RATE_EXCEEDED":
		f.Kind = FailureRateLimited
	case "SENDER_ID_MISMATCH", "THIRD_PARTY_AUTH_ERROR", "AUTHENTICATION_ERROR":
		f.Kind = FailureProviderAuth
	case "INTERNAL", "UNAVAILABLE":
		f.Kind = FailureProviderUnavailable
	default:
		if e.Status == "UNAVAILABLE" || e.Status == "INTERNAL" {
			f.Kind = FailureProviderUnavailable
			return f
		}
		f.Kind = FailurePermanent
	}
	return f
}

// fcmDetail 只保留可归因的字段，不整段回显供应商响应：
// 响应里可能带着令牌片段，而失败详情会被写进日志。
func fcmDetail(e fcmError) string {
	parts := make([]string, 0, 3)
	if e.Status != "" {
		parts = append(parts, e.Status)
	}
	if e.ErrorCode != "" {
		parts = append(parts, e.ErrorCode)
	}
	if e.Message != "" {
		parts = append(parts, truncateRunes(e.Message, 200))
	}
	return strings.Join(parts, " / ")
}
