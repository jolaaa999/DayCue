package authn

import (
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func fixedClock(t time.Time) func() time.Time { return func() time.Time { return t } }

var base = time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)

func TestPasswordRoundTrip(t *testing.T) {
	h, err := HashPassword("正确的马电池订书钉")
	if err != nil {
		t.Fatalf("生成哈希失败: %v", err)
	}
	if err := VerifyPassword(h, "正确的马电池订书钉"); err != nil {
		t.Fatalf("正确口令应当通过: %v", err)
	}
	if err := VerifyPassword(h, "错误口令"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("错误口令应返回 ErrInvalidCredentials，实际 %v", err)
	}
}

func TestSamePasswordProducesDifferentHash(t *testing.T) {
	h1, _ := HashPassword("same")
	h2, _ := HashPassword("same")
	// 每次都要新盐；否则相同口令会产生相同哈希，等于泄漏"这两个用户口令一样"。
	if h1 == h2 {
		t.Fatal("相同口令必须产生不同哈希（盐应当随机）")
	}
}

func TestHashEmbedsAlgorithmAndIterations(t *testing.T) {
	h, _ := HashPassword("x")
	parts := strings.Split(h, "$")
	if len(parts) != 5 || parts[0] != "pbkdf2" || parts[1] != "sha256" {
		t.Fatalf("哈希串格式不对: %s", h)
	}
	// 迭代次数必须写进串里，否则以后调参会让老用户无法登录。
	if parts[2] == "" {
		t.Fatal("哈希串必须包含迭代次数")
	}
}

func TestVerifyRejectsMalformedHashWithoutLeaking(t *testing.T) {
	for _, bad := range []string{"", "plain", "pbkdf2$sha256$notanumber$a$b", "bcrypt$x$1$a$b", "pbkdf2$sha256$1000$!!!$!!!"} {
		if err := VerifyPassword(bad, "x"); !errors.Is(err, ErrInvalidCredentials) {
			t.Errorf("损坏的哈希串 %q 应返回 ErrInvalidCredentials，实际 %v", bad, err)
		}
	}
}

func TestIssuerRejectsShortSecret(t *testing.T) {
	if _, err := NewIssuer("too-short", nil); !errors.Is(err, ErrWeakSecret) {
		t.Fatalf("短密钥应被拒绝，实际 %v", err)
	}
}

func TestTokenRoundTrip(t *testing.T) {
	iss, err := NewIssuer(strings.Repeat("k", 32), fixedClock(base))
	if err != nil {
		t.Fatalf("构造签发器失败: %v", err)
	}
	tok, err := iss.Issue("user-1", time.Hour)
	if err != nil {
		t.Fatalf("签发失败: %v", err)
	}
	uid, err := iss.Verify(tok)
	if err != nil {
		t.Fatalf("校验失败: %v", err)
	}
	if uid != "user-1" {
		t.Fatalf("userID 应为 user-1，实际 %s", uid)
	}
}

func TestTokenExpires(t *testing.T) {
	now := base
	iss, _ := NewIssuer(strings.Repeat("k", 32), func() time.Time { return now })
	tok, _ := iss.Issue("user-1", time.Minute)

	now = base.Add(59 * time.Second)
	if _, err := iss.Verify(tok); err != nil {
		t.Fatalf("未过期时不应失败: %v", err)
	}

	now = base.Add(2 * time.Minute)
	if _, err := iss.Verify(tok); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("过期后应返回 ErrInvalidToken，实际 %v", err)
	}
}

func TestTamperedTokenIsRejected(t *testing.T) {
	iss, _ := NewIssuer(strings.Repeat("k", 32), fixedClock(base))
	tok, _ := iss.Issue("user-1", time.Hour)

	// 直接把 userID 换掉，签名必须对不上。
	raw, sig, _ := strings.Cut(tok, ".")
	forged := []byte("user-2.9999999999")
	forgedTok := encodeRaw(forged) + "." + sig

	if _, err := iss.Verify(forgedTok); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("篡改载荷必须被拒绝，实际 %v", err)
	}
	if _, err := iss.Verify(raw + "." + strings.Repeat("0", len(sig))); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("篡改签名必须被拒绝")
	}
}

func TestTokenSignedByAnotherSecretIsRejected(t *testing.T) {
	a, _ := NewIssuer(strings.Repeat("a", 32), fixedClock(base))
	b, _ := NewIssuer(strings.Repeat("b", 32), fixedClock(base))
	tok, _ := a.Issue("user-1", time.Hour)
	// 换密钥后老令牌必须失效，这是"轮换密钥"能真正踢人的前提。
	if _, err := b.Verify(tok); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("别的密钥签的令牌必须被拒绝，实际 %v", err)
	}
}

func TestIssueRejectsEmptyUserAndBadTTL(t *testing.T) {
	iss, _ := NewIssuer(strings.Repeat("k", 32), fixedClock(base))
	if _, err := iss.Issue("", time.Hour); err == nil {
		t.Fatal("空 userID 应被拒绝")
	}
	if _, err := iss.Issue("u", 0); err == nil {
		t.Fatal("零 ttl 应被拒绝")
	}
	if _, err := iss.Issue("u", -time.Minute); err == nil {
		t.Fatal("负 ttl 应被拒绝")
	}
}

func TestParseBearer(t *testing.T) {
	cases := []struct {
		in     string
		want   string
		wantOK bool
	}{
		{"Bearer abc", "abc", true},
		{"bearer abc", "abc", true},
		{"Bearer  abc  ", "abc", true},
		{"Basic abc", "", false},
		{"Bearer ", "", false},
		{"", "", false},
		{"abc", "", false},
	}
	for _, c := range cases {
		got, ok := ParseBearer(c.in)
		if ok != c.wantOK || got != c.want {
			t.Errorf("ParseBearer(%q) = (%q,%v)，期望 (%q,%v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

func encodeRaw(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// 回归：userID 里含点时必须仍能正确校验。
// 曾经载荷是 "<userID>.<exp>"，按第一个点切分会把 "com.1791..." 当成过期时间，
// 导致由邮箱派生的 userID（如 "u_a_example.com"）签发的令牌永远无效。
func TestTokenRoundTripsForUserIDContainingDots(t *testing.T) {
	iss, _ := NewIssuer(strings.Repeat("k", 32), fixedClock(base))
	for _, uid := range []string{"u_a_example.com", "a.b.c.d", "u_1.2.3"} {
		tok, err := iss.Issue(uid, time.Hour)
		if err != nil {
			t.Fatalf("签发 %q 失败: %v", uid, err)
		}
		got, err := iss.Verify(tok)
		if err != nil {
			t.Fatalf("含点 userID %q 应能校验通过，实际 %v", uid, err)
		}
		if got != uid {
			t.Fatalf("应还原为 %q，实际 %q", uid, got)
		}
	}
}
