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
	client  *http.Client
}

// NewOpenAI 构造适配器；响应格式固定要求 JSON object，便于结构化解析。
func NewOpenAI(baseURL, apiKey, model string, timeout time.Duration) *OpenAI {
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	return &OpenAI{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		model:   model,
		client:  &http.Client{Timeout: timeout},
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
		Message chatMessage `json:"message"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

// Complete 调用上游；错误信息里绝不带上游响应体，避免把用户原文带进日志。
func (o *OpenAI) Complete(ctx context.Context, system, user string) (Result, error) {
	payload := chatRequest{
		Model: o.model,
		Messages: []chatMessage{
			{Role: "system", Content: system},
			{Role: "user", Content: user},
		},
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
