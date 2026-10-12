// Package httpx 提供统一的 JSON 响应、错误码与 HTTP 中间件。
package httpx

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// 错误码与 contracts/v1/error.schema.json 的枚举一一对应。
const (
	CodeInvalidRequest     = "invalid_request"
	CodeUnauthorized       = "unauthorized"
	CodeNotFound           = "not_found"
	CodePayloadTooLarge    = "payload_too_large"
	CodeUnsupportedMedia   = "unsupported_media_type"
	CodeUnprocessable      = "unprocessable"
	CodeRateLimited        = "rate_limited"
	CodeUpstreamTimeout    = "upstream_timeout"
	CodeUpstreamError      = "upstream_error"
	CodeModelOutputInvalid = "model_output_invalid"
	CodeServiceUnavailable = "service_unavailable"
	CodeInternal           = "internal"
)

// StatusFor 把业务错误码映射为 HTTP 状态码。
func StatusFor(code string) int {
	switch code {
	case CodeInvalidRequest:
		return http.StatusBadRequest
	case CodeUnauthorized:
		return http.StatusUnauthorized
	case CodeNotFound:
		return http.StatusNotFound
	case CodePayloadTooLarge:
		return http.StatusRequestEntityTooLarge
	case CodeUnsupportedMedia:
		return http.StatusUnsupportedMediaType
	case CodeUnprocessable:
		return http.StatusUnprocessableEntity
	case CodeRateLimited:
		return http.StatusTooManyRequests
	case CodeUpstreamTimeout:
		return http.StatusGatewayTimeout
	case CodeUpstreamError:
		return http.StatusBadGateway
	case CodeModelOutputInvalid:
		return http.StatusBadGateway
	case CodeServiceUnavailable:
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}

// APIError 是错误体中的 error 对象。
type APIError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
	TraceID   string `json:"trace_id"`
}

// ErrorResponse 是唯一的非 2xx 响应形状。
type ErrorResponse struct {
	Error APIError `json:"error"`
}

// Retryable 判断某个错误码是否适合客户端自动重试。
func Retryable(code string) bool {
	switch code {
	case CodeUpstreamTimeout, CodeUpstreamError, CodeModelOutputInvalid, CodeRateLimited, CodeServiceUnavailable:
		return true
	default:
		return false
	}
}

// WriteError 输出标准错误体。message 必须是面向用户的可读提示，
// 不得包含用户原文、音频内容或密钥。
func WriteError(w http.ResponseWriter, r *http.Request, code, message string) {
	WriteJSON(w, StatusFor(code), ErrorResponse{Error: APIError{
		Code:      code,
		Message:   message,
		Retryable: Retryable(code),
		TraceID:   RequestID(r),
	}})
}

const internalErrorBody = "{\"error\":{\"code\":\"internal\",\"message\":\"服务内部错误\",\"retryable\":true,\"trace_id\":\"\"}}"

// WriteJSON 输出 JSON；序列化失败时退回 500，且不再二次写头。
func WriteJSON(w http.ResponseWriter, status int, v any) {
	buf, err := json.Marshal(v)
	if err != nil {
		slog.Error("响应序列化失败", "error", err)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(internalErrorBody))
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(buf)
}

// DecodeJSON 严格解析请求体：拒绝未知字段，让契约漂移在开发期就暴露，
// 而不是被静默忽略。
func DecodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	if dec.More() {
		return errTrailingContent
	}
	return nil
}

type trailingContentError struct{}

func (trailingContentError) Error() string { return "请求体包含多余内容" }

var errTrailingContent = trailingContentError{}
