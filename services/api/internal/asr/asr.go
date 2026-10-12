// Package asr 定义音频转写适配层。
//
// 客户端只在"系统识别不可用或未授权"时才走后端转写；因此这里的失败
// 必须如实上报，绝不允许返回编造的文本。
package asr

import (
	"context"
	"errors"
)

var (
	// ErrNotConfigured 表示未配置转写供应商。
	ErrNotConfigured = errors.New("未配置语音转写供应商")
	// ErrTimeout 表示上游超时。
	ErrTimeout = errors.New("语音转写超时")
	// ErrUpstream 表示上游返回错误或非法响应。
	ErrUpstream = errors.New("语音转写失败")
)

// Result 是一次转写结果。
type Result struct {
	Text     string
	Provider string
	Model    string
	Language string
}

// Transcriber 是音频转写供应商。
type Transcriber interface {
	Name() string
	Transcribe(ctx context.Context, audio []byte, contentType, language string) (Result, error)
}
