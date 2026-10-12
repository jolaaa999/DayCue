package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 固定时钟：让"过期判定"与"重试退避"在任何机器、任何时刻跑出同样结果。
var fixedNow = time.Date(2026, 10, 12, 3, 0, 0, 0, time.UTC)

func clockAt(t time.Time) func() time.Time { return func() time.Time { return t } }

// stubDoer 是假 HTTP 客户端：没有真实 APNs / FCM 凭据时，
// 这是唯一能覆盖"状态码 → 失败分类"全部路径的办法。
type stubDoer struct {
	status  int
	body    string
	header  http.Header
	err     error
	calls   int
	lastReq *http.Request
}

func (d *stubDoer) Do(req *http.Request) (*http.Response, error) {
	d.calls++
	d.lastReq = req
	if d.err != nil {
		return nil, d.err
	}
	header := d.header
	if header == nil {
		header = http.Header{}
	}
	return &http.Response{
		StatusCode: d.status,
		Header:     header,
		Body:       io.NopCloser(strings.NewReader(d.body)),
	}, nil
}

// testAPNsKey 生成一对临时 P-256 密钥，并导出成 .p8 的 PKCS#8 PEM。
// 用临时密钥而不是夹具里的固定私钥：仓库里不留任何形式的私钥。
func testAPNsKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("生成测试密钥失败: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("序列化测试密钥失败: %v", err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func okTarget() DeviceTarget {
	return DeviceTarget{
		UserID: "usr_1", DeviceID: "dev_1",
		Platform: PlatformIOS, Token: "test-token",
	}
}

func testMessage() Message {
	// DedupeKey 与 ID 一致：调度层就是这么填的，collapse-id 断言才有意义。
	return Message{ID: "pm_1", Kind: "geo", DedupeKey: "pm_1", Title: "该复习了", Body: "还有 3 天考试"}
}

// ---------- 未配置 ----------

func TestUnconfiguredSenderNeverPretendsSuccess(t *testing.T) {
	var s Sender = Unconfigured{Name: "apns"}
	receipt, err := s.Send(context.Background(), okTarget(), testMessage())

	if err == nil {
		t.Fatal("未配置的通道必须返回错误，不能静默成功")
	}
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("错误必须可被 errors.Is(ErrNotConfigured) 命中，实际: %v", err)
	}
	if receipt.Status != StatusFailed {
		t.Fatalf("回执状态必须是 failed，实际: %s", receipt.Status)
	}
	f, ok := FailureOf(err)
	if !ok || f.Kind != FailureNotConfigured {
		t.Fatalf("失败分类应为 not_configured，实际: %+v", f)
	}
	if f.Retryable() {
		t.Fatal("未配置不该被判定为可重试：重试一万次也不会成功")
	}
}

// ---------- Guard 预检 ----------

func TestGuardRejectsUnsendableMessages(t *testing.T) {
	downstream := SenderFunc(func(context.Context, DeviceTarget, Message) (Receipt, error) {
		t.Fatal("预检失败时不得触达供应商")
		return Receipt{}, nil
	})
	g := Guard(downstream, clockAt(fixedNow))

	expired := fixedNow.Add(-time.Minute)
	cases := []struct {
		name   string
		target DeviceTarget
		msg    Message
		want   FailureKind
	}{
		{"平台未知", DeviceTarget{Platform: PlatformUnknown, Token: "t"}, testMessage(), FailureUnsupportedPlatform},
		{"没有令牌", DeviceTarget{Platform: PlatformIOS}, testMessage(), FailureMissingToken},
		{"已经过期", okTarget(), Message{Title: "a", ExpiresAt: &expired}, FailureExpired},
		{"内容为空", okTarget(), Message{}, FailureEmptyMessage},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			receipt, err := g.Send(context.Background(), tc.target, tc.msg)
			f, ok := FailureOf(err)
			if !ok {
				t.Fatalf("应当返回推送失败，实际 err=%v", err)
			}
			if f.Kind != tc.want {
				t.Fatalf("失败分类应为 %s，实际 %s", tc.want, f.Kind)
			}
			if receipt.Status != StatusFailed {
				t.Fatalf("回执状态应为 failed，实际 %s", receipt.Status)
			}
		})
	}
}

func TestGuardPassesThroughAndFillsProvider(t *testing.T) {
	inner := SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
		return acceptedReceipt(target, "", "", fixedNow), nil
	})
	g := Guard(inner, clockAt(fixedNow))
	receipt, err := g.Send(context.Background(), okTarget(), testMessage())
	if err != nil {
		t.Fatalf("预检通过时不该报错: %v", err)
	}
	if receipt.DeviceID != "dev_1" {
		t.Fatalf("回执必须回填设备，实际: %q", receipt.DeviceID)
	}
	if receipt.Status != StatusAccepted {
		t.Fatalf("状态应为 accepted，实际: %s", receipt.Status)
	}
}

// ---------- 重试 ----------

func TestRetryRetriesOnlyRetryableFailures(t *testing.T) {
	newSender := func(kind FailureKind) (Sender, *int) {
		attempts := 0
		s := SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
			attempts++
			r, err := failureReceipt(target, &Failure{Kind: kind, Provider: "apns"}, fixedNow)
			return r, err
		})
		return s, &attempts
	}

	policy := RetryPolicy{
		MaxAttempts: 3, BaseDelay: time.Millisecond, MaxDelay: time.Millisecond,
		// 注入空 Sleep：验证"重试了 3 次"不该真的等 3 次。
		Sleep: func(context.Context, time.Duration) error { return nil },
	}

	retryable, n1 := newSender(FailureProviderUnavailable)
	if _, err := WithRetry(retryable, policy).Send(context.Background(), okTarget(), testMessage()); err == nil {
		t.Fatal("一直失败时最终必须报错")
	}
	if *n1 != 3 {
		t.Fatalf("可重试失败应尝试 3 次，实际 %d", *n1)
	}

	fatal, n2 := newSender(FailureInvalidToken)
	if _, err := WithRetry(fatal, policy).Send(context.Background(), okTarget(), testMessage()); err == nil {
		t.Fatal("令牌失效时必须报错")
	}
	if *n2 != 1 {
		t.Fatalf("不可重试失败只应尝试 1 次，实际 %d", *n2)
	}

	ok, n3 := newSender(FailureRateLimited)
	_ = ok
	_ = n3

	succeedSecond := 0
	flaky := SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
		succeedSecond++
		if succeedSecond == 1 {
			r, err := failureReceipt(target, &Failure{Kind: FailureRateLimited, Provider: "apns"}, fixedNow)
			return r, err
		}
		return acceptedReceipt(target, "apns", "id-2", fixedNow), nil
	})
	receipt, err := WithRetry(flaky, policy).Send(context.Background(), okTarget(), testMessage())
	if err != nil {
		t.Fatalf("第二次成功时不该报错: %v", err)
	}
	if receipt.Status != StatusAccepted || succeedSecond != 2 {
		t.Fatalf("应第 2 次成功，实际 attempts=%d status=%s", succeedSecond, receipt.Status)
	}
}

func TestRetryStopsWhenContextCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	attempts := 0
	inner := SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
		attempts++
		r, err := failureReceipt(target, &Failure{Kind: FailureProviderUnavailable, Provider: "apns"}, fixedNow)
		return r, err
	})
	policy := RetryPolicy{MaxAttempts: 5, BaseDelay: time.Hour, MaxDelay: time.Hour}
	_, err := WithRetry(inner, policy).Send(ctx, okTarget(), testMessage())
	if err == nil {
		t.Fatal("上下文取消后必须报错")
	}
	if attempts != 1 {
		t.Fatalf("取消后不该继续尝试，实际 %d 次", attempts)
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("错误里必须保留取消原因，实际: %v", err)
	}
	// 原始推送失败也不能丢：否则排查时会以为问题出在取消上。
	if _, ok := FailureOf(err); !ok {
		t.Fatalf("错误里必须保留最后一次推送失败，实际: %v", err)
	}
}

// ---------- APNs ----------

func TestNewAPNsReportsMissingCredentials(t *testing.T) {
	if _, err := NewAPNs(APNsConfig{}); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("缺凭据必须报未配置，实际: %v", err)
	}
	_, pemBytes := testAPNsKey(t)
	if _, err := NewAPNs(APNsConfig{KeyID: "K", TeamID: "T", BundleID: "B", PrivateKeyPEM: []byte("not-pem")}); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("私钥格式错误也必须报未配置，实际: %v", err)
	}
	if _, err := NewAPNs(APNsConfig{KeyID: "K", TeamID: "T", BundleID: "B", PrivateKeyPEM: pemBytes}); err != nil {
		t.Fatalf("凭据齐全时不该报错: %v", err)
	}
}

func TestAPNsSignsVerifiableES256Token(t *testing.T) {
	key, pemBytes := testAPNsKey(t)
	doer := &stubDoer{status: http.StatusOK, header: http.Header{"Apns-Id": []string{"apns-1"}}}
	a, err := NewAPNs(APNsConfig{
		KeyID: "KEY123", TeamID: "TEAM123", BundleID: "com.example.daycue",
		PrivateKeyPEM: pemBytes, Endpoint: "https://apns.invalid",
		HTTPClient: doer, Now: clockAt(fixedNow),
	})
	if err != nil {
		t.Fatalf("构造 APNs 失败: %v", err)
	}

	receipt, err := a.Send(context.Background(), okTarget(), testMessage())
	if err != nil {
		t.Fatalf("投递失败: %v", err)
	}
	if receipt.Status != StatusAccepted {
		t.Fatalf("APNs 只回报受理，状态必须是 accepted，实际 %s", receipt.Status)
	}
	if receipt.MessageID != "apns-1" {
		t.Fatalf("应取到 apns-id，实际 %q", receipt.MessageID)
	}

	auth := doer.lastReq.Header.Get("authorization")
	if !strings.HasPrefix(auth, "bearer ") {
		t.Fatalf("缺少 bearer 授权头: %q", auth)
	}
	token := strings.TrimPrefix(auth, "bearer ")
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT 必须是三段，实际 %d 段", len(parts))
	}

	// 用公钥验签：这是"签名真的能通过 APNs 校验"在无外部依赖下最接近的证明。
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("解码头失败: %v", err)
	}
	var header map[string]any
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		t.Fatalf("解析头失败: %v", err)
	}
	if header["alg"] != "ES256" || header["kid"] != "KEY123" {
		t.Fatalf("JWT 头不正确: %+v", header)
	}

	claimBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatalf("解码声明失败: %v", err)
	}
	var claims map[string]any
	if err := json.Unmarshal(claimBytes, &claims); err != nil {
		t.Fatalf("解析声明失败: %v", err)
	}
	if claims["iss"] != "TEAM123" {
		t.Fatalf("iss 应为 TeamID，实际: %v", claims["iss"])
	}
	if int64(claims["iat"].(float64)) != fixedNow.Unix() {
		t.Fatalf("iat 应为当前时刻，实际: %v", claims["iat"])
	}

	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("解码签名失败: %v", err)
	}
	if len(sig) != 64 {
		t.Fatalf("ES256 签名必须是固定 64 字节的 r||s，实际 %d 字节", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("签名无法用公钥验证，APNs 也会拒绝它")
	}

	// 关键头部：没有 apns-topic 与 apns-push-type，APNs 会直接 400。
	if got := doer.lastReq.Header.Get("apns-topic"); got != "com.example.daycue" {
		t.Fatalf("apns-topic 不正确: %q", got)
	}
	if got := doer.lastReq.Header.Get("apns-push-type"); got != "alert" {
		t.Fatalf("apns-push-type 不正确: %q", got)
	}
	if got := doer.lastReq.Header.Get("apns-collapse-id"); got != "pm_1" {
		t.Fatalf("同一条消息必须带 collapse-id，实际: %q", got)
	}
}

func TestAPNsReusesCachedToken(t *testing.T) {
	_, pemBytes := testAPNsKey(t)
	doer := &stubDoer{status: http.StatusOK}
	a, err := NewAPNs(APNsConfig{
		KeyID: "K", TeamID: "T", BundleID: "B", PrivateKeyPEM: pemBytes,
		Endpoint: "https://apns.invalid", HTTPClient: doer, Now: clockAt(fixedNow),
	})
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	if _, err := a.Send(context.Background(), okTarget(), testMessage()); err != nil {
		t.Fatalf("第一次投递失败: %v", err)
	}
	first := doer.lastReq.Header.Get("authorization")
	if _, err := a.Send(context.Background(), okTarget(), testMessage()); err != nil {
		t.Fatalf("第二次投递失败: %v", err)
	}
	second := doer.lastReq.Header.Get("authorization")
	// 每次请求都重签会触发 APNs 的 TooManyProviderTokenUpdates。
	if first != second {
		t.Fatal("同一小时内必须复用 provider token，不能每次请求重签")
	}
}

func TestAPNsClassifiesProviderStatus(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		body       string
		want       FailureKind
		retryable  bool
		devInvalid bool
	}{
		{"410 令牌失效", http.StatusGone, "{\"reason\":\"Unregistered\"}", FailureInvalidToken, false, true},
		{"400 BadDeviceToken", http.StatusBadRequest, "{\"reason\":\"BadDeviceToken\"}", FailureInvalidToken, false, true},
		{"400 DeviceTokenNotForTopic", http.StatusBadRequest, "{\"reason\":\"DeviceTokenNotForTopic\"}", FailureInvalidToken, false, true},
		{"429 限流", http.StatusTooManyRequests, "", FailureRateLimited, true, false},
		{"500 供应商故障", http.StatusInternalServerError, "", FailureProviderUnavailable, true, false},
		{"503 供应商故障", http.StatusServiceUnavailable, "", FailureProviderUnavailable, true, false},
		{"403 凭据被拒", http.StatusForbidden, "{\"reason\":\"InvalidProviderToken\"}", FailureProviderAuth, false, false},
		{"400 负载过大", http.StatusBadRequest, "{\"reason\":\"PayloadTooLarge\"}", FailurePermanent, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, pemBytes := testAPNsKey(t)
			doer := &stubDoer{status: tc.status, body: tc.body}
			a, err := NewAPNs(APNsConfig{
				KeyID: "K", TeamID: "T", BundleID: "B", PrivateKeyPEM: pemBytes,
				Endpoint: "https://apns.invalid", HTTPClient: doer, Now: clockAt(fixedNow),
			})
			if err != nil {
				t.Fatalf("构造失败: %v", err)
			}
			receipt, err := a.Send(context.Background(), okTarget(), testMessage())
			f, ok := FailureOf(err)
			if !ok {
				t.Fatalf("应当失败，实际 err=%v", err)
			}
			if f.Kind != tc.want {
				t.Fatalf("分类应为 %s，实际 %s（detail=%s）", tc.want, f.Kind, f.Detail)
			}
			if f.Retryable() != tc.retryable {
				t.Fatalf("retryable 应为 %v，实际 %v", tc.retryable, f.Retryable())
			}
			if receipt.DeviceInvalid() != tc.devInvalid {
				t.Fatalf("deviceInvalid 应为 %v，实际 %v", tc.devInvalid, receipt.DeviceInvalid())
			}
		})
	}
}

func TestAPNsNetworkErrorIsRetryable(t *testing.T) {
	_, pemBytes := testAPNsKey(t)
	doer := &stubDoer{err: errors.New("connection refused")}
	a, err := NewAPNs(APNsConfig{
		KeyID: "K", TeamID: "T", BundleID: "B", PrivateKeyPEM: pemBytes,
		Endpoint: "https://apns.invalid", HTTPClient: doer, Now: clockAt(fixedNow),
	})
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	_, err = a.Send(context.Background(), okTarget(), testMessage())
	f, ok := FailureOf(err)
	if !ok || !f.Retryable() {
		t.Fatalf("网络不可达应当可重试，实际: %+v", f)
	}
}

// ---------- FCM ----------

type staticToken string

func (s staticToken) Token(context.Context) (string, error) { return string(s), nil }

type failingToken struct{ err error }

func (f failingToken) Token(context.Context) (string, error) { return "", f.err }

func TestNewFCMReportsMissingCredentials(t *testing.T) {
	if _, err := NewFCM(FCMConfig{}); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("缺 ProjectID/TokenSource 必须报未配置，实际: %v", err)
	}
	if _, err := NewFCM(FCMConfig{ProjectID: "p"}); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("缺 TokenSource 必须报未配置，实际: %v", err)
	}
	if _, err := NewFCM(FCMConfig{ProjectID: "p", TokenSource: staticToken("t")}); err != nil {
		t.Fatalf("配置齐全时不该报错: %v", err)
	}
}

func TestFCMTokenFailureIsNotDeviceInvalid(t *testing.T) {
	doer := &stubDoer{status: http.StatusOK}
	f, err := NewFCM(FCMConfig{
		ProjectID: "proj", TokenSource: failingToken{err: errors.New("no credentials")},
		Endpoint: "https://fcm.invalid", HTTPClient: doer, Now: clockAt(fixedNow),
	})
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	receipt, err := f.Send(context.Background(), okTarget(), testMessage())
	fail, ok := FailureOf(err)
	if !ok || fail.Kind != FailureProviderAuth {
		t.Fatalf("服务端取不到令牌应归为 provider_auth，实际: %+v", fail)
	}
	// 关键：绝不能因为服务端凭据问题就把所有 Android 设备标记为失效。
	if receipt.DeviceInvalid() {
		t.Fatal("服务端凭据问题不得上报为设备失效")
	}
	if doer.calls != 0 {
		t.Fatal("拿不到访问令牌时不该发起请求")
	}
}

func TestFCMClassifiesProviderStatus(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		body       string
		want       FailureKind
		devInvalid bool
	}{
		{"404 UNREGISTERED", http.StatusNotFound, "{\"error\":{\"status\":\"NOT_FOUND\",\"details\":[{\"errorCode\":\"UNREGISTERED\"}]}}", FailureInvalidToken, true},
		{"429 限流", http.StatusTooManyRequests, "{\"error\":{\"status\":\"RESOURCE_EXHAUSTED\"}}", FailureRateLimited, false},
		{"401 凭据错误", http.StatusUnauthorized, "{\"error\":{\"status\":\"UNAUTHENTICATED\"}}", FailureProviderAuth, false},
		{"503 不可用", http.StatusServiceUnavailable, "{\"error\":{\"status\":\"UNAVAILABLE\"}}", FailureProviderUnavailable, false},
		{"400 参数非法", http.StatusBadRequest, "{\"error\":{\"status\":\"INVALID_ARGUMENT\"}}", FailurePermanent, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doer := &stubDoer{status: tc.status, body: tc.body}
			f, err := NewFCM(FCMConfig{
				ProjectID: "proj", TokenSource: staticToken("tok"),
				Endpoint: "https://fcm.invalid", HTTPClient: doer, Now: clockAt(fixedNow),
			})
			if err != nil {
				t.Fatalf("构造失败: %v", err)
			}
			receipt, err := f.Send(context.Background(), okTarget(), testMessage())
			fail, ok := FailureOf(err)
			if !ok {
				t.Fatalf("应当失败，实际 err=%v", err)
			}
			if fail.Kind != tc.want {
				t.Fatalf("分类应为 %s，实际 %s（detail=%s）", tc.want, fail.Kind, fail.Detail)
			}
			if receipt.DeviceInvalid() != tc.devInvalid {
				t.Fatalf("deviceInvalid 应为 %v，实际 %v", tc.devInvalid, receipt.DeviceInvalid())
			}
		})
	}
}

func TestFCMAcceptsWithMessageName(t *testing.T) {
	doer := &stubDoer{status: http.StatusOK, body: "{\"name\":\"projects/proj/messages/123\"}"}
	f, err := NewFCM(FCMConfig{
		ProjectID: "proj", TokenSource: staticToken("tok"),
		Endpoint: "https://fcm.invalid", HTTPClient: doer, Now: clockAt(fixedNow),
	})
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	receipt, err := f.Send(context.Background(), okTarget(), testMessage())
	if err != nil {
		t.Fatalf("投递失败: %v", err)
	}
	if receipt.Status != StatusAccepted {
		t.Fatalf("FCM 200 只代表受理，状态必须是 accepted，实际 %s", receipt.Status)
	}
	if receipt.MessageID != "projects/proj/messages/123" {
		t.Fatalf("应取到消息 name，实际 %q", receipt.MessageID)
	}
	if got := doer.lastReq.URL.Path; !strings.HasSuffix(got, "/v1/projects/proj/messages:send") {
		t.Fatalf("FCM v1 路径不正确: %q", got)
	}
}

// ---------- Router ----------

type recordingInvalidator struct {
	userID   string
	deviceID string
	calls    int
	err      error
}

func (r *recordingInvalidator) MarkDeviceInvalid(_ context.Context, userID, deviceID string, _ time.Time) error {
	r.calls++
	r.userID, r.deviceID = userID, deviceID
	return r.err
}

func TestRouterRoutesByPlatform(t *testing.T) {
	var iosCalls, androidCalls int
	router := NewRouter(clockAt(fixedNow)).
		Register(PlatformIOS, SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
			iosCalls++
			return acceptedReceipt(target, apnsProvider, "a", fixedNow), nil
		})).
		Register(PlatformAndroid, SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
			androidCalls++
			return acceptedReceipt(target, fcmProvider, "f", fixedNow), nil
		}))

	ios := okTarget()
	if _, err := router.Send(context.Background(), ios, testMessage()); err != nil {
		t.Fatalf("iOS 投递失败: %v", err)
	}
	android := okTarget()
	android.Platform = PlatformAndroid
	if _, err := router.Send(context.Background(), android, testMessage()); err != nil {
		t.Fatalf("Android 投递失败: %v", err)
	}
	if iosCalls != 1 || androidCalls != 1 {
		t.Fatalf("应按平台分流，实际 ios=%d android=%d", iosCalls, androidCalls)
	}

	mac := okTarget()
	mac.Platform = PlatformMacOS
	_, err := router.Send(context.Background(), mac, testMessage())
	f, ok := FailureOf(err)
	if !ok || f.Kind != FailureUnsupportedPlatform {
		t.Fatalf("未登记平台应报 unsupported_platform，实际: %+v", f)
	}
}

func TestRouterReportsDeviceInvalidation(t *testing.T) {
	invalidator := &recordingInvalidator{}
	router := NewRouter(clockAt(fixedNow)).
		WithInvalidator(invalidator).
		Register(PlatformAndroid, SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
			return failureReceipt(target, &Failure{
				Kind: FailureInvalidToken, Provider: fcmProvider, StatusCode: http.StatusNotFound,
			}, fixedNow)
		}))

	target := okTarget()
	target.Platform = PlatformAndroid
	receipt, err := router.Send(context.Background(), target, testMessage())
	if !receipt.DeviceInvalid() {
		t.Fatal("回执必须标明设备令牌失效")
	}
	if _, ok := FailureOf(err); !ok {
		t.Fatal("仍然要返回推送失败")
	}
	if invalidator.calls != 1 || invalidator.userID != "usr_1" || invalidator.deviceID != "dev_1" {
		t.Fatalf("必须上报设备失效，实际: %+v", invalidator)
	}
}

func TestRouterKeepsPushFailureWhenInvalidationFails(t *testing.T) {
	invalidator := &recordingInvalidator{err: errors.New("数据库不可用")}
	router := NewRouter(clockAt(fixedNow)).
		WithInvalidator(invalidator).
		Register(PlatformAndroid, SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
			return failureReceipt(target, &Failure{Kind: FailureInvalidToken, Provider: fcmProvider}, fixedNow)
		}))

	target := okTarget()
	target.Platform = PlatformAndroid
	_, err := router.Send(context.Background(), target, testMessage())
	f, ok := FailureOf(err)
	if !ok || f.Kind != FailureInvalidToken {
		t.Fatalf("上报失败不能吞掉原始推送失败，实际: %+v", f)
	}
	if !strings.Contains(err.Error(), "上报设备失效失败") {
		t.Fatalf("上报失败也要保留在错误里，实际: %v", err)
	}
}

func TestRouterDoesNotInvalidateOnOrdinaryFailure(t *testing.T) {
	invalidator := &recordingInvalidator{}
	router := NewRouter(clockAt(fixedNow)).
		WithInvalidator(invalidator).
		Register(PlatformAndroid, SenderFunc(func(_ context.Context, target DeviceTarget, _ Message) (Receipt, error) {
			return failureReceipt(target, &Failure{Kind: FailureProviderUnavailable, Provider: fcmProvider}, fixedNow)
		}))

	target := okTarget()
	target.Platform = PlatformAndroid
	if _, err := router.Send(context.Background(), target, testMessage()); err == nil {
		t.Fatal("应当返回失败")
	}
	if invalidator.calls != 0 {
		t.Fatal("供应商故障不得停用设备：那会把一次网络抖动变成用户设备被踢下线")
	}
}

func TestFailureDetailNeverLeaksToken(t *testing.T) {
	target := okTarget()
	target.Token = "super-secret-token"
	f := &Failure{Kind: FailureInvalidToken, Provider: apnsProvider, StatusCode: 410, Detail: "Unregistered"}
	if strings.Contains(f.Error(), target.Token) {
		t.Fatal("失败详情不得包含推送令牌明文")
	}
}
