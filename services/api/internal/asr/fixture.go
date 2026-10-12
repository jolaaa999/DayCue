package asr

import (
	"context"
	"fmt"
)

// Fixture 只在显式开启模拟模式时使用。它明确拒绝返回任何看似真实的文本，
// 因为伪造转写会直接污染用户的笔记——宁可报"未配置"也不编造。
type Fixture struct{}

func NewFixture() *Fixture { return &Fixture{} }

func (f *Fixture) Name() string { return "fixture" }

func (f *Fixture) Transcribe(ctx context.Context, audio []byte, contentType, language string) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{}, ErrTimeout
	}
	return Result{}, fmt.Errorf("%w：模拟模式不提供语音转写，请改用系统听写或配置真实 ASR 供应商。", ErrNotConfigured)
}
