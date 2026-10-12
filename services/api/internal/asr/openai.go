package asr

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"strings"
	"time"
)

const maxUpstreamBytes = 1 << 20

// OpenAI 适配 OpenAI-compatible 的 /audio/transcriptions 接口。
type OpenAI struct {
	baseURL string
	apiKey  string
	model   string
	client  *http.Client
}

func NewOpenAI(baseURL, apiKey, model string, timeout time.Duration) *OpenAI {
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	return &OpenAI{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		model:   model,
		client:  &http.Client{Timeout: timeout},
	}
}

func (o *OpenAI) Name() string { return "openai-compatible" }

// Transcribe 以 multipart 形式上传音频。上游错误体不回传、不落日志。
func (o *OpenAI) Transcribe(ctx context.Context, audio []byte, contentType, language string) (Result, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("file", "audio"+extFor(contentType))
	if err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}
	if _, err := part.Write(audio); err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}
	if err := mw.WriteField("model", o.model); err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}
	if language != "" {
		if err := mw.WriteField("language", language); err != nil {
			return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
		}
	}
	if err := mw.Close(); err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/audio/transcriptions", &buf)
	if err != nil {
		return Result{}, fmt.Errorf("%w: 请求构造失败", ErrUpstream)
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
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
		return Result{}, fmt.Errorf("%w: 状态码 %d", ErrUpstream, resp.StatusCode)
	}
	var out struct {
		Text     string `json:"text"`
		Language string `json:"language"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return Result{}, fmt.Errorf("%w: 响应不是合法 JSON", ErrUpstream)
	}
	if strings.TrimSpace(out.Text) == "" {
		return Result{}, fmt.Errorf("%w: 响应没有文本", ErrUpstream)
	}
	return Result{Text: out.Text, Provider: o.Name(), Model: o.model, Language: out.Language}, nil
}

func extFor(contentType string) string {
	switch {
	case strings.Contains(contentType, "wav"):
		return ".wav"
	case strings.Contains(contentType, "mpeg"), strings.Contains(contentType, "mp3"):
		return ".mp3"
	case strings.Contains(contentType, "webm"):
		return ".webm"
	default:
		return ".m4a"
	}
}

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
