package extract

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/llm"
	"github.com/jolaaa999/DayCue/services/api/internal/temporal"
)

// ambModelUncertain 表示「模型给的原文依据在输入里找不到」。
// 它属于提取层的判断，不属于时间解析，所以不放 temporal 包。
const ambModelUncertain = "model_uncertain"

// modelOutput 是模型**唯一**被允许返回的形状：只有"时间表达"，没有绝对时刻。
// 这样即使模型算错日期也无从生效，因为绝对时刻由 temporal 包重算。
type modelOutput struct {
	Items []struct {
		Kind           string  `json:"kind"`
		Title          string  `json:"title"`
		Detail         string  `json:"detail"`
		SourceEvidence string  `json:"source_evidence"`
		DateExpression string  `json:"date_expression"`
		CourseHint     string  `json:"course_hint"`
		PlaceHint      string  `json:"place_hint"`
		Confidence     float64 `json:"confidence"`
	} `json:"items"`
	Warnings []string `json:"warnings"`
}

// Extract 调用供应商并做确定性归一化。
func Extract(ctx context.Context, req Request, p llm.Provider) (Response, error) {
	recordedAt, err := req.RecordedTime()
	if err != nil {
		return Response{}, err
	}
	loc, err := time.LoadLocation(req.Timezone)
	if err != nil {
		return Response{}, err
	}

	begin := time.Now()
	out, err := p.Complete(ctx, SystemPrompt(), BuildUserMessage(req, recordedAt, loc))
	latency := time.Since(begin).Milliseconds()
	if err != nil {
		return Response{}, err
	}
	return Normalize(out, req, recordedAt, loc, latency)
}

// Normalize 把模型输出转成契约响应。任何一条候选的绝对时刻都在这里重算。
func Normalize(out llm.Result, req Request, recordedAt time.Time, loc *time.Location, latencyMS int64) (Response, error) {
	parsed, err := parseModelOutput(out.Text)
	if err != nil {
		return Response{}, err
	}

	mode := "live"
	if out.Provider == "fixture" {
		mode = "fixture"
	}

	resp := Response{
		SchemaVersion: SchemaVersion,
		CaptureID:     req.CaptureID,
		Mode:          mode,
		Items:         []Item{},
		Warnings:      []string{},
		Usage: &Usage{
			Provider:         out.Provider,
			Model:            out.Model,
			LatencyMS:        latencyMS,
			PromptTokens:     out.PromptTokens,
			CompletionTokens: out.CompletionTokens,
		},
	}
	resp.Warnings = append(resp.Warnings, parsed.Warnings...)

	source := squash(req.Source.Text)
	skipped := 0

	for _, raw := range parsed.Items {
		if len(resp.Items) >= MaxItems {
			resp.Warnings = append(resp.Warnings, "候选超过 20 条，超出部分已忽略。")
			break
		}

		kind := strings.ToLower(strings.TrimSpace(raw.Kind))
		title := clipRunes(strings.TrimSpace(raw.Title), 200)
		if (kind != "task" && kind != "note") || title == "" {
			// 结构不完整的候选一律丢弃，宁可少写也不要写错一条任务。
			skipped++
			continue
		}

		ambs := []Ambiguity{}

		// 依据必须能在原文里找到，否则说明模型在编造，清除并提示用户核对。
		evidence := strings.TrimSpace(raw.SourceEvidence)
		if evidence == "" || !strings.Contains(source, squash(evidence)) {
			if evidence != "" {
				ambs = append(ambs, Ambiguity{Code: ambModelUncertain, Field: "source_evidence",
					Message: "模型给出的原文依据与输入不一致，已清除依据，请核对这条候选。"})
			} else {
				ambs = append(ambs, Ambiguity{Code: ambModelUncertain, Field: "source_evidence",
					Message: "模型没有给出原文依据，请核对这条候选。"})
			}
			evidence = ""
		}

		expr := strings.TrimSpace(raw.DateExpression)
		var dateExpr *string
		if expr != "" {
			e := clipRunes(expr, 100)
			dateExpr = &e
		}

		res := temporal.Resolution{Kind: temporal.KindNone}
		if expr != "" {
			res = temporal.Resolve(expr, recordedAt, loc)
		}

		item := Item{
			ItemID:         "itm_" + itoa(len(resp.Items)+1),
			Kind:           kind,
			Title:          title,
			Detail:         optional(clipRunes(strings.TrimSpace(raw.Detail), 2000)),
			SourceEvidence: evidence,
			DateExpression: dateExpr,
			Due:            Due{Kind: temporal.KindNone},
			CourseHint:     optional(clipRunes(strings.TrimSpace(raw.CourseHint), 100)),
			PlaceHint:      optional(clipRunes(strings.TrimSpace(raw.PlaceHint), 100)),
			Ambiguities:    ambs,
			Confidence:     clampConfidence(raw.Confidence),
		}

		// 笔记没有截止与提醒；只有行动任务才落到 Due / Remind。
		if kind == "task" {
			local := res.Local
			utc := res.UTC
			tz := req.Timezone
			switch res.Kind {
			case temporal.KindDatetime:
				item.Due = Due{Kind: "datetime", Local: &local, UTC: &utc, Timezone: &tz}
				// 明确写出了时刻，就把它作为提醒时刻；用户仍可在预览页改。
				item.Remind = &Remind{Kind: "absolute", Local: local, UTC: utc, Timezone: tz}
			case temporal.KindDate:
				// 只有截止日，没有提醒时刻：绝不替用户编造一个时间。
				item.Due = Due{Kind: "date", Local: &local, Timezone: &tz}
			}
			for _, a := range res.Ambiguities {
				item.Ambiguities = append(item.Ambiguities, Ambiguity{Code: a.Code, Field: a.Field, Message: a.Message})
			}
		}

		resp.Items = append(resp.Items, item)
	}

	// 全部候选都不合法，说明模型输出不可用：报错而不是返回半成品。
	if len(parsed.Items) > 0 && len(resp.Items) == 0 {
		return Response{}, ErrModelOutputInvalid
	}
	if len(resp.Items) == 0 {
		resp.Warnings = append(resp.Warnings, "这段内容里没有可整理的明确事项。")
	}
	return resp, nil
}

// parseModelOutput 容忍 Markdown 代码块围栏，但拒绝任何非 JSON 的返回。
func parseModelOutput(text string) (modelOutput, error) {
	var out modelOutput
	if err := json.Unmarshal([]byte(stripFence(text)), &out); err != nil {
		if err := json.Unmarshal([]byte(outermostJSON(text)), &out); err != nil {
			return modelOutput{}, ErrModelOutputInvalid
		}
	}
	return out, nil
}

func stripFence(s string) string {
	t := strings.TrimSpace(s)
	if !strings.HasPrefix(t, "```") {
		return t
	}
	if i := strings.IndexByte(t, 0x0A); i >= 0 {
		t = t[i+1:]
	}
	t = strings.TrimSpace(t)
	t = strings.TrimSuffix(t, "```")
	return strings.TrimSpace(t)
}

func outermostJSON(s string) string {
	i := strings.IndexByte(s, '{')
	j := strings.LastIndexByte(s, '}')
	if i >= 0 && j > i {
		return s[i : j+1]
	}
	return s
}

// squash 去掉全部空白，用于"依据是否出自原文"的比对，避免空格差异造成误判。
func squash(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch r {
		case 0x20, 0x09, 0x0A, 0x0D, 0x3000:
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func clampConfidence(v float64) *float64 {
	if v < 0 {
		v = 0
	}
	if v > 1 {
		v = 1
	}
	return &v
}

func clipRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [8]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
