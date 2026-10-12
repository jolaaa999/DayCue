package llm

import (
	"context"
	"strings"
)

// Fixture 是显式启用的模拟供应商：只在 DAYCUE_FIXTURE_MODE=1 时被装载。
// 它返回固定样例，绝不冒充真实模型调用；响应里的 mode 会被标记为 fixture。
type Fixture struct{}

func NewFixture() *Fixture { return &Fixture{} }

func (f *Fixture) Name() string  { return "fixture" }
func (f *Fixture) Model() string { return "fixture-rules-v1" }

// Complete 只在输入命中设计文档 5.1 的样例时返回预设拆分，否则返回空结果，
// 这样既不会伪造结构，也让开发者一眼看出这是模拟数据。
func (f *Fixture) Complete(ctx context.Context, system, user string) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{}, ErrTimeout
	}
	if strings.Contains(user, "PV") {
		return Result{Text: fixturePVOutput, Provider: f.Name(), Model: f.Model()}, nil
	}
	return Result{Text: fixtureEmptyOutput, Provider: f.Name(), Model: f.Model()}, nil
}

const fixturePVOutput = `{
  "items": [
    {
      "kind": "note",
      "title": "操作系统讲到 PV 操作",
      "detail": "今天操作系统讲了 PV 操作，我还是没理解。",
      "source_evidence": "今天操作系统讲了 PV 操作，我还是没理解",
      "date_expression": "",
      "course_hint": "操作系统",
      "place_hint": "",
      "confidence": 0.92
    },
    {
      "kind": "task",
      "title": "复习操作系统 PV 操作",
      "detail": "",
      "source_evidence": "明晚八点提醒我复习",
      "date_expression": "明晚八点",
      "course_hint": "操作系统",
      "place_hint": "",
      "confidence": 0.88
    },
    {
      "kind": "task",
      "title": "交实验报告",
      "detail": "",
      "source_evidence": "周五之前交实验报告",
      "date_expression": "周五之前",
      "course_hint": "",
      "place_hint": "",
      "confidence": 0.8
    }
  ],
  "warnings": []
}`

const fixtureEmptyOutput = `{
  "items": [],
  "warnings": ["模拟结果：输入未命中预设样例，未做任何结构化拆分"]
}`
