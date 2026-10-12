// Package llm 定义 AI 文本模型的供应商适配层。
//
// 之所以抽象成接口：设计文档要求服务端统一保管 API Key 且能替换供应商，
// 同时让单元测试可以注入假供应商，从而在没有任何真实凭据的情况下验证错误路径。
package llm

import (
	"context"
	"errors"
)

var (
	// ErrNotConfigured 表示没有配置任何供应商，调用方应返回 503 而不是伪造结果。
	ErrNotConfigured = errors.New("未配置 AI 供应商")
	// ErrTimeout 表示上游超时，调用方应返回 504 并标记可重试。
	ErrTimeout = errors.New("AI 供应商响应超时")
	// ErrUpstream 表示上游返回了错误或非法响应，调用方应返回 502。
	ErrUpstream = errors.New("AI 供应商返回错误")
)

// Result 是一次补全调用的结果与用量。
type Result struct {
	Text             string
	Provider         string
	Model            string
	PromptTokens     int
	CompletionTokens int
}

// Provider 是文本补全供应商。
type Provider interface {
	Name() string
	Model() string
	Complete(ctx context.Context, system, user string) (Result, error)
}
