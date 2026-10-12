// Package extract 把一段自然语言整理成结构化候选。
//
// 关键安全属性：模型只负责"拆分事项 + 指出时间表达"，绝对时刻一律由
// internal/temporal 用真实日历算出，模型自报的日期一律不采信。
package extract

import (
	"errors"
	"strings"
	"time"
)

// SchemaVersion 是当前契约版本，与 contracts/v1 一致。
const SchemaVersion = "1.0"

// MaxItems 限制单条记录最多拆出多少个候选，防止模型失控输出。
const MaxItems = 20

// ErrModelOutputInvalid 表示模型输出无法通过结构校验。
var ErrModelOutputInvalid = errors.New("模型输出不符合结构约定")

// Request 是 POST /v1/extractions 的请求体。
type Request struct {
	SchemaVersion string         `json:"schema_version"`
	CaptureID     string         `json:"capture_id"`
	Source        Source         `json:"source"`
	RecordedAt    string         `json:"recorded_at"`
	Timezone      string         `json:"timezone"`
	ClientContext *ClientContext `json:"client_context,omitempty"`
}

// Source 是被整理的原始内容。
type Source struct {
	Type     string `json:"type"`
	Text     string `json:"text"`
	Language string `json:"language,omitempty"`
}

// ClientContext 是端侧提供的少量上下文；第一阶段只用到课表标志。
type ClientContext struct {
	HasCourseSchedule bool     `json:"has_course_schedule"`
	KnownPlaces       []string `json:"known_places,omitempty"`
}

// Response 是 POST /v1/extractions 的响应体。
type Response struct {
	SchemaVersion string   `json:"schema_version"`
	CaptureID     string   `json:"capture_id"`
	Mode          string   `json:"mode"`
	Items         []Item   `json:"items"`
	Warnings      []string `json:"warnings"`
	Usage         *Usage   `json:"usage,omitempty"`
}

// Usage 记录一次调用的用量，便于成本核算；不含用户原文。
type Usage struct {
	Provider         string `json:"provider"`
	Model            string `json:"model"`
	LatencyMS        int64  `json:"latency_ms"`
	PromptTokens     int    `json:"prompt_tokens"`
	CompletionTokens int    `json:"completion_tokens"`
}

// Item 是一条结构化候选。
type Item struct {
	ItemID         string      `json:"item_id"`
	Kind           string      `json:"kind"`
	Title          string      `json:"title"`
	Detail         *string     `json:"detail"`
	SourceEvidence string      `json:"source_evidence"`
	DateExpression *string     `json:"date_expression"`
	Due            Due         `json:"due"`
	Remind         *Remind     `json:"remind"`
	CourseHint     *string     `json:"course_hint"`
	PlaceHint      *string     `json:"place_hint"`
	Ambiguities    []Ambiguity `json:"ambiguities"`
	Confidence     *float64    `json:"confidence"`
}

// Due 描述截止时间。kind=date 时只有 local（YYYY-MM-DD），绝不伪造成 UTC 午夜。
type Due struct {
	Kind     string  `json:"kind"`
	Local    *string `json:"local"`
	UTC      *string `json:"utc"`
	Timezone *string `json:"timezone"`
}

// Remind 描述提醒时刻；为 nil 表示没有设置提醒时间（不等于没有截止日）。
type Remind struct {
	Kind     string `json:"kind"`
	Local    string `json:"local"`
	UTC      string `json:"utc"`
	Timezone string `json:"timezone"`
}

// Ambiguity 是需要用户确认的不确定点。
type Ambiguity struct {
	Code    string `json:"code"`
	Field   string `json:"field"`
	Message string `json:"message"`
}

// Validate 校验请求体的结构与语义，返回面向用户的中文提示。
func (r Request) Validate() error {
	if r.SchemaVersion != SchemaVersion {
		return errors.New("schema_version 必须是 " + SchemaVersion + "。")
	}
	if strings.TrimSpace(r.CaptureID) == "" || len(r.CaptureID) > 64 {
		return errors.New("capture_id 不能为空且长度不超过 64。")
	}
	switch r.Source.Type {
	case "text", "asr", "ocr":
	default:
		return errors.New("source.type 必须是 text、asr 或 ocr。")
	}
	text := strings.TrimSpace(r.Source.Text)
	if text == "" {
		return errors.New("source.text 不能为空。")
	}
	if len([]rune(text)) > 8000 {
		return errors.New("source.text 过长，请拆分后再提交。")
	}
	if _, err := time.Parse(time.RFC3339, r.RecordedAt); err != nil {
		return errors.New("recorded_at 必须是 RFC3339 时间。")
	}
	if _, err := time.LoadLocation(r.Timezone); err != nil {
		return errors.New("timezone 必须是合法的 IANA 时区名，例如 Asia/Shanghai。")
	}
	return nil
}

// RecordedTime 返回解析后的录入时刻；调用前必须先通过 Validate。
func (r Request) RecordedTime() (time.Time, error) {
	return time.Parse(time.RFC3339, r.RecordedAt)
}
