// Package api 组装 DayCue 后端的 HTTP 接口。
//
// 本服务保持无状态：不存用户数据、不做系统写操作，只负责"把文本变成结构化候选"
// 和"把音频变成文本"。用户数据在第一阶段全部留在 iOS 本地库。
package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/asr"
	"github.com/jolaaa999/DayCue/services/api/internal/config"
	"github.com/jolaaa999/DayCue/services/api/internal/extract"
	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/llm"
)

// Version 是服务版本号。
const Version = "0.1.0"

// Server 持有配置与供应商适配器。字段导出是为了让测试能注入假供应商，
// 从而在没有任何真实凭据的机器上也能验证全部错误路径。
type Server struct {
	cfg config.Config
	LLM llm.Provider
	ASR asr.Transcriber
	Now func() time.Time
}

// New 按配置装配供应商。模拟模式必须由 DAYCUE_FIXTURE_MODE 显式开启。
func New(cfg config.Config) *Server {
	s := &Server{cfg: cfg, Now: time.Now}
	if cfg.FixtureMode {
		s.LLM = llm.NewFixture()
		s.ASR = asr.NewFixture()
		return s
	}
	if cfg.LLM.Configured() {
		s.LLM = llm.NewOpenAI(cfg.LLM.BaseURL, cfg.LLM.APIKey, cfg.LLM.Model, cfg.LLM.Timeout)
	}
	if cfg.ASR.Configured() {
		s.ASR = asr.NewOpenAI(cfg.ASR.BaseURL, cfg.ASR.APIKey, cfg.ASR.Model, cfg.ASR.Timeout)
	}
	return s
}

// Handler 返回带全部中间件的根处理器。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.handleHealth)
	mux.Handle("POST /v1/extractions", httpx.Chain(
		http.HandlerFunc(s.handleExtractions), httpx.MaxBody(s.cfg.MaxJSONBytes)))
	mux.Handle("POST /v1/transcriptions", httpx.Chain(
		http.HandlerFunc(s.handleTranscriptions), httpx.MaxBody(s.cfg.MaxAudioBytes)))
	mux.HandleFunc("/", handleNotFound)

	return httpx.Chain(mux,
		httpx.Recover,
		httpx.WithRequestID,
		httpx.AccessLog,
		httpx.Auth(s.cfg.AuthToken),
		httpx.Timeout(s.cfg.RequestTimeout),
	)
}

type healthLimits struct {
	MaxJSONBytes  int64 `json:"max_json_bytes"`
	MaxAudioBytes int64 `json:"max_audio_bytes"`
}

type healthResponse struct {
	Status      string            `json:"status"`
	Version     string            `json:"version"`
	Time        string            `json:"time"`
	Env         string            `json:"env"`
	FixtureMode bool              `json:"fixture_mode"`
	Providers   map[string]string `json:"providers"`
	Limits      healthLimits      `json:"limits"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	if s.Now != nil {
		now = s.Now()
	}
	httpx.WriteJSON(w, http.StatusOK, healthResponse{
		Status:      "ok",
		Version:     Version,
		Time:        now.UTC().Format(time.RFC3339),
		Env:         s.cfg.Env,
		FixtureMode: s.cfg.FixtureMode,
		Providers: map[string]string{
			"llm": providerState(s.LLM),
			"asr": providerState(s.ASR),
		},
		Limits: healthLimits{MaxJSONBytes: s.cfg.MaxJSONBytes, MaxAudioBytes: s.cfg.MaxAudioBytes},
	})
}

// providerState 如实区分三种状态：真实供应商、显式开启的模拟供应商、未配置。
// 把模拟供应商报成 configured 会让调用方误以为拿到了真实 AI 结果。
func providerState(p any) string {
	if p == nil {
		return "absent"
	}
	type named interface{ Name() string }
	if n, ok := p.(named); ok && n.Name() == "fixture" {
		return "fixture"
	}
	return "configured"
}

func handleNotFound(w http.ResponseWriter, r *http.Request) {
	httpx.WriteError(w, r, httpx.CodeNotFound, "接口不存在。")
}

func (s *Server) handleExtractions(w http.ResponseWriter, r *http.Request) {
	if ct := r.Header.Get("Content-Type"); ct != "" && !strings.HasPrefix(ct, "application/json") {
		httpx.WriteError(w, r, httpx.CodeUnsupportedMedia, "该接口只接受 application/json。")
		return
	}

	var req extract.Request
	if err := httpx.DecodeJSON(r, &req); err != nil {
		if httpx.IsBodyTooLarge(err) {
			httpx.WriteError(w, r, httpx.CodePayloadTooLarge, "请求内容过大。")
			return
		}
		httpx.WriteError(w, r, httpx.CodeInvalidRequest, "请求体不是合法 JSON，或包含契约之外的字段。")
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, err.Error())
		return
	}
	if s.LLM == nil {
		httpx.WriteError(w, r, httpx.CodeServiceUnavailable, "服务端尚未配置 AI 供应商，请在设置中填写可用的服务地址。")
		return
	}

	resp, err := extract.Extract(r.Context(), req, s.LLM)
	if err != nil {
		s.writeExtractError(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}

// writeExtractError 把内部错误映射为契约错误码。此处绝不下发上游响应内容，
// 也绝不因为一次失败就触发任何系统写操作。
func (s *Server) writeExtractError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, llm.ErrTimeout), errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		slog.Warn("提取超时", "trace_id", httpx.RequestID(r))
		httpx.WriteError(w, r, httpx.CodeUpstreamTimeout, "AI 服务响应超时。原始记录已保留，可稍后重试。")
	case errors.Is(err, extract.ErrModelOutputInvalid):
		slog.Warn("模型输出不可用", "trace_id", httpx.RequestID(r))
		httpx.WriteError(w, r, httpx.CodeModelOutputInvalid, "AI 返回的内容无法解析为结构化候选。原始记录已保留，可稍后重试。")
	case errors.Is(err, llm.ErrNotConfigured):
		httpx.WriteError(w, r, httpx.CodeServiceUnavailable, "服务端尚未配置 AI 供应商。")
	default:
		slog.Warn("提取失败", "trace_id", httpx.RequestID(r), "reason", err.Error())
		httpx.WriteError(w, r, httpx.CodeUpstreamError, "AI 服务暂时不可用。原始记录已保留，可稍后重试。")
	}
}

type transcriptionResponse struct {
	SchemaVersion string   `json:"schema_version"`
	Text          string   `json:"text"`
	Mode          string   `json:"mode"`
	Language      string   `json:"language,omitempty"`
	Warnings      []string `json:"warnings"`
}

func (s *Server) handleTranscriptions(w http.ResponseWriter, r *http.Request) {
	contentType := r.Header.Get("Content-Type")
	if !strings.HasPrefix(contentType, "audio/") {
		httpx.WriteError(w, r, httpx.CodeUnsupportedMedia, "该接口只接受原始音频字节，Content-Type 必须是 audio/*。")
		return
	}
	audio, err := io.ReadAll(r.Body)
	if err != nil {
		if httpx.IsBodyTooLarge(err) {
			httpx.WriteError(w, r, httpx.CodePayloadTooLarge, "音频文件过大。")
			return
		}
		httpx.WriteError(w, r, httpx.CodeInvalidRequest, "读取音频内容失败。")
		return
	}
	if len(audio) == 0 {
		httpx.WriteError(w, r, httpx.CodeInvalidRequest, "音频内容为空。")
		return
	}
	if s.ASR == nil {
		httpx.WriteError(w, r, httpx.CodeServiceUnavailable, "服务端尚未配置语音转写供应商，请使用系统听写或稍后重试。")
		return
	}

	res, err := s.ASR.Transcribe(r.Context(), audio, contentType, r.Header.Get("X-DayCue-Language"))
	if err != nil {
		switch {
		case errors.Is(err, asr.ErrTimeout), errors.Is(err, context.DeadlineExceeded):
			httpx.WriteError(w, r, httpx.CodeUpstreamTimeout, "语音转写超时。音频已保存在本地，可稍后重试。")
		case errors.Is(err, asr.ErrNotConfigured):
			httpx.WriteError(w, r, httpx.CodeServiceUnavailable, err.Error())
		default:
			slog.Warn("转写失败", "trace_id", httpx.RequestID(r), "reason", err.Error())
			httpx.WriteError(w, r, httpx.CodeUpstreamError, "语音转写失败。音频已保存在本地，可稍后重试。")
		}
		return
	}

	mode := "live"
	if res.Provider == "fixture" {
		mode = "fixture"
	}
	httpx.WriteJSON(w, http.StatusOK, transcriptionResponse{
		SchemaVersion: extract.SchemaVersion,
		Text:          res.Text,
		Mode:          mode,
		Language:      res.Language,
		Warnings:      []string{},
	})
}
