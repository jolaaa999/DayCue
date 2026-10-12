package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	_ "time/tzdata"

	"github.com/jolaaa999/DayCue/services/api/internal/config"
	"github.com/jolaaa999/DayCue/services/api/internal/extract"
	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/llm"
)

type stubProvider struct {
	text  string
	err   error
	delay time.Duration
}

func (s stubProvider) Name() string  { return "stub" }
func (s stubProvider) Model() string { return "stub-1" }
func (s stubProvider) Complete(ctx context.Context, system, user string) (llm.Result, error) {
	if s.delay > 0 {
		select {
		case <-time.After(s.delay):
		case <-ctx.Done():
			return llm.Result{}, llm.ErrTimeout
		}
	}
	if s.err != nil {
		return llm.Result{}, s.err
	}
	return llm.Result{Text: s.text, Provider: s.Name(), Model: s.Model()}, nil
}

func testConfig() config.Config {
	return config.Config{
		Env:            "test",
		Addr:           "127.0.0.1:8787",
		MaxJSONBytes:   4096,
		MaxAudioBytes:  8192,
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  time.Second,
	}
}

func validBody() string {
	return `{"schema_version":"1.0","capture_id":"cap_test","source":{"type":"text","text":"明晚八点提醒我复习操作系统"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Asia/Shanghai"}`
}

func doRequest(t *testing.T, h http.Handler, method, path, body, contentType string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHealth(t *testing.T) {
	cfg := testConfig()
	s := New(cfg)
	rec := doRequest(t, s.Handler(), http.MethodGet, "/v1/health", "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d", rec.Code)
	}
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("健康检查不是 JSON: %v", err)
	}
	if got["status"] != "ok" {
		t.Errorf("status = %v", got["status"])
	}
}

func TestExtractionsWithoutProviderReturns503(t *testing.T) {
	s := New(testConfig())
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", validBody(), "application/json")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("未配置供应商应返回 503，实得 %d: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), httpx.CodeServiceUnavailable) {
		t.Errorf("错误码不正确: %s", rec.Body.String())
	}
}

func TestExtractionsFixtureModeEndToEnd(t *testing.T) {
	cfg := testConfig()
	cfg.FixtureMode = true
	s := New(cfg)

	body := `{"schema_version":"1.0","capture_id":"cap_e2e","source":{"type":"asr","text":"今天操作系统讲了 PV 操作，我还是没理解，明晚八点提醒我复习，周五之前交实验报告。","language":"zh-Hans"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Asia/Shanghai"}`
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", body, "application/json")
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d: %s", rec.Code, rec.Body.String())
	}
	var resp extract.Response
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("响应解析失败: %v", err)
	}
	if resp.Mode != "fixture" {
		t.Errorf("模拟模式必须标记 mode=fixture，实得 %q", resp.Mode)
	}
	if len(resp.Items) != 3 {
		t.Fatalf("期望 3 条候选，实得 %d: %s", len(resp.Items), rec.Body.String())
	}
	if resp.Items[0].Kind != "note" {
		t.Errorf("第 1 条应为笔记，实得 %q", resp.Items[0].Kind)
	}
	if resp.Items[1].Due.UTC == nil || *resp.Items[1].Due.UTC != "2026-10-12T12:00:00Z" {
		t.Errorf("跨时区换算不正确: %+v", resp.Items[1].Due)
	}
	if resp.Items[1].Remind == nil {
		t.Errorf("明晚八点应带提醒时刻")
	}
	if resp.Items[2].Remind != nil {
		t.Errorf("周五之前不得自动补提醒时刻")
	}
}

func TestExtractionsRejectsUnknownField(t *testing.T) {
	cfg := testConfig()
	cfg.FixtureMode = true
	s := New(cfg)
	// 契约里没有 user_id：必须拒绝，防止越权字段被静默接受。
	body := `{"schema_version":"1.0","capture_id":"c","source":{"type":"text","text":"明天交作业"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Asia/Shanghai","user_id":"someone-else"}`
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", body, "application/json")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("未知字段应返回 400，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

func TestExtractionsRejectsBadTimezone(t *testing.T) {
	cfg := testConfig()
	cfg.FixtureMode = true
	s := New(cfg)
	body := `{"schema_version":"1.0","capture_id":"c","source":{"type":"text","text":"明天交作业"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Mars/Olympus"}`
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", body, "application/json")
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("非法时区应返回 422，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

func TestExtractionsPayloadTooLarge(t *testing.T) {
	cfg := testConfig()
	cfg.MaxJSONBytes = 64
	s := New(cfg)
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", validBody(), "application/json")
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超大请求应返回 413，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

func TestExtractionsModelOutputInvalidReturns502(t *testing.T) {
	cfg := testConfig()
	s := New(cfg)
	s.LLM = stubProvider{text: "这不是 JSON"}
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", validBody(), "application/json")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("模型输出非法应返回 502，实得 %d: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), httpx.CodeModelOutputInvalid) {
		t.Errorf("错误码应为 model_output_invalid: %s", rec.Body.String())
	}
	// 关键属性：失败响应体里不能带任何候选，客户端无从据此写入系统。
	if strings.Contains(rec.Body.String(), "items") {
		t.Errorf("失败响应不得包含候选: %s", rec.Body.String())
	}
}

func TestExtractionsTimeoutReturns504(t *testing.T) {
	cfg := testConfig()
	cfg.RequestTimeout = 60 * time.Millisecond
	s := New(cfg)
	s.LLM = stubProvider{delay: 2 * time.Second}
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", validBody(), "application/json")
	if rec.Code != http.StatusGatewayTimeout {
		t.Fatalf("超时应返回 504，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

func TestExtractionsUpstreamErrorReturns502(t *testing.T) {
	cfg := testConfig()
	s := New(cfg)
	s.LLM = stubProvider{err: llm.ErrUpstream}
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", validBody(), "application/json")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("上游错误应返回 502，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

func TestAuthRequiredWhenTokenConfigured(t *testing.T) {
	cfg := testConfig()
	cfg.AuthToken = "s3cret"
	cfg.FixtureMode = true
	s := New(cfg)

	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/extractions", validBody(), "application/json")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("缺少令牌应返回 401，实得 %d", rec.Code)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/extractions", strings.NewReader(validBody()))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer s3cret")
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, req)
	if rec2.Code != http.StatusOK {
		t.Fatalf("携带正确令牌应成功，实得 %d: %s", rec2.Code, rec2.Body.String())
	}
}

func TestTranscriptionsRequiresAudioContentType(t *testing.T) {
	s := New(testConfig())
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/transcriptions", "not-audio", "application/json")
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("非音频类型应返回 415，实得 %d", rec.Code)
	}
}

func TestTranscriptionsWithoutProviderReturns503(t *testing.T) {
	cfg := testConfig()
	cfg.FixtureMode = true
	s := New(cfg)
	// 模拟模式不提供转写：必须明确失败，绝不能返回编造文本。
	rec := doRequest(t, s.Handler(), http.MethodPost, "/v1/transcriptions", "fake-audio-bytes", "audio/mp4")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("应返回 503，实得 %d: %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), `"text"`) {
		t.Errorf("失败响应不得包含转写文本: %s", rec.Body.String())
	}
}

func TestNotFound(t *testing.T) {
	s := New(testConfig())
	rec := doRequest(t, s.Handler(), http.MethodGet, "/v1/nope", "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("未知路径应返回 404，实得 %d", rec.Code)
	}
}

func TestEmptyBodyReturns400(t *testing.T) {
	s := New(testConfig())
	req := httptest.NewRequest(http.MethodPost, "/v1/extractions", bytes.NewReader(nil))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("空 body 应返回 400，实得 %d", rec.Code)
	}
}
