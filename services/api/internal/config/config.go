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

	LLM ProviderConfig
	ASR ProviderConfig
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
