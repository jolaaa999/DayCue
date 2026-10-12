// Package config 负责从环境变量装载服务配置，并在启动前做安全校验。
//
// 设计取舍：所有凭据只能来自环境变量，绝不落盘、绝不写进日志；
// 校验失败一律拒绝启动，而不是"降级运行"，避免把无认证的 AI 代理暴露到公网。
package config

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config 是服务运行所需的全部配置。
type Config struct {
	Env            string
	Addr           string
	AuthToken      string
	FixtureMode    bool
	MaxJSONBytes   int64
	MaxAudioBytes  int64
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration

	// ---- 云同步（可选）----
	// 三项全空表示云同步未启用：服务端只提供 AI 端点，客户端完全走本地。
	// 这样"不登录也能用"不是靠客户端判断，而是服务端确实没有这套能力。
	DatabaseURL string
	// TokenSecret 是用户访问令牌的签名密钥，与 AuthToken 语义不同，不要复用。
	TokenSecret string
	MediaRoot   string

	LLM ProviderConfig
	ASR ProviderConfig

	// ---- 主动推送（可选）----
	// 凭据缺失不是错误：对应平台会注册 push.Unconfigured 并在启动日志里明确报「未配置」，
	// 让运维一眼看出推送为什么没有真正发出。
	Push PushConfig
}

// PushConfig 是主动推送的凭据与调度参数。
//
// 所有凭据只来自环境变量（与 LLM/ASR 一致），绝不落盘、绝不写进日志。
// 环境变量名固定如下，运维据此判断「到底缺哪一项」：
//
//	DAYCUE_APNS_KEY_ID / DAYCUE_APNS_TEAM_ID / DAYCUE_APNS_BUNDLE_ID
//	DAYCUE_APNS_KEY_FILE（.p8 路径）或 DAYCUE_APNS_KEY_PEM（.p8 内容，二选一）
//	DAYCUE_APNS_ENDPOINT（可选；沙箱用 https://api.sandbox.push.apple.com，生产留空）
//	DAYCUE_FCM_PROJECT_ID
//	DAYCUE_FCM_SERVICE_ACCOUNT_FILE 或 DAYCUE_FCM_SERVICE_ACCOUNT_JSON（二选一）
//	DAYCUE_FCM_ENDPOINT（可选）
//	DAYCUE_PROACTIVE_INTERVAL（默认 1m）、DAYCUE_PROACTIVE_CLAIM_LIMIT（默认 50）
type PushConfig struct {
	APNsKeyID    string
	APNsTeamID   string
	APNsBundleID string
	// APNsKeyPEM 与 APNsKeyFile 二选一；同时存在时以文件为准（组装层负责读取）。
	APNsKeyPEM   string
	APNsKeyFile  string
	APNsEndpoint string

	FCMProjectID string
	// FCMServiceAccountJSON 与 FCMServiceAccountFile 二选一；同时存在时以文件为准。
	FCMServiceAccountJSON string
	FCMServiceAccountFile string
	FCMEndpoint           string

	// Interval 是主动推送调度循环的间隔。
	Interval time.Duration
	// ClaimLimit 是单轮最多认领条数。
	ClaimLimit int
	// Lease 是领取租约时长；<=0 时用 proactive.DefaultLease。
	//
	// 为什么可配：租约为 0 会让"刚领取即可被抢走"，等于没有互斥；
	// 而取得过长会让崩溃进程留下的行迟迟无法回收。
	Lease time.Duration
	// MaxAttempts 是单条消息允许被领取的最大次数；<=0 时用 proactive.DefaultMaxAttempts。
	// 必须有上限，否则一条永远失败的行会被无限重试，每轮再占一次当日额度。
	MaxAttempts int
	// RecoverLimit 是单轮最多回收的过期租约条数；<=0 时用 ClaimLimit。
	RecoverLimit int

	// ProduceLookback 是候选生产者回看多久之内到期的业务事件。
	//
	// 它存在的意义与客户端追问策略里的补发宽限同源：设备离线一整天后重开时，
	// 补一堆昨天的提醒比不提醒更糟。超过窗口的事件不再生成候选。
	ProduceLookback time.Duration
	// ProduceLimit 是生产者单轮最多处理多少条事件，防止首次接入时一次性灌满账本。
	ProduceLimit int
}

// MissingAPNsEnv 返回 APNs 缺失的必填环境变量名；为空表示凭据齐全。
//
// 返回变量名而不是布尔值：运维需要知道的是「去配哪一个」，不是「没配好」。
func (p PushConfig) MissingAPNsEnv() []string {
	var missing []string
	if strings.TrimSpace(p.APNsKeyID) == "" {
		missing = append(missing, "DAYCUE_APNS_KEY_ID")
	}
	if strings.TrimSpace(p.APNsTeamID) == "" {
		missing = append(missing, "DAYCUE_APNS_TEAM_ID")
	}
	if strings.TrimSpace(p.APNsBundleID) == "" {
		missing = append(missing, "DAYCUE_APNS_BUNDLE_ID")
	}
	if strings.TrimSpace(p.APNsKeyFile) == "" && strings.TrimSpace(p.APNsKeyPEM) == "" {
		missing = append(missing, "DAYCUE_APNS_KEY_FILE 或 DAYCUE_APNS_KEY_PEM")
	}
	return missing
}

// MissingFCMEnv 返回 FCM 缺失的必填环境变量名；为空表示凭据齐全。
func (p PushConfig) MissingFCMEnv() []string {
	var missing []string
	if strings.TrimSpace(p.FCMProjectID) == "" {
		missing = append(missing, "DAYCUE_FCM_PROJECT_ID")
	}
	if strings.TrimSpace(p.FCMServiceAccountFile) == "" && strings.TrimSpace(p.FCMServiceAccountJSON) == "" {
		missing = append(missing, "DAYCUE_FCM_SERVICE_ACCOUNT_FILE 或 DAYCUE_FCM_SERVICE_ACCOUNT_JSON")
	}
	return missing
}

// ProviderConfig 描述一个上游 AI 供应商；BaseURL 为空表示未配置。
type ProviderConfig struct {
	BaseURL string
	APIKey  string
	Model   string
	Timeout time.Duration
}

// Configured 表示该供应商是否具备调用条件。
func (p ProviderConfig) Configured() bool {
	return strings.TrimSpace(p.BaseURL) != "" && strings.TrimSpace(p.Model) != ""
}

// Load 读取环境变量并返回配置；缺失项使用开发默认值。
func Load() Config {
	c := Config{
		Env:            env("DAYCUE_ENV", "development"),
		Addr:           env("DAYCUE_ADDR", "127.0.0.1:8787"),
		AuthToken:      os.Getenv("DAYCUE_AUTH_TOKEN"),
		FixtureMode:    envBool("DAYCUE_FIXTURE_MODE", false),
		MaxJSONBytes:   envInt64("DAYCUE_MAX_JSON_BYTES", 256*1024),
		MaxAudioBytes:  envInt64("DAYCUE_MAX_AUDIO_BYTES", 12*1024*1024),
		RequestTimeout: envDuration("DAYCUE_REQUEST_TIMEOUT", 30*time.Second),
		ShutdownGrace:  envDuration("DAYCUE_SHUTDOWN_GRACE", 5*time.Second),
		DatabaseURL:    os.Getenv("DAYCUE_DATABASE_URL"),
		TokenSecret:    os.Getenv("DAYCUE_TOKEN_SECRET"),
		MediaRoot:      env("DAYCUE_MEDIA_ROOT", "data/media"),
	}
	c.LLM = ProviderConfig{
		BaseURL: os.Getenv("DAYCUE_LLM_BASE_URL"),
		APIKey:  os.Getenv("DAYCUE_LLM_API_KEY"),
		Model:   env("DAYCUE_LLM_MODEL", "gpt-4o-mini"),
		Timeout: envDuration("DAYCUE_LLM_TIMEOUT", 20*time.Second),
	}
	c.ASR = ProviderConfig{
		BaseURL: os.Getenv("DAYCUE_ASR_BASE_URL"),
		APIKey:  os.Getenv("DAYCUE_ASR_API_KEY"),
		Model:   env("DAYCUE_ASR_MODEL", "whisper-1"),
		Timeout: envDuration("DAYCUE_ASR_TIMEOUT", 60*time.Second),
	}
	c.Push = PushConfig{
		APNsKeyID:             os.Getenv("DAYCUE_APNS_KEY_ID"),
		APNsTeamID:            os.Getenv("DAYCUE_APNS_TEAM_ID"),
		APNsBundleID:          os.Getenv("DAYCUE_APNS_BUNDLE_ID"),
		APNsKeyPEM:            os.Getenv("DAYCUE_APNS_KEY_PEM"),
		APNsKeyFile:           os.Getenv("DAYCUE_APNS_KEY_FILE"),
		APNsEndpoint:          os.Getenv("DAYCUE_APNS_ENDPOINT"),
		FCMProjectID:          os.Getenv("DAYCUE_FCM_PROJECT_ID"),
		FCMServiceAccountJSON: os.Getenv("DAYCUE_FCM_SERVICE_ACCOUNT_JSON"),
		FCMServiceAccountFile: os.Getenv("DAYCUE_FCM_SERVICE_ACCOUNT_FILE"),
		FCMEndpoint:           os.Getenv("DAYCUE_FCM_ENDPOINT"),
		Interval:              envDuration("DAYCUE_PROACTIVE_INTERVAL", time.Minute),
		ClaimLimit:            int(envInt64("DAYCUE_PROACTIVE_CLAIM_LIMIT", 50)),
		Lease:                 envDuration("DAYCUE_PROACTIVE_LEASE", 15*time.Minute),
		MaxAttempts:           int(envInt64("DAYCUE_PROACTIVE_MAX_ATTEMPTS", 4)),
		RecoverLimit:          int(envInt64("DAYCUE_PROACTIVE_RECOVER_LIMIT", 100)),
		ProduceLookback:       envDuration("DAYCUE_PROACTIVE_LOOKBACK", 2*time.Hour),
		ProduceLimit:          int(envInt64("DAYCUE_PROACTIVE_PRODUCE_LIMIT", 200)),
	}
	return c
}

// Validate 在监听前拦截危险组合。
func (c Config) Validate() error {
	var problems []string

	// 非本地监听必须带认证，否则等于把用户的 AI 代理公开出去。
	if !IsLoopbackAddr(c.Addr) && strings.TrimSpace(c.AuthToken) == "" {
		problems = append(problems, fmt.Sprintf("监听 %s 不是环回地址，必须设置 DAYCUE_AUTH_TOKEN", c.Addr))
	}
	// 模拟结果不能出现在生产环境，否则会冒充真实 AI 调用。
	if c.Env == "production" && c.FixtureMode {
		problems = append(problems, "DAYCUE_ENV=production 时不允许开启 DAYCUE_FIXTURE_MODE")
	}
	if c.MaxJSONBytes <= 0 || c.MaxAudioBytes <= 0 {
		problems = append(problems, "请求体大小上限必须为正数")
	}
	// 启用云同步却用弱密钥，等于把所有人账号的令牌都变成可伪造的。
	// 宁可拒绝启动，也不要带着弱密钥上线。
	if strings.TrimSpace(c.DatabaseURL) != "" && len(c.TokenSecret) < 32 {
		problems = append(problems,
			"启用云同步（DAYCUE_DATABASE_URL）时，DAYCUE_TOKEN_SECRET 必须至少 32 字节")
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// IsLoopbackAddr 判断监听地址是否只在本地可达。
func IsLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	host = strings.TrimSpace(host)
	if host == "" || host == "0.0.0.0" || host == "::" || host == "[::]" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

func envInt64(key string, def int64) int64 {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n <= 0 {
		return def
	}
	return n
}

func envDuration(key string, def time.Duration) time.Duration {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return def
	}
	return d
}
