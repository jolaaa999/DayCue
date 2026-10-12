package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"
)

// APNs 官方端点。沙箱端点单独暴露：用生产端点发开发环境令牌只会得到 400，
// 而那个错误看起来很像"令牌失效"，极容易被误判成设备问题。
const (
	APNsEndpoint        = "https://api.push.apple.com"
	APNsSandboxEndpoint = "https://api.sandbox.push.apple.com"
)

// apnsProvider 是回执与失败里使用的稳定供应商标识。
const apnsProvider = "apns"

// maxProviderBody 是读取供应商响应体的上限：出错时对方可能返回很大的 HTML，
// 全量读进内存毫无意义。
const maxProviderBody = 8 << 10

// apnsTokenLifetime 是本地缓存 provider token 的时长。
// APNs 要求 token 有效期不超过 1 小时，并且**不要**每个请求都重新签发；
// 留 10 分钟余量既避开边界过期，也避免频繁签名被判成滥用。
const apnsTokenLifetime = 50 * time.Minute

// APNsConfig 是 APNs 通道的凭据与端点配置。
type APNsConfig struct {
	// KeyID 是 Apple 开发者后台里 .p8 密钥的 Key ID。
	KeyID string
	// TeamID 是开发者账号 Team ID。
	TeamID string
	// BundleID 同时作为 apns-topic。
	BundleID string
	// PrivateKeyPEM 是 .p8 文件内容（PKCS#8 EC 私钥）。
	PrivateKeyPEM []byte
	// Endpoint 为空时使用生产端点；测试/沙箱环境必须显式传沙箱端点。
	Endpoint   string
	HTTPClient Doer
	Now        func() time.Time
}

// APNs 是 APNs 通道实现。
type APNs struct {
	endpoint string
	bundleID string
	client   Doer
	now      func() time.Time
	tokens   *apnsTokenCache
}

// NewAPNs 构造 APNs 通道。
//
// 缺任何一项凭据都直接返回包装了 ErrNotConfigured 的错误，而不是构造一个
// "运行时会失败"的对象：让配置错误在启动时暴露，而不是等到用户该收到提醒的那一刻。
func NewAPNs(cfg APNsConfig) (*APNs, error) {
	var missing []string
	if cfg.KeyID == "" {
		missing = append(missing, "KeyID")
	}
	if cfg.TeamID == "" {
		missing = append(missing, "TeamID")
	}
	if cfg.BundleID == "" {
		missing = append(missing, "BundleID")
	}
	if len(cfg.PrivateKeyPEM) == 0 {
		missing = append(missing, "PrivateKeyPEM")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("%w: APNs 缺少 %v", ErrNotConfigured, missing)
	}
	key, err := parseAPNsKey(cfg.PrivateKeyPEM)
	if err != nil {
		// 密钥格式错误同样是"这条通道不可用"，归到未配置，避免启动后才发现。
		return nil, fmt.Errorf("%w: %v", ErrNotConfigured, err)
	}
	endpoint := cfg.Endpoint
	if endpoint == "" {
		endpoint = APNsEndpoint
	}
	now := orDefaultNow(cfg.Now)
	return &APNs{
		endpoint: endpoint,
		bundleID: cfg.BundleID,
		client:   orDefaultClient(cfg.HTTPClient),
		now:      now,
		tokens: &apnsTokenCache{
			key: key, keyID: cfg.KeyID, teamID: cfg.TeamID, now: now,
		},
	}, nil
}

// Provider 实现 Named。
func (a *APNs) Provider() string { return apnsProvider }

// Send 投递一条通知。
//
// 注意：APNs 的发送接口只回报"已受理"，**不回报设备是否收到**。
// 因此成功时状态固定是 accepted，绝不写成 delivered —— 送达只有设备侧能确认。
func (a *APNs) Send(ctx context.Context, target DeviceTarget, msg Message) (Receipt, error) {
	at := a.now()
	bearer, err := a.tokens.bearer()
	if err != nil {
		return failureReceipt(target, &Failure{
			Kind: FailureProviderAuth, Provider: apnsProvider,
			Detail: "签发 provider token 失败",
		}, at)
	}
	body, err := a.buildPayload(msg)
	if err != nil {
		return failureReceipt(target, &Failure{
			Kind: FailurePermanent, Provider: apnsProvider, Detail: err.Error(),
		}, at)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		a.endpoint+"/3/device/"+url.PathEscape(target.Token), bytes.NewReader(body))
	if err != nil {
		return failureReceipt(target, &Failure{
			Kind: FailurePermanent, Provider: apnsProvider, Detail: "构造请求失败",
		}, at)
	}
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-topic", a.bundleID)
	req.Header.Set("apns-push-type", "alert")
	// 主动提醒对时效敏感：用最高优先级，让系统尽量立刻展示。
	req.Header.Set("apns-priority", "10")
	req.Header.Set("content-type", "application/json")
	if msg.DedupeKey != "" {
		// apns-collapse-id 上限 64 字节；同一条消息重试时它保证只留一条通知。
		req.Header.Set("apns-collapse-id", truncateRunes(msg.DedupeKey, 64))
	}
	if msg.ExpiresAt != nil {
		req.Header.Set("apns-expiration", strconv.FormatInt(msg.ExpiresAt.Unix(), 10))
	} else {
		// 0 表示"不存储、只尝试立即投递"，与主动提醒的语义一致。
		req.Header.Set("apns-expiration", "0")
	}

	resp, err := a.client.Do(req)
	if err != nil {
		// 调用方已经取消时不要再报"可重试"：重试只会在同一个已死的上下文上立刻失败。
		if ctx.Err() != nil {
			return failureReceipt(target, &Failure{
				Kind: FailurePermanent, Provider: apnsProvider,
				Detail: "请求被取消或超时",
			}, at)
		}
		return failureReceipt(target, &Failure{
			Kind: FailureProviderUnavailable, Provider: apnsProvider,
			Detail: "请求未送达",
		}, at)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxProviderBody))

	if resp.StatusCode == http.StatusOK {
		return acceptedReceipt(target, apnsProvider, resp.Header.Get("apns-id"), at), nil
	}
	return failureReceipt(target, classifyAPNs(resp.StatusCode, apnsReason(raw)), at)
}

// buildPayload 生成 APNs 负载。
//
// 保留键冲突时**报错而不是静默丢弃**：静默丢弃会让调用方以为附加字段已经送达，
// 客户端却永远等不到它。
func (a *APNs) buildPayload(msg Message) ([]byte, error) {
	reserved := map[string]bool{"aps": true, "message_id": true, "kind": true, "deep_link": true}
	payload := map[string]any{
		"aps": map[string]any{
			"alert": map[string]string{"title": msg.Title, "body": msg.Body},
			"sound": "default",
		},
	}
	if msg.ID != "" {
		payload["message_id"] = msg.ID
	}
	if msg.Kind != "" {
		payload["kind"] = msg.Kind
	}
	if msg.DeepLink != "" {
		payload["deep_link"] = msg.DeepLink
	}
	for k, v := range msg.Data {
		if reserved[k] {
			return nil, errors.New("push: APNs 负载字段名与保留键冲突: " + k)
		}
		payload[k] = v
	}
	return json.Marshal(payload)
}

// apnsReason 从响应体里取出 reason 字段；解析不出来时返回空串，
// 让分类退回到"只看状态码"，而不是编一个原因出来。
func apnsReason(raw []byte) string {
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		return ""
	}
	reason, _ := body["reason"].(string)
	return reason
}

// classifyAPNs 把 APNs 的状态码与 reason 映射成失败分类。
//
// 这张映射表是"令牌失效能否被正确上报"的唯一依据：
// 把 Unregistered 归到 permanent，失效设备就会永远留在推送名单里被反复重试。
func classifyAPNs(status int, reason string) *Failure {
	f := &Failure{Provider: apnsProvider, StatusCode: status, Detail: reason}
	switch status {
	case http.StatusGone: // 410
		// 410 只有一种含义：令牌不再有效，必须停用设备。
		f.Kind = FailureInvalidToken
		return f
	case http.StatusTooManyRequests: // 429
		f.Kind = FailureRateLimited
		return f
	}
	if status >= 500 {
		f.Kind = FailureProviderUnavailable
		return f
	}
	switch reason {
	case "BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered":
		f.Kind = FailureInvalidToken
	case "ExpiredProviderToken", "InvalidProviderToken", "MissingProviderToken",
		"BadTopic", "TopicDisallowed", "MissingTopic":
		f.Kind = FailureProviderAuth
	case "TooManyProviderTokenUpdates":
		// 这是"签发 token 太频繁"，属于限流而不是密钥错误，等一会儿重试有意义。
		f.Kind = FailureRateLimited
	default:
		if status == http.StatusForbidden {
			f.Kind = FailureProviderAuth
			return f
		}
		f.Kind = FailurePermanent
	}
	return f
}

// ---------- provider token ----------

// apnsTokenCache 缓存 ES256 JWT。
//
// 为什么必须缓存：APNs 会因为"provider token 刷新过于频繁"直接拒绝后续请求
// （TooManyProviderTokenUpdates），每个请求都重签等于把自己限流掉。
type apnsTokenCache struct {
	mu        sync.Mutex
	cached    string
	expiresAt time.Time
	key       *ecdsa.PrivateKey
	keyID     string
	teamID    string
	now       func() time.Time
}

func (t *apnsTokenCache) bearer() (string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	if t.cached != "" && now.Before(t.expiresAt) {
		return t.cached, nil
	}
	token, err := signES256JWT(t.key, t.keyID, map[string]any{
		"iss": t.teamID,
		"iat": now.Unix(),
	})
	if err != nil {
		return "", err
	}
	t.cached = token
	t.expiresAt = now.Add(apnsTokenLifetime)
	return token, nil
}

// signES256JWT 用 P-256 私钥签一个最小 JWT。
//
// 自己签而不是引入第三方 JWT 库：只需要 ES256 一种算法、两个声明，
// 少一个依赖就少一处供应链风险，而且这段代码可以被"用公钥验签"的测试完整覆盖。
func signES256JWT(key *ecdsa.PrivateKey, keyID string, claims map[string]any) (string, error) {
	header, err := json.Marshal(map[string]any{"alg": "ES256", "kid": keyID, "typ": "JWT"})
	if err != nil {
		return "", err
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signingInput := b64url(header) + "." + b64url(payload)
	digest := sha256.Sum256([]byte(signingInput))

	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS 要求固定长度的 r||s，而 ecdsa.Sign 给出的是两个大整数：
	// 直接拼接会在其中一个值高位为零时变短，APNs 会直接判定签名非法。
	size := (key.Curve.Params().BitSize + 7) / 8
	sig := make([]byte, 2*size)
	r.FillBytes(sig[:size])
	s.FillBytes(sig[size:])
	return signingInput + "." + b64url(sig), nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// parseAPNsKey 解析 .p8 文件内容。
func parseAPNsKey(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("APNs 私钥不是 PEM 格式")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("解析 APNs 私钥失败: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs 私钥不是 EC 私钥（.p8 必须是 ES256 密钥）")
	}
	return key, nil
}
