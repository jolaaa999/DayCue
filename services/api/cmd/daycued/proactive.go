package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/config"
	"github.com/jolaaa999/DayCue/services/api/internal/proactive"
	"github.com/jolaaa999/DayCue/services/api/internal/push"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// 编译期确认存储层确实满足推送包的设备失效回调；接口一旦变动这里会先编译失败。
var _ push.DeviceInvalidator = (*store.Postgres)(nil)

// 编译期确认组装层适配器满足 runner 的窄端口。
var _ proactive.ProactiveLedger = ledgerAdapter{}

// newProactiveRunner 组装主动推送链路。
//
// 返回值约定：runner 为 nil 表示"明确不启动"（当前只有一种：没有数据库），
// 此时 note 说明原因；err 只用于真正的初始化失败。
//
// 链路顺序与 internal/proactive、internal/push 的约定一致：
//
//	Router（按平台分发 + 上报设备失效）
//	  -> Guard（发前检查令牌/过期/空内容）
//	    -> WithRetry（限流与供应商抖动）
//	      -> Scheduler（预算/冷却/静默判定）
//	        -> Runner（账本 + 设备 + 落库）
func newProactiveRunner(cfg config.Config, pg *store.Postgres) (*proactive.Runner, time.Duration, string, error) {
	if pg == nil {
		return nil, 0, "无数据库，主动推送调度未启动", nil
	}
	now := time.Now
	router := push.NewRouter(now)

	// 凭据缺失不是错误，但绝不能静默跳过：注册 Unconfigured 让每次投递得到明确的
	// not_configured 失败，并在启动日志里点名缺了哪个环境变量。
	apns, err := buildAPNs(cfg.Push, now)
	if err != nil {
		slog.Warn("APNs 推送未配置，iOS 推送不会真正发出",
			"cause", err.Error(),
			"missing_env", strings.Join(cfg.Push.MissingAPNsEnv(), ", "))
		router.Register(push.PlatformIOS, push.Unconfigured{Name: "apns"})
	} else {
		router.Register(push.PlatformIOS, apns)
	}

	fcm, err := buildFCM(cfg.Push, now)
	if err != nil {
		slog.Warn("FCM 推送未配置，Android 推送不会真正发出",
			"cause", err.Error(),
			"missing_env", strings.Join(cfg.Push.MissingFCMEnv(), ", "))
		router.Register(push.PlatformAndroid, push.Unconfigured{Name: "fcm"})
	} else {
		router.Register(push.PlatformAndroid, fcm)
	}

	// 令牌失效由路由器自动上报，避免调度层漏掉。
	router.WithInvalidator(pg)

	sender := push.WithRetry(push.Guard(router, now), push.DefaultRetryPolicy())
	scheduler, err := proactive.NewScheduler(proactive.DefaultPolicy(), sender, now)
	if err != nil {
		return nil, 0, "", fmt.Errorf("构造主动推送调度器失败: %w", err)
	}
	// 用户时区从库里读（app_user.timezone，IANA 名）。读不到或为空时在存储层回退 UTC：
	// 预算、静默时段、每日重置都按用户本地自然日算，账本里的绝对时刻仍一律存 UTC。
	//
	// 这里同步读取（LocationOf 签名不带 ctx）是刻意的：调度器与 runner 的时区判定
	// 必须在一轮内保持一致，异步预取会让同一轮里出现两个"今天"。
	locationOf := func(userID string) *time.Location {
		loc, err := pg.UserLocation(context.Background(), userID)
		if err != nil {
			slog.Warn("读取用户时区失败，本轮按 UTC 计算", "user_id", userID, "cause", err.Error())
			return time.UTC
		}
		return loc
	}
	scheduler.LocationOf = locationOf

	runner := &proactive.Runner{
		Ledger:         ledgerAdapter{pg: pg},
		Devices:        deviceAdapter{pg: pg, deliverable: platformDeliverable(router)},
		Scheduler:      scheduler,
		LocationOf:     locationOf,
		LocationSource: pg.UserLocation,
		Now:            now,
		ClaimLimit:     cfg.Push.ClaimLimit,
		ClaimedBy:      claimedBy(),
		Lease:          cfg.Push.Lease,
		MaxAttempts:    cfg.Push.MaxAttempts,
		RecoverLimit:   cfg.Push.RecoverLimit,
		DailyBudgetFor: func(string) int { return scheduler.Policy.DailyBudget },
	}

	interval := cfg.Push.Interval
	if interval <= 0 {
		interval = time.Minute
	}
	return runner, interval, "主动推送调度已启动", nil
}

// platformDeliverable 判断某平台是否真的配好了通道。
//
// 把"平台未配置"的设备从路由候选里剔除：否则一条本该发给另一台设备的消息，
// 会因为挑中未配置平台而得到 not_configured 失败，被 runner 当成永久失败落 cancelled。
// 剔除后 runner 会释放占用、保持 pending，等凭据配好再发。
func platformDeliverable(router *push.Router) func(push.Platform) bool {
	return func(p push.Platform) bool {
		sender, ok := router.SenderFor(p)
		if !ok {
			return false
		}
		_, unconfigured := sender.(push.Unconfigured)
		return !unconfigured
	}
}

// buildAPNs 从环境变量构造 APNs 通道；缺凭据或文件读不到都归为"未配置"。
func buildAPNs(p config.PushConfig, now func() time.Time) (push.Sender, error) {
	if missing := p.MissingAPNsEnv(); len(missing) > 0 {
		return nil, fmt.Errorf("缺少环境变量 %s", strings.Join(missing, ", "))
	}
	keyPEM := []byte(p.APNsKeyPEM)
	if strings.TrimSpace(p.APNsKeyFile) != "" {
		raw, err := os.ReadFile(p.APNsKeyFile)
		if err != nil {
			return nil, fmt.Errorf("读取 APNs 私钥失败（DAYCUE_APNS_KEY_FILE）: %w", err)
		}
		keyPEM = raw
	}
	apns, err := push.NewAPNs(push.APNsConfig{
		KeyID:         p.APNsKeyID,
		TeamID:        p.APNsTeamID,
		BundleID:      p.APNsBundleID,
		PrivateKeyPEM: keyPEM,
		Endpoint:      p.APNsEndpoint,
		Now:           now,
	})
	if err != nil {
		return nil, err
	}
	return apns, nil
}

// buildFCM 从环境变量 + 服务账号 JSON 构造 FCM 通道。
func buildFCM(p config.PushConfig, now func() time.Time) (push.Sender, error) {
	if missing := p.MissingFCMEnv(); len(missing) > 0 {
		return nil, fmt.Errorf("缺少环境变量 %s", strings.Join(missing, ", "))
	}
	raw := []byte(p.FCMServiceAccountJSON)
	if strings.TrimSpace(p.FCMServiceAccountFile) != "" {
		b, err := os.ReadFile(p.FCMServiceAccountFile)
		if err != nil {
			return nil, fmt.Errorf("读取 FCM 服务账号失败（DAYCUE_FCM_SERVICE_ACCOUNT_FILE）: %w", err)
		}
		raw = b
	}
	var sa serviceAccount
	if err := json.Unmarshal(raw, &sa); err != nil {
		return nil, fmt.Errorf("解析 FCM 服务账号 JSON 失败: %w", err)
	}
	project := strings.TrimSpace(p.FCMProjectID)
	if project == "" {
		project = strings.TrimSpace(sa.ProjectID)
	}
	tokens, err := newServiceAccountTokenSource(sa, now)
	if err != nil {
		return nil, err
	}
	fcm, err := push.NewFCM(push.FCMConfig{
		ProjectID:   project,
		TokenSource: tokens,
		Endpoint:    p.FCMEndpoint,
		Now:         now,
	})
	if err != nil {
		return nil, err
	}
	return fcm, nil
}

// ---------- 端口适配器 ----------
//
// proactive 不 import store、store 也不 import proactive，两边各自持有扁平类型；
// 翻译只发生在这个组装层，任何一侧换实现都不用改另一侧。

type ledgerAdapter struct{ pg *store.Postgres }

func (a ledgerAdapter) ClaimDueProactive(ctx context.Context, req proactive.ClaimRequest) (proactive.ClaimBatch, error) {
	batch, err := a.pg.ClaimDueProactive(ctx, store.ProactiveClaimRequest{
		Now:           req.Now,
		Limit:         req.Limit,
		ClaimedBy:     req.ClaimedBy,
		Lease:         req.Lease,
		MaxAttempts:   req.MaxAttempts,
		DailyLimitFor: req.DailyLimitFor,
		LocationFor:   req.LocationFor,
	})
	if err != nil {
		return proactive.ClaimBatch{}, err
	}
	out := proactive.ClaimBatch{
		Claims:          make([]proactive.Claim, 0, len(batch.Claims)),
		OverBudgetUsers: batch.OverBudgetUsers,
	}
	for _, c := range batch.Claims {
		out.Claims = append(out.Claims, proactive.Claim{
			ID:             c.ID,
			UserID:         c.UserID,
			Kind:           c.Kind,
			DedupeKey:      c.DedupeKey,
			ScheduledAt:    c.ScheduledAt,
			ExpiresAt:      c.ExpiresAt,
			Title:          c.Title,
			Body:           c.Body,
			DeepLink:       c.DeepLink,
			Data:           c.Data,
			ClaimToken:     c.ClaimToken,
			LeaseExpiresAt: c.LeaseExpiresAt,
			AttemptCount:   c.AttemptCount,
			DeliveryID:     c.DeliveryID,
		})
	}
	return out, nil
}

func (a ledgerAdapter) SettleProactive(ctx context.Context, req proactive.SettleRequest) error {
	return a.pg.SettleProactive(ctx, store.ProactiveSettleRequest{
		ID:             req.ID,
		Token:          req.Token,
		State:          req.State,
		SuppressReason: req.SuppressReason,
		DeliveredAt:    req.DeliveredAt,
		DeliveryStatus: req.DeliveryStatus,
		At:             req.At,
		RetryAfter:     req.RetryAfter,
	})
}

func (a ledgerAdapter) RecoverExpiredProactive(ctx context.Context, now time.Time, limit int, lease time.Duration, maxAttempts int) (proactive.RecoverResult, error) {
	res, err := a.pg.RecoverExpiredProactive(ctx, now, limit, lease, maxAttempts)
	if err != nil {
		return proactive.RecoverResult{}, err
	}
	return proactive.RecoverResult{Requeued: res.Requeued, Expired: res.Expired, Extended: res.Extended}, nil
}

func (a ledgerAdapter) BeginProactiveDelivery(ctx context.Context, id string, token string, at time.Time) error {
	return a.pg.BeginProactiveDelivery(ctx, id, token, at)
}

func (a ledgerAdapter) UserLocation(ctx context.Context, userID string) (*time.Location, error) {
	return a.pg.UserLocation(ctx, userID)
}

func (a ledgerAdapter) ProactiveHistory(ctx context.Context, userID string, dedupeKey string, kind string, now time.Time, loc *time.Location) (proactive.HistoryFacts, error) {
	facts, err := a.pg.ProactiveHistory(ctx, userID, dedupeKey, kind, now, loc)
	if err != nil {
		return proactive.HistoryFacts{}, err
	}
	return proactive.HistoryFacts{
		DeliveredToday:        facts.DeliveredToday,
		ClaimedToday:          facts.ClaimedToday,
		ReservedToday:         facts.ReservedToday,
		UnknownToday:          facts.UnknownToday,
		LastDeliveredSameKey:  facts.LastDeliveredSameKey,
		LastDeliveredSameKind: facts.LastDeliveredSameKind,
		SameKeyDeliveredToday: facts.SameKeyDeliveredToday,
	}, nil
}

func (a ledgerAdapter) MarkDeviceInvalid(ctx context.Context, userID string, deviceID string, at time.Time) error {
	return a.pg.MarkDeviceInvalid(ctx, userID, deviceID, at)
}

func (a ledgerAdapter) CancelPendingForDevice(ctx context.Context, userID string, deviceID string, at time.Time) (int, error) {
	return a.pg.CancelPendingForDevice(ctx, userID, deviceID, at)
}

func (a ledgerAdapter) AssignProactiveDevice(ctx context.Context, id string, deviceID string, at time.Time) error {
	return a.pg.AssignProactiveDevice(ctx, id, deviceID, at)
}

// deviceAdapter 把设备记录翻译成推送目标，并剔除平台未配置的设备。
type deviceAdapter struct {
	pg          *store.Postgres
	deliverable func(push.Platform) bool
}

func (a deviceAdapter) DevicesForUser(ctx context.Context, userID string) ([]push.DeviceTarget, error) {
	devices, err := a.pg.DevicesByUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]push.DeviceTarget, 0, len(devices))
	for _, d := range devices {
		platform := push.ParsePlatform(d.Platform)
		if a.deliverable != nil && !a.deliverable(platform) {
			continue
		}
		out = append(out, push.DeviceTarget{
			UserID:   d.UserID,
			DeviceID: d.ID,
			Platform: platform,
			Token:    strings.TrimSpace(d.PushToken),
		})
	}
	return out, nil
}

// ---------- FCM 服务账号令牌 ----------

// fcmScope 是 FCM HTTP v1 需要的 OAuth2 scope。
const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

// serviceAccount 是 Google 服务账号密钥里组装层需要的字段。
// 只解析必要字段：多解析一份凭据结构就多一处将来会漂移的假设。
type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// serviceAccountTokenSource 用服务账号私钥换 FCM 的 OAuth2 访问令牌。
//
// 为什么自己实现而不是引入第三方库：push 包把"凭据获取方式"留给部署环境，
// 这里只需要 RS256 签 JWT + 换 token 两步，标准库足够，少一个依赖就少一份供应链面。
// 代价：这段实现没有对真实 Google 凭据做过端到端验证（见交付说明）。
type serviceAccountTokenSource struct {
	email    string
	key      *rsa.PrivateKey
	tokenURI string
	client   *http.Client
	now      func() time.Time

	mu     sync.Mutex
	token  string
	expiry time.Time
}

func newServiceAccountTokenSource(sa serviceAccount, now func() time.Time) (*serviceAccountTokenSource, error) {
	if strings.TrimSpace(sa.ClientEmail) == "" {
		return nil, errors.New("服务账号缺少 client_email")
	}
	if strings.TrimSpace(sa.TokenURI) == "" {
		return nil, errors.New("服务账号缺少 token_uri")
	}
	if now == nil {
		now = time.Now
	}
	key, err := parseServiceAccountKey(sa.PrivateKey)
	if err != nil {
		return nil, err
	}
	return &serviceAccountTokenSource{
		email:    sa.ClientEmail,
		key:      key,
		tokenURI: sa.TokenURI,
		client:   http.DefaultClient,
		now:      now,
	}, nil
}

// parseServiceAccountKey 同时接受 PKCS#8 与 PKCS#1 两种 PEM，避免运维导出格式不同就起不来。
func parseServiceAccountKey(pemText string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemText))
	if block == nil {
		return nil, errors.New("服务账号私钥不是 PEM 格式")
	}
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		rsaKey, ok := parsed.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("服务账号私钥不是 RSA 私钥")
		}
		return rsaKey, nil
	}
	rsaKey, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("解析服务账号私钥失败: %w", err)
	}
	return rsaKey, nil
}

// Token 返回可用的访问令牌，并在本地缓存到接近过期。
func (s *serviceAccountTokenSource) Token(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.now()
	// 提前一分钟视为过期：正好卡在边界上被供应商拒绝会浪费一次投递。
	if s.token != "" && now.Before(s.expiry.Add(-time.Minute)) {
		return s.token, nil
	}

	iat := now.Unix()
	claims, err := json.Marshal(map[string]any{
		"iss":   s.email,
		"scope": fcmScope,
		"aud":   s.tokenURI,
		"iat":   iat,
		"exp":   iat + 3600,
	})
	if err != nil {
		return "", fmt.Errorf("构造 FCM JWT 声明失败: %w", err)
	}
	signing := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	signature, err := rsa.SignPKCS1v15(rand.Reader, s.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("签发 FCM JWT 失败: %w", err)
	}
	assertion := signing + "." + base64.RawURLEncoding.EncodeToString(signature)

	form := url.Values{}
	form.Set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
	form.Set("assertion", assertion)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.tokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("构造 FCM 令牌请求失败: %w", err)
	}
	req.Header.Set("content-type", "application/x-www-form-urlencoded")
	resp, err := s.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("请求 FCM 令牌失败: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("读取 FCM 令牌响应失败: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("FCM 令牌端点返回 %d: %s", resp.StatusCode, truncateForLog(string(body), 200))
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("解析 FCM 令牌响应失败: %w", err)
	}
	if out.AccessToken == "" {
		return "", errors.New("FCM 令牌响应缺少 access_token")
	}
	s.token = out.AccessToken
	ttl := time.Duration(out.ExpiresIn) * time.Second
	if ttl <= 0 {
		ttl = time.Hour
	}
	s.expiry = now.Add(ttl)
	return s.token, nil
}

// truncateForLog 限制错误响应体长度，避免把供应商返回的大段 HTML 写进日志。
func truncateForLog(s string, max int) string {
	s = strings.TrimSpace(s)
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max]) + "..."
}

// claimedBy 生成本调度进程的稳定标识：主机名 + pid。
//
// 为什么不用随机值：租约上的 claimed_by 是给排障用的——"这条被谁领走了"必须能定位到
// 具体一台机器上的具体进程。随机值只能回答"是某个进程"，等于没有信息。
// 取不到主机名时退回 "daycued"：标识为空会让租约记录失去可读性。
func claimedBy() string {
	host, err := os.Hostname()
	if err != nil || strings.TrimSpace(host) == "" {
		return "daycued"
	}
	return fmt.Sprintf("daycued@%s:%d", host, os.Getpid())
}
