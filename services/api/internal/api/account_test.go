package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/authn"
	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/media"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

// 固定时间基准：所有断言都基于它，测试才不会因为"跑在半夜"而变脆。
var fixedNow = time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)

func fixedNowFn() time.Time { return fixedNow }

// 口令派生很贵（210k 次迭代），测试里只算一次，避免每个用例都要付一遍代价。
var testPasswordHashOnce = sync.OnceValue(func() string {
	h, err := authn.HashPassword("correct-horse-battery")
	if err != nil {
		panic(err)
	}
	return h
})

func testPasswordHash() string { return testPasswordHashOnce() }

type accountFixture struct {
	handler http.Handler
	deps    AccountDeps
	users   *store.Memory
	svc     *syncsvc.Service
	issuer  *authn.Issuer
}

func newAccountFixture(t *testing.T) *accountFixture {
	t.Helper()
	users := store.NewMemory(fixedNowFn)
	svc := &syncsvc.Service{Sync: users, Exporter: users, Now: fixedNowFn}
	mediaStore, err := media.NewFS(t.TempDir(), media.NewMemoryCatalog(), 1<<20, fixedNowFn)
	if err != nil {
		t.Fatalf("构造媒体存储失败: %v", err)
	}
	issuer, err := authn.NewIssuer(strings.Repeat("t", 32), fixedNowFn)
	if err != nil {
		t.Fatalf("构造签发器失败: %v", err)
	}
	deps := AccountDeps{Users: users, Sync: svc, Media: mediaStore, Issuer: issuer, Now: fixedNowFn}
	h, err := NewAccountHandler(deps)
	if err != nil {
		t.Fatalf("构造账号处理器失败: %v", err)
	}
	return &accountFixture{handler: h.Routes(), deps: deps, users: users, svc: svc, issuer: issuer}
}

// seedUser 直接写库并签发令牌：注册接口本身有专门的用例覆盖，
// 其他用例没必要为此反复付口令派生的代价。
func (f *accountFixture) seedUser(t *testing.T, id, email string) string {
	t.Helper()
	u := store.User{
		ID: id, Email: email, PasswordHash: testPasswordHash(),
		CreatedAt: fixedNow, UpdatedAt: fixedNow,
	}
	if err := f.users.CreateUser(context.Background(), u); err != nil {
		t.Fatalf("写入测试用户失败: %v", err)
	}
	token, err := f.issuer.Issue(id, time.Hour)
	if err != nil {
		t.Fatalf("签发测试令牌失败: %v", err)
	}
	return token
}

func requestWith(t *testing.T, h http.Handler, method, path, token, body, contentType string) *httptest.ResponseRecorder {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, path, reader)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func (f *accountFixture) request(t *testing.T, method, path, token, body, contentType string) *httptest.ResponseRecorder {
	t.Helper()
	return requestWith(t, f.handler, method, path, token, body, contentType)
}

func (f *accountFixture) postJSON(t *testing.T, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	return f.request(t, http.MethodPost, path, token, body, "application/json")
}

func (f *accountFixture) uploadMedia(t *testing.T, token, ownerType, ownerID, contentType string, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if err := mw.WriteField("owner_type", ownerType); err != nil {
		t.Fatal(err)
	}
	if err := mw.WriteField("owner_id", ownerID); err != nil {
		t.Fatal(err)
	}
	hdr := textproto.MIMEHeader{}
	hdr.Set("Content-Disposition", `form-data; name="file"; filename="upload.bin"`)
	hdr.Set("Content-Type", contentType)
	part, err := mw.CreatePart(hdr)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/media", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	f.handler.ServeHTTP(rec, req)
	return rec
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder, dst any) {
	t.Helper()
	if err := json.Unmarshal(rec.Body.Bytes(), dst); err != nil {
		t.Fatalf("响应不是预期 JSON: %v (%s)", err, rec.Body.String())
	}
}

func pushItems(t *testing.T, f *accountFixture, token, body string) syncPushResponse {
	t.Helper()
	rec := f.postJSON(t, "/v1/sync/push", token, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("推送应返回 200，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var out syncPushResponse
	decodeBody(t, rec, &out)
	return out
}

// ---------- 鉴权 ----------

func TestAccountEndpointsRequireToken(t *testing.T) {
	f := newAccountFixture(t)
	cases := []struct{ method, path, body string }{
		{http.MethodGet, "/v1/devices", ""},
		{http.MethodPost, "/v1/devices", `{}`},
		{http.MethodDelete, "/v1/devices/dev_missing", ""},
		{http.MethodPost, "/v1/sync/push", `{"items":[]}`},
		{http.MethodGet, "/v1/sync/pull", ""},
		{http.MethodPost, "/v1/media", ""},
		{http.MethodGet, "/v1/media/med_missing", ""},
		{http.MethodDelete, "/v1/media/med_missing", ""},
		{http.MethodGet, "/v1/export", ""},
		{http.MethodDelete, "/v1/account", ""},
	}
	for _, tc := range cases {
		rec := f.request(t, tc.method, tc.path, "", tc.body, "application/json")
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s 无令牌应返回 401，实得 %d: %s", tc.method, tc.path, rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), `"code":"unauthorized"`) {
			t.Errorf("%s %s 错误码应为 unauthorized: %s", tc.method, tc.path, rec.Body.String())
		}
	}
	// 伪造令牌同样必须 401。
	rec := f.request(t, http.MethodGet, "/v1/export", "not-a-real-token", "", "")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("伪造令牌应返回 401，实得 %d", rec.Code)
	}
}

func TestEndpointsRejectUserIDFromBody(t *testing.T) {
	f := newAccountFixture(t)
	// DecodeJSON 拒绝未知字段：请求体里的 user_id 必须变成 400，而不是被静默接受。
	rec := f.postJSON(t, "/v1/auth/register", "",
		`{"email":"x@example.com","password":"longenough1","user_id":"usr_b"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("注册体带 user_id 应返回 400，实得 %d: %s", rec.Code, rec.Body.String())
	}

	tokenA := f.seedUser(t, "usr_a", "a@example.com")
	rec = f.postJSON(t, "/v1/sync/push", tokenA, `{"user_id":"usr_b","items":[]}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("推送体带 user_id 应返回 400，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCrossUserAccessIsNotFound(t *testing.T) {
	f := newAccountFixture(t)
	tokenA := f.seedUser(t, "usr_a", "a@example.com")
	tokenB := f.seedUser(t, "usr_b", "b@example.com")

	// B 上传一份媒体。
	rec := f.uploadMedia(t, tokenB, "capture", "cap_b", "image/png", []byte("fake-png-bytes"))
	if rec.Code != http.StatusCreated {
		t.Fatalf("B 上传媒体应成功，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var uploaded mediaResponse
	decodeBody(t, rec, &uploaded)

	// A 访问 B 的媒体：必须是 404，而不是 200 或 403（403 会泄漏"这个 ID 确实存在"）。
	rec = f.request(t, http.MethodGet, "/v1/media/"+uploaded.ID, tokenA, "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("越权读媒体应返回 404，实得 %d: %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "fake-png") {
		t.Errorf("404 响应不得泄漏对象内容: %s", rec.Body.String())
	}

	// B 建一台设备，A 删除它 → 404。
	rec = f.postJSON(t, "/v1/devices", tokenB, `{"id":"dev_bbbbbbbb","platform":"ios","name":"B 的手机"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("B 建设备应成功，实得 %d: %s", rec.Code, rec.Body.String())
	}
	rec = f.request(t, http.MethodDelete, "/v1/devices/dev_bbbbbbbb", tokenA, "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("越权删设备应返回 404，实得 %d: %s", rec.Code, rec.Body.String())
	}

	// B 写一条同步记录，A 的拉取与导出都必须看不到。
	pushItems(t, f, tokenB, `{"items":[{"type":"task","id":"task_b","base_version":0,"payload":{"title":"B 的任务"}}]}`)
	for _, path := range []string{"/v1/sync/pull", "/v1/export"} {
		rec = f.request(t, http.MethodGet, path, tokenA, "", "")
		if rec.Code != http.StatusOK {
			t.Fatalf("%s 应返回 200，实得 %d: %s", path, rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "task_b") || strings.Contains(rec.Body.String(), "B 的任务") {
			t.Errorf("%s 泄漏了其他用户的数据: %s", path, rec.Body.String())
		}
	}
}

// ---------- 注册 / 登录 ----------

func TestRegisterRejectsDuplicateEmail(t *testing.T) {
	f := newAccountFixture(t)
	body := `{"email":"dup@example.com","password":"longenough1","device":{"platform":"ios","name":"我的 iPhone"}}`

	rec := f.postJSON(t, "/v1/auth/register", "", body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("首次注册应返回 201，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var first authResponse
	decodeBody(t, rec, &first)
	if first.UserID == "" || first.Token == "" {
		t.Fatalf("注册响应缺少 user_id/token: %s", rec.Body.String())
	}
	if first.Device == nil || first.Device.ID == "" {
		t.Fatalf("注册时携带的设备应被登记: %s", rec.Body.String())
	}

	rec = f.postJSON(t, "/v1/auth/register", "", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("重复邮箱应失败，实得 %d: %s", rec.Code, rec.Body.String())
	}

	// 大小写不同但仍是同一邮箱，也必须被拒绝。
	rec = f.postJSON(t, "/v1/auth/register", "",
		`{"email":"DUP@example.com","password":"longenough1"}`)
	if rec.Code == http.StatusCreated || rec.Code == http.StatusOK {
		t.Fatalf("大小写不同的同一邮箱必须被拒绝，实得 %d: %s", rec.Code, rec.Body.String())
	}

	// 第一次注册的账号仍能用原口令登录，且 user_id 不变。
	rec = f.postJSON(t, "/v1/auth/login", "",
		`{"email":"dup@example.com","password":"longenough1"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("登录应成功，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var login authResponse
	decodeBody(t, rec, &login)
	if login.UserID != first.UserID {
		t.Errorf("登录返回的 user_id 与注册不一致: %q vs %q", login.UserID, first.UserID)
	}
}

func TestLoginFailuresAreIndistinguishable(t *testing.T) {
	f := newAccountFixture(t)
	f.seedUser(t, "usr_a", "a@example.com")

	wrongPassword := f.postJSON(t, "/v1/auth/login", "",
		`{"email":"a@example.com","password":"definitely-wrong"}`)
	unknownEmail := f.postJSON(t, "/v1/auth/login", "",
		`{"email":"nobody@example.com","password":"definitely-wrong"}`)

	if wrongPassword.Code != http.StatusUnauthorized || unknownEmail.Code != http.StatusUnauthorized {
		t.Fatalf("两种登录失败都应返回 401，实得 %d / %d", wrongPassword.Code, unknownEmail.Code)
	}
	var a, b httpx.ErrorResponse
	decodeBody(t, wrongPassword, &a)
	decodeBody(t, unknownEmail, &b)
	if a.Error.Code != b.Error.Code || a.Error.Message != b.Error.Message {
		t.Errorf("账号不存在与口令错误的响应必须完全一致: %+v vs %+v", a.Error, b.Error)
	}
}

// TestDummyPasswordHashIsWellFormed 保证登录接口的计时抹平不是空谈：
// 占位哈希必须与真实哈希同格式、同迭代次数，否则它在"账号不存在"分支里
// 要么立刻失败（等于没跑派生），要么格式非法（authn 直接拒绝）。
func TestDummyPasswordHashIsWellFormed(t *testing.T) {
	parts := strings.Split(dummyPasswordHash, "$")
	if len(parts) != 5 || parts[0] != "pbkdf2" || parts[1] != "sha256" {
		t.Fatalf("占位哈希格式不正确: %q", dummyPasswordHash)
	}
	if parts[2] != "210000" {
		t.Errorf("迭代次数必须与 authn.defaultIterations 一致，实得 %q", parts[2])
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil || len(salt) != 16 {
		t.Fatalf("盐必须是 16 字节的合法 base64: len=%d err=%v", len(salt), err)
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(want) != 32 {
		t.Fatalf("目标哈希必须是 32 字节的合法 base64: len=%d err=%v", len(want), err)
	}
	if err := authn.VerifyPassword(dummyPasswordHash, "whatever"); err == nil {
		t.Fatal("占位哈希不能通过任何口令")
	}
}

// ---------- 同步 ----------

func TestSyncPushSettlesEachItemInOrder(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "usr_a", "a@example.com")

	first := pushItems(t, f, token,
		`{"items":[{"type":"task","id":"task_1","base_version":0,"payload":{"title":"复习操作系统"}}]}`)
	if len(first.Results) != 1 || first.Results[0].Outcome != syncsvc.OutcomeAccepted {
		t.Fatalf("首次推送应被接受: %+v", first.Results)
	}
	if first.Results[0].Version != 1 {
		t.Fatalf("首个版本号应为 1，实得 %d", first.Results[0].Version)
	}

	// 一批三条：冲突 / 新增 / 非法。结果必须与入参同序，且逐条独立结算。
	batch := `{"items":[{"type":"task","id":"task_1","base_version":0,"payload":{"title":"本地改过的"}},{"type":"task","id":"task_2","base_version":0,"payload":{"title":"第二条"}},{"type":"","id":"","base_version":0}]}`
	got := pushItems(t, f, token, batch)
	if len(got.Results) != 3 {
		t.Fatalf("结果数必须与入参一致，实得 %d", len(got.Results))
	}
	if got.Results[0].Outcome != syncsvc.OutcomeConflict {
		t.Errorf("已有未删除记录时 base_version=0 必须冲突，实得 %q", got.Results[0].Outcome)
	}
	if got.Results[0].Type != "task" || got.Results[0].ID != "task_1" {
		t.Errorf("冲突项必须回显原 type/id: %+v", got.Results[0])
	}
	if got.Results[0].ServerVersion != 1 {
		t.Errorf("冲突项必须带服务端版本 1，实得 %d", got.Results[0].ServerVersion)
	}
	if got.Results[0].Reason == "" {
		t.Error("冲突项必须给出可读原因")
	}
	if got.Results[1].Outcome != syncsvc.OutcomeAccepted {
		t.Errorf("第二条应被接受，实得 %q", got.Results[1].Outcome)
	}
	if got.Results[2].Outcome != syncsvc.OutcomeRejected {
		t.Errorf("缺 type/id 的条目应被拒绝，实得 %q", got.Results[2].Outcome)
	}

	// 基准版本过旧同样冲突，并带回服务端最新版本（task_2 现在是版本 2）。
	stale := pushItems(t, f, token,
		`{"items":[{"type":"task","id":"task_2","base_version":99,"payload":{}}]}`)
	if stale.Results[0].Outcome != syncsvc.OutcomeConflict || stale.Results[0].ServerVersion != 2 {
		t.Fatalf("版本过旧应冲突并带服务端版本 2: %+v", stale.Results[0])
	}
}

func TestSyncPullAdvancesCursor(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "usr_a", "a@example.com")
	pushItems(t, f, token, `{"items":[{"type":"task","id":"task_1","base_version":0,"payload":{"title":"一"}},{"type":"note","id":"note_1","base_version":0,"payload":{"body":"二"}}]}`)

	rec := f.request(t, http.MethodGet, "/v1/sync/pull", token, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("拉取应返回 200，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var page syncPullResponse
	decodeBody(t, rec, &page)
	if len(page.Changes) != 2 || page.Cursor != "2" || page.HasMore {
		t.Fatalf("首屏应拿到 2 条且游标为 2: %+v", page)
	}

	// 游标推进后应没有新变更，且游标保持不变。
	rec = f.request(t, http.MethodGet, "/v1/sync/pull?cursor=2", token, "", "")
	var empty syncPullResponse
	decodeBody(t, rec, &empty)
	if len(empty.Changes) != 0 || empty.Cursor != "2" {
		t.Fatalf("游标处之后不应有变更: %+v", empty)
	}

	// 再写一条，从旧游标只能拉到它。
	pushItems(t, f, token, `{"items":[{"type":"task","id":"task_3","base_version":0,"payload":{"title":"三"}}]}`)
	rec = f.request(t, http.MethodGet, "/v1/sync/pull?cursor=2", token, "", "")
	var delta syncPullResponse
	decodeBody(t, rec, &delta)
	if len(delta.Changes) != 1 || delta.Changes[0].Version != 3 || delta.Cursor != "3" {
		t.Fatalf("增量拉取应只包含版本 3: %+v", delta)
	}

	// 坏游标必须报 400，绝不能静默当成空游标。
	rec = f.request(t, http.MethodGet, "/v1/sync/pull?cursor=not-a-number", token, "", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("坏游标应返回 400，实得 %d: %s", rec.Code, rec.Body.String())
	}
	rec = f.request(t, http.MethodGet, "/v1/sync/pull?limit=0", token, "", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("非法 limit 应返回 400，实得 %d: %s", rec.Code, rec.Body.String())
	}

	// limit 生效，并且如实告知还有更多。
	rec = f.request(t, http.MethodGet, "/v1/sync/pull?limit=1", token, "", "")
	var limited syncPullResponse
	decodeBody(t, rec, &limited)
	if len(limited.Changes) != 1 || !limited.HasMore || limited.Cursor != "1" {
		t.Fatalf("limit=1 应只返回一条并标记还有更多: %+v", limited)
	}
}

// ---------- 设备 ----------

func TestDeviceLifecycle(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "usr_a", "a@example.com")

	rec := f.postJSON(t, "/v1/devices", token, `{"platform":"ios","name":"iPhone 15","capabilities":{"notifications":true}}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("新设备应返回 201，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var created deviceResponse
	decodeBody(t, rec, &created)
	if !strings.HasPrefix(created.ID, "dev_") {
		t.Fatalf("缺少 ID 时服务端必须生成 dev_ 前缀的 ID，实得 %q", created.ID)
	}
	if !created.Capabilities["notifications"] {
		t.Errorf("设备能力应被保存: %+v", created)
	}

	// 同一 ID 再提交一次是更新，不是新建。
	rec = f.postJSON(t, "/v1/devices", token,
		`{"id":"`+created.ID+`" ,"platform":"ios","name":"改过名字"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("更新已有设备应返回 200，实得 %d: %s", rec.Code, rec.Body.String())
	}

	rec = f.request(t, http.MethodGet, "/v1/devices", token, "", "")
	var list deviceListResponse
	decodeBody(t, rec, &list)
	if len(list.Devices) != 1 || list.Devices[0].Name != "改过名字" {
		t.Fatalf("设备列表不正确: %+v", list.Devices)
	}

	// 非法 platform 必须是 422（与数据库 CHECK 约束的语义保持一致），而不是 500。
	rec = f.postJSON(t, "/v1/devices", token, `{"platform":"windows"}`)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("非法 platform 应返回 422，实得 %d: %s", rec.Code, rec.Body.String())
	}

	rec = f.request(t, http.MethodDelete, "/v1/devices/"+created.ID, token, "", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("删除设备应返回 204，实得 %d: %s", rec.Code, rec.Body.String())
	}
	rec = f.request(t, http.MethodDelete, "/v1/devices/"+created.ID, token, "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("重复删除应返回 404，实得 %d: %s", rec.Code, rec.Body.String())
	}
	rec = f.request(t, http.MethodGet, "/v1/devices", token, "", "")
	decodeBody(t, rec, &list)
	if len(list.Devices) != 0 {
		t.Fatalf("删除后设备列表应为空: %+v", list.Devices)
	}
}

// ---------- 媒体 ----------

func TestMediaUploadDownloadDelete(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "usr_a", "a@example.com")
	payload := []byte("daycue-media-payload")

	rec := f.uploadMedia(t, token, "capture", "cap_1", "image/png", payload)
	if rec.Code != http.StatusCreated {
		t.Fatalf("上传应返回 201，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var uploaded mediaResponse
	decodeBody(t, rec, &uploaded)
	if uploaded.ByteSize != int64(len(payload)) || uploaded.SHA256 == "" {
		t.Fatalf("媒体元数据不正确: %+v", uploaded)
	}
	if strings.Contains(rec.Body.String(), "storage_key") {
		t.Errorf("响应不得下发服务端存储键: %s", rec.Body.String())
	}

	rec = f.request(t, http.MethodGet, "/v1/media/"+uploaded.ID, token, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("下载应返回 200，实得 %d: %s", rec.Code, rec.Body.String())
	}
	if !bytes.Equal(rec.Body.Bytes(), payload) {
		t.Errorf("下载内容与上传不一致: %q", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("Content-Type 应为 image/png，实得 %q", ct)
	}

	// 白名单外的类型必须被拒绝。
	rec = f.uploadMedia(t, token, "capture", "cap_1", "application/x-msdownload", []byte("MZ"))
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("白名单外类型应返回 415，实得 %d: %s", rec.Code, rec.Body.String())
	}

	rec = f.request(t, http.MethodDelete, "/v1/media/"+uploaded.ID, token, "", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("删除媒体应返回 204，实得 %d: %s", rec.Code, rec.Body.String())
	}
	rec = f.request(t, http.MethodGet, "/v1/media/"+uploaded.ID, token, "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("删除后下载应返回 404，实得 %d: %s", rec.Code, rec.Body.String())
	}
}

// ---------- 导出 / 删号 ----------

func TestDeleteAccountPurgesEverything(t *testing.T) {
	f := newAccountFixture(t)
	token := f.seedUser(t, "usr_a", "a@example.com")

	pushItems(t, f, token, `{"items":[{"type":"task","id":"task_1","base_version":0,"payload":{"title":"复习操作系统"}}]}`)
	rec := f.postJSON(t, "/v1/devices", token, `{"platform":"ios","name":"iPhone"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("登记设备应成功，实得 %d: %s", rec.Code, rec.Body.String())
	}

	rec = f.request(t, http.MethodGet, "/v1/export", token, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("导出应返回 200，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var before exportResponse
	decodeBody(t, rec, &before)
	if len(before.Records) != 1 || len(before.Devices) != 1 || before.UserID != "usr_a" {
		t.Fatalf("删除前导出应包含数据: %+v", before)
	}
	if !strings.Contains(rec.Body.String(), "复习操作系统") {
		t.Errorf("导出必须包含实体内容: %s", rec.Body.String())
	}

	rec = f.request(t, http.MethodDelete, "/v1/account", token, "", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("删除账号应返回 204，实得 %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 0 {
		t.Errorf("204 不应带响应体: %q", rec.Body.String())
	}

	// 令牌本身没过期，但账号已经不存在：必须 401，否则删号后旧令牌还能继续写数据。
	rec = f.request(t, http.MethodGet, "/v1/export", token, "", "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("删号后旧令牌应返回 401，实得 %d: %s", rec.Code, rec.Body.String())
	}

	// 绕开鉴权直接问服务层，确认数据是真的被清空，而不是"只是令牌被拒"。
	bundle, err := f.svc.Export(context.Background(), "usr_a")
	if err != nil {
		t.Fatalf("服务层导出失败: %v", err)
	}
	if len(bundle.Records) != 0 || len(bundle.Memories) != 0 || len(bundle.Devices) != 0 {
		t.Fatalf("删号后导出必须为空，实得 records=%d memories=%d devices=%d",
			len(bundle.Records), len(bundle.Memories), len(bundle.Devices))
	}

	// 旧口令不能再登录（账号已软删）。
	rec = f.postJSON(t, "/v1/auth/login", "",
		`{"email":"a@example.com","password":"correct-horse-battery"}`)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("已删账号登录应返回 401，实得 %d: %s", rec.Code, rec.Body.String())
	}

	// 同一邮箱可以重新注册，且拿到的是全新账号。
	rec = f.postJSON(t, "/v1/auth/register", "",
		`{"email":"a@example.com","password":"longenough1"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("删号后同邮箱应能重新注册，实得 %d: %s", rec.Code, rec.Body.String())
	}
	var again authResponse
	decodeBody(t, rec, &again)
	if again.UserID == "usr_a" || again.UserID == "" {
		t.Fatalf("重新注册必须得到新账号，实得 %q", again.UserID)
	}
}

// ---------- 组装 ----------

func TestAccountHandlerRejectsMissingDeps(t *testing.T) {
	f := newAccountFixture(t)
	if _, err := NewAccountHandler(AccountDeps{}); err == nil {
		t.Error("缺少全部依赖时必须报错")
	}
	incomplete := f.deps
	incomplete.Media = nil
	if _, err := NewAccountHandler(incomplete); err == nil {
		t.Error("缺少 Media 时必须报错")
	}
	if _, err := NewRootHandler(nil, f.deps); err == nil {
		t.Error("Server 为 nil 时必须报错")
	}
}

// TestRootHandlerMountsAccountRoutes 验证与 api.go 的合并方式：
// 具体模式优先于 "/" 兜底，两组端点互不遮蔽。
func TestRootHandlerMountsAccountRoutes(t *testing.T) {
	f := newAccountFixture(t)
	root, err := NewRootHandler(New(testConfig()), f.deps)
	if err != nil {
		t.Fatalf("合并根处理器失败: %v", err)
	}

	if rec := requestWith(t, root, http.MethodGet, "/v1/health", "", "", ""); rec.Code != http.StatusOK {
		t.Errorf("健康检查应仍然可用，实得 %d", rec.Code)
	}
	if rec := requestWith(t, root, http.MethodGet, "/v1/devices", "", "", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("账号路由应优先于 \"/\" 兜底并返回 401，实得 %d", rec.Code)
	}
	if rec := requestWith(t, root, http.MethodGet, "/v1/nope", "", "", ""); rec.Code != http.StatusNotFound {
		t.Errorf("未知路径应返回 404，实得 %d", rec.Code)
	}
	// AI 端点仍在，且没有供应商时如实返回 503。
	rec := requestWith(t, root, http.MethodPost, "/v1/extractions", "", validBody(), "application/json")
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("AI 端点应仍然可用（无供应商 → 503），实得 %d: %s", rec.Code, rec.Body.String())
	}
}
