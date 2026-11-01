package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// 假上游：把收到的 messages 原样回传，好让测试断言客户端到底发了什么。
func captureMessages(t *testing.T, call func(baseURL string)) []struct{ Role, Content string } {
	t.Helper()
	var got []struct{ Role, Content string }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("请求体解析失败: %v", err)
		}
		for _, m := range body.Messages {
			got = append(got, struct{ Role, Content string }{m.Role, m.Content})
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"{}"}}],"usage":{}}`))
	}))
	defer srv.Close()
	call(srv.URL)
	return got
}

// 默认行为：system 与 user 分开送，职责分离不被悄悄改掉。
func TestCompleteKeepsSystemRoleByDefault(t *testing.T) {
	got := captureMessages(t, func(baseURL string) {
		c := NewOpenAI(baseURL, "k", "m", 5*time.Second, false)
		if _, err := c.Complete(context.Background(), "指令", "原文"); err != nil {
			t.Fatalf("调用失败: %v", err)
		}
	})
	if len(got) != 2 {
		t.Fatalf("期望 2 条消息，实际 %d", len(got))
	}
	if got[0].Role != "system" || got[1].Role != "user" {
		t.Fatalf("角色顺序不对: %+v", got)
	}
}

// 打开合并后只能发一条 user 消息，且指令与原文都在里面。
// 这条路径是给「丢弃 system 消息」的中转端点兜底的：真机上不合并时，
// 模型收到了原文却看不到格式要求，于是自己造字段名、自己算日期。
func TestCompleteMergesSystemPromptIntoUserWhenEnabled(t *testing.T) {
	got := captureMessages(t, func(baseURL string) {
		c := NewOpenAI(baseURL, "k", "m", 5*time.Second, true)
		if _, err := c.Complete(context.Background(), "指令", "原文"); err != nil {
			t.Fatalf("调用失败: %v", err)
		}
	})
	if len(got) != 1 {
		t.Fatalf("期望合并成 1 条消息，实际 %d", len(got))
	}
	if got[0].Role != "user" {
		t.Fatalf("合并后角色应为 user，实际 %s", got[0].Role)
	}
	if !strings.Contains(got[0].Content, "指令") || !strings.Contains(got[0].Content, "原文") {
		t.Fatalf("合并后内容缺少指令或原文: %s", got[0].Content)
	}
}
