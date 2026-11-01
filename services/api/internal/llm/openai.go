package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// maxUpstreamBytes 限制单次读取的上游响应体，避免异常上游打爆内存。
const maxUpstreamBytes = 1 << 20

// OpenAI 适配任意 OpenAI-compatible 的 /chat/completions 接口。
type OpenAI struct {
	baseURL string
	apiKey  string
	model   string

	// mergeSystemPrompt 见 NewOpenAI 的说明：专为不认 system 角色的端点准备。
	mergeSystemPrompt bool

	client *http.Client
}

// NewOpenAI 构造 OpenAI-compatible 客户端；响应格式固定要求 JSON object，便于结构化解析。
//
// mergeSystemPrompt 用于绕过「不认 system 角色」的中转端点：这类网关会把
// system 消息丢掉，模型只看到 user 原文，于是无视输出格式要求、自己发明字段、
// 自己算日期。打开后把指令直接拼在 user 消息前面——实测能让这类端点恢复可用。
func NewOpenAI(baseURL, apiKey, model string, timeout time.Duration, mergeSystemPrompt bool) *OpenAI {
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	return &OpenAI{
		baseURL:           strings.TrimRight(baseURL, "/"),
		apiKey:            apiKey,
		model:             model,
		mergeSystemPrompt: mergeSystemPrompt,
		client:            &http.Client{Timeout: timeout},
	}
}

func (o *OpenAI) Name() string  { return "openai-compatible" }
func (o *OpenAI) Model() string { return o.model }

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type responseFormat struct {
	Type string `json:"type"`
}

type chatRequest struct {
	Model          string          `json:"model"`
	Messages       []chatMessage   `json:"messages"`
	Temperature    float64         `json:"temperature"`
	ResponseFormat *responseFormat `json:"response_format,omitempty"`
}

type chatResponse struct {
	Choices []struct {
		Message      chatMessage `json:"message"`
		FinishReason string      `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

// Complete 调用上游；错误信息里绝不带上游响应体，避免把用户原文带进日志。
func (o *OpenAI) Complete(ctx context.Context, system, user string) (Result, error) {
	// 默认保留 system/user 的职责分离；只有对不认 system 角色的端点才合并。
	messages := []chatMessage{
		{Role: "system", Content: system},
		{Role: "user", Content: user},
	}
	if o.mergeSystemPrompt {
		// 合并时保留空行分隔，让指令块和待处理原文在视觉上仍分得开。
		messages = []chatMessage{{Role: "user", Content: system + "\n\n" + user}}
	}

	payload := chatRequest{
		Model:          o.model,
		Messages:       messages,
		Temperature:    0,
		ResponseFormat: &responseFormat{Type: "json_object"},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}
	req.Header.Set("Content-Type", "application/json")
	if o.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.apiKey)
	}

	resp, err := o.client.Do(req)
	if err != nil {
		return Result{}, classify(err, ctx)
	}
	defer func() { _ = resp.Body.Close() }()

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxUpstreamBytes))
	if err != nil {
		return Result{}, classify(err, ctx)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// 只保留状态码：上游错误体里可能回显用户原文。
		return Result{}, fmt.Errorf("%w: 状态码 %d", ErrUpstream, resp.StatusCode)
	}

	var out chatResponse
	if err := json.Unmarshal(data, &out); err != nil {
		return Result{}, fmt.Errorf("%w: 响应不是合法 JSON", ErrUpstream)
	}
	if len(out.Choices) == 0 {
		return Result{}, fmt.Errorf("%w: 响应缺少 choices", ErrUpstream)
	}
	return Result{
		Text:             out.Choices[0].Message.Content,
		Provider:         o.Name(),
		Model:            o.model,
		PromptTokens:     out.Usage.PromptTokens,
		CompletionTokens: out.Usage.CompletionTokens,
		FinishReason:     out.Choices[0].FinishReason,
	}, nil
}

// classify 把网络错误归为超时或一般上游错误。
func classify(err error, ctx context.Context) error {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return ErrTimeout
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return ErrTimeout
	}
	return fmt.Errorf("%w: %v", ErrUpstream, err)
}
