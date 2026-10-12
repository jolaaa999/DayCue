package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 客户端上报时区的处理。
//
// 这条链路之前是断的：两个客户端都在每个请求上带 X-DayCue-Timezone，
// 而服务端完全忽略它，于是预算、静默时段与每日重置只能按 UTC 算。
// 下面的用例把「接上了」这件事钉住，也把几个刻意的边界钉住。

// requestWithTimezone 发一个带时区头的已鉴权请求。
func (f *accountFixture) requestWithTimezone(t *testing.T, method, path, token, timezone string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	if timezone != "" {
		req.Header.Set("X-DayCue-Timezone", timezone)
	}
	rec := httptest.NewRecorder()
	f.handler.ServeHTTP(rec, req)
	return rec
}

func (f *accountFixture) storedTimezone(t *testing.T, userID string) string {
	t.Helper()
	tz, err := f.users.UserTimeZone(context.Background(), userID)
	if err != nil {
		t.Fatalf("读取测试用户时区失败: %v", err)
	}
	return tz
}

func TestReportedTimezoneIsPersisted(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "u_tz1", "tz1@example.com")
	if got := f.storedTimezone(t, "u_tz1"); got != "" {
		t.Fatalf("前提不成立：新用户的时区应当是「未知」，实际 %q", got)
	}

	rec := f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "Asia/Shanghai")
	if rec.Code != http.StatusOK {
		t.Fatalf("列设备应当成功，实际 %d：%s", rec.Code, rec.Body.String())
	}
	if got := f.storedTimezone(t, "u_tz1"); got != "Asia/Shanghai" {
		t.Fatalf("客户端上报的时区应当被存下来，实际 %q", got)
	}
}

func TestReportedTimezoneChangeIsApplied(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "u_tz2", "tz2@example.com")

	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "Asia/Shanghai")
	if got := f.storedTimezone(t, "u_tz2"); got != "Asia/Shanghai" {
		t.Fatalf("首次写入失败，实际 %q", got)
	}

	// 用户出行换了时区：下一次请求就该跟上，不能只在首次生效。
	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "America/New_York")
	if got := f.storedTimezone(t, "u_tz2"); got != "America/New_York" {
		t.Fatalf("时区变更应当生效，实际 %q", got)
	}
}

func TestMissingTimezoneHeaderKeepsStoredValue(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "u_tz3", "tz3@example.com")

	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "Asia/Shanghai")
	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "")

	if got := f.storedTimezone(t, "u_tz3"); got != "Asia/Shanghai" {
		t.Fatalf("没有上报头时不得改动已存的值，实际 %q", got)
	}
}

// TestBlankTimezoneHeaderDoesNotClearStoredValue 钉住一个刻意的边界。
//
// 空串在存储层有确定的语义（"未知"，读时回退 UTC）。如果漏发头的客户端
// 能把用户的时区抹成"未知"，用户的预算与静默时段就会无声无息地按 UTC 计算——
// 所以这里必须忽略，而不是当成"清空"。
func TestBlankTimezoneHeaderDoesNotClearStoredValue(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "u_tz4", "tz4@example.com")

	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "Asia/Shanghai")
	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "   ")

	if got := f.storedTimezone(t, "u_tz4"); got != "Asia/Shanghai" {
		t.Fatalf("空白时区不得清空已存的值，实际 %q", got)
	}
}

// TestInvalidTimezoneIsIgnoredWithoutFailingRequest 钉住另一个边界：
// 时区是环境的附属信息，一个畸形的头不该让整个请求失败。
func TestInvalidTimezoneIsIgnoredWithoutFailingRequest(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "u_tz5", "tz5@example.com")

	f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "Asia/Shanghai")
	rec := f.requestWithTimezone(t, http.MethodGet, "/v1/devices", token, "Mars/Phobos")

	if rec.Code != http.StatusOK {
		t.Fatalf("畸形时区不该让请求失败，实际 %d：%s", rec.Code, rec.Body.String())
	}
	if got := f.storedTimezone(t, "u_tz5"); got != "Asia/Shanghai" {
		t.Fatalf("畸形时区不得覆盖已存的值，实际 %q", got)
	}
}
