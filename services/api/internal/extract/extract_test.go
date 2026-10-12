package extract

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	_ "time/tzdata"

	"github.com/jolaaa999/DayCue/services/api/internal/llm"
)

// repoPath 从测试文件往上找到仓库根，让契约 fixture 保持唯一事实来源，
// 而不是在测试里再抄一份期望值。
func repoPath(t *testing.T, rel string) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("无法定位测试文件")
	}
	dir := filepath.Dir(file)
	for i := 0; i < 12; i++ {
		candidate := filepath.Join(dir, rel)
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("在仓库中找不到 %s", rel)
	return ""
}

func loadJSON(t *testing.T, path string, dst any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取 %s 失败: %v", path, err)
	}
	if err := json.Unmarshal(b, dst); err != nil {
		t.Fatalf("解析 %s 失败: %v", path, err)
	}
}

func memLoc(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("加载时区失败: %v", err)
	}
	return loc
}

// TestNormalizeMatchesContractFixture 是契约金丝雀：模型输出 -> 归一化结果
// 必须与 contracts/fixtures/extract-os-pv.response.json 完全一致。
// 设置 DAYCUE_UPDATE_FIXTURE=1 可按当前实现重新生成该文件。
func TestNormalizeMatchesContractFixture(t *testing.T) {
	var req Request
	loadJSON(t, repoPath(t, filepath.Join("contracts", "fixtures", "extract-os-pv.request.json")), &req)
	if err := req.Validate(); err != nil {
		t.Fatalf("样例请求应通过校验: %v", err)
	}
	recordedAt, err := req.RecordedTime()
	if err != nil {
		t.Fatalf("recorded_at 解析失败: %v", err)
	}
	loc := memLoc(t, req.Timezone)

	// 用模拟供应商产出"模型原始输出"，再走真实的归一化路径。
	provider := llm.NewFixture()
	out, err := provider.Complete(context.Background(), SystemPrompt(), BuildUserMessage(req, recordedAt, loc))
	if err != nil {
		t.Fatalf("模拟供应商失败: %v", err)
	}
	got, err := Normalize(out, req, recordedAt, loc, 0)
	if err != nil {
		t.Fatalf("归一化失败: %v", err)
	}

	if len(got.Items) != 3 {
		t.Fatalf("期望 3 条候选，实得 %d", len(got.Items))
	}
	if got.Items[0].Kind != "note" {
		t.Errorf("第 1 条应为笔记，实得 %s", got.Items[0].Kind)
	}
	if got.Items[1].Due.Kind != "datetime" || got.Items[1].Due.Local == nil || *got.Items[1].Due.Local != "2026-10-12T20:00:00" {
		t.Errorf("第 2 条应解析为 2026-10-12 20:00，实得 %+v", got.Items[1].Due)
	}
	if got.Items[1].Due.UTC == nil || *got.Items[1].Due.UTC != "2026-10-12T12:00:00Z" {
		t.Errorf("第 2 条的 UTC 换算不正确: %+v", got.Items[1].Due.UTC)
	}
	if got.Items[2].Remind != nil {
		t.Errorf("「周五之前」不得自动补出提醒时刻，实得 %+v", got.Items[2].Remind)
	}
	if got.Items[0].Remind != nil {
		t.Errorf("笔记不应带提醒，实得 %+v", got.Items[0].Remind)
	}
	if !hasAmbCode(got.Items[2].Ambiguities, "deadline_only") {
		t.Errorf("「周五之前」应带 deadline_only，实得 %+v", got.Items[2].Ambiguities)
	}

	path := repoPath(t, filepath.Join("contracts", "fixtures", "extract-os-pv.response.json"))
	if os.Getenv("DAYCUE_UPDATE_FIXTURE") == "1" {
		b, err := json.MarshalIndent(got, "", "  ")
		if err != nil {
			t.Fatalf("序列化失败: %v", err)
		}
		if err := os.WriteFile(path, append(b, 0x0A), 0o644); err != nil {
			t.Fatalf("写入 fixture 失败: %v", err)
		}
		t.Logf("已按当前实现重新生成 %s", path)
		return
	}

	var want map[string]any
	loadJSON(t, path, &want)
	gotBytes, _ := json.Marshal(got)
	var gotMap map[string]any
	if err := json.Unmarshal(gotBytes, &gotMap); err != nil {
		t.Fatalf("序列化结果无法解析: %v", err)
	}
	if !reflect.DeepEqual(want, gotMap) {
		wantBytes, _ := json.MarshalIndent(want, "", "  ")
		gotPretty, _ := json.MarshalIndent(gotMap, "", "  ")
		t.Errorf("响应与契约 fixture 不一致\n期望:\n%s\n实得:\n%s", wantBytes, gotPretty)
	}
}

func hasAmbCode(list []Ambiguity, code string) bool {
	for _, a := range list {
		if a.Code == code {
			return true
		}
	}
	return false
}

func baseRequest() Request {
	return Request{
		SchemaVersion: SchemaVersion,
		CaptureID:     "cap_test_01",
		Source:        Source{Type: "text", Text: "明天交作业"},
		RecordedAt:    "2026-10-11T11:30:00Z",
		Timezone:      "Asia/Shanghai",
	}
}

func TestNormalizeRejectsNonJSON(t *testing.T) {
	req := baseRequest()
	_, err := Normalize(llm.Result{Text: "抱歉，我不确定你是什么意思。", Provider: "stub", Model: "m"}, req, mustTime(t, req.RecordedAt), memLoc(t, req.Timezone), 0)
	if err != ErrModelOutputInvalid {
		t.Fatalf("非 JSON 输出必须返回 ErrModelOutputInvalid，实得 %v", err)
	}
}

func TestNormalizeAcceptsFencedJSON(t *testing.T) {
	req := baseRequest()
	inner := `{"items":[{"kind":"task","title":"交作业","source_evidence":"明天交作业","date_expression":"明天"}]}`
	raw := "```json" + "\n" + inner + "\n" + "```"
	got, err := Normalize(llm.Result{Text: raw, Provider: "stub", Model: "m"}, req, mustTime(t, req.RecordedAt), memLoc(t, req.Timezone), 0)
	if err != nil {
		t.Fatalf("围栏 JSON 应被接受: %v", err)
	}
	if len(got.Items) != 1 || got.Items[0].Due.Kind != "date" {
		t.Fatalf("解析结果不符合预期: %+v", got.Items)
	}
}

func TestNormalizeDropsFabricatedEvidence(t *testing.T) {
	req := baseRequest()
	raw := `{"items":[{"kind":"task","title":"买牛奶","source_evidence":"用户说要买牛奶","date_expression":""}]}`
	got, err := Normalize(llm.Result{Text: raw, Provider: "stub", Model: "m"}, req, mustTime(t, req.RecordedAt), memLoc(t, req.Timezone), 0)
	if err != nil {
		t.Fatalf("归一化失败: %v", err)
	}
	if got.Items[0].SourceEvidence != "" {
		t.Errorf("原文里没有的依据必须被清除，实得 %q", got.Items[0].SourceEvidence)
	}
	if !hasAmbCode(got.Items[0].Ambiguities, "model_uncertain") {
		t.Errorf("编造依据必须标记 model_uncertain，实得 %+v", got.Items[0].Ambiguities)
	}
}

func TestNormalizeUnresolvedTimeIsNotInvented(t *testing.T) {
	req := baseRequest()
	raw := `{"items":[{"kind":"task","title":"交作业","source_evidence":"明天交作业","date_expression":"下个黄道吉日"}]}`
	got, err := Normalize(llm.Result{Text: raw, Provider: "stub", Model: "m"}, req, mustTime(t, req.RecordedAt), memLoc(t, req.Timezone), 0)
	if err != nil {
		t.Fatalf("归一化失败: %v", err)
	}
	if got.Items[0].Due.Kind != "none" {
		t.Errorf("无法解析的表达不得产生截止时间，实得 %+v", got.Items[0].Due)
	}
	if got.Items[0].Remind != nil {
		t.Errorf("无法解析的表达不得产生提醒，实得 %+v", got.Items[0].Remind)
	}
	if !hasAmbCode(got.Items[0].Ambiguities, "unresolved_date") {
		t.Errorf("应标记 unresolved_date，实得 %+v", got.Items[0].Ambiguities)
	}
}

func TestNormalizeAllInvalidIsError(t *testing.T) {
	req := baseRequest()
	raw := `{"items":[{"kind":"reminder","title":""},{"kind":"","title":""}]}`
	if _, err := Normalize(llm.Result{Text: raw, Provider: "stub", Model: "m"}, req, mustTime(t, req.RecordedAt), memLoc(t, req.Timezone), 0); err != ErrModelOutputInvalid {
		t.Fatalf("全部候选非法时必须报错，实得 %v", err)
	}
}

func TestNormalizeEmptyItemsIsNotError(t *testing.T) {
	req := baseRequest()
	got, err := Normalize(llm.Result{Text: `{"items":[]}`, Provider: "stub", Model: "m"}, req, mustTime(t, req.RecordedAt), memLoc(t, req.Timezone), 0)
	if err != nil {
		t.Fatalf("空候选不是错误: %v", err)
	}
	if len(got.Items) != 0 || len(got.Warnings) == 0 {
		t.Fatalf("空候选应带提示: %+v", got)
	}
}

func TestExtractPropagatesProviderTimeout(t *testing.T) {
	req := baseRequest()
	_, err := Extract(context.Background(), req, errProvider{})
	if err != llm.ErrTimeout {
		t.Fatalf("上游超时必须原样传播，实得 %v", err)
	}
}

type errProvider struct{}

func (errProvider) Name() string  { return "stub" }
func (errProvider) Model() string { return "stub" }
func (errProvider) Complete(ctx context.Context, system, user string) (llm.Result, error) {
	return llm.Result{}, llm.ErrTimeout
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("时间解析失败: %v", err)
	}
	return v
}
