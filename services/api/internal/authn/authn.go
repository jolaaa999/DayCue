// Package authn 负责账号口令、令牌签发与请求鉴权。
//
// 设计取舍：
//   - 口令用 PBKDF2-HMAC-SHA256（标准库 crypto/pbkdf2），迭代次数写进哈希串本身，
//     这样以后调高迭代数不会让老用户无法登录。
//   - 访问令牌是 HMAC 签名的自包含令牌，不落库：服务端只存密钥。
//     代价是无法单独撤销某一枚令牌 —— 需要撤销时走"改口令/换密钥"，
//     这条限制写在文档里，不假装支持按令牌下线。
//   - 鉴权失败一律返回同一种错误，不区分"用户不存在"和"口令错误"，
//     避免把账号是否存在泄漏给攻击者。
package authn

import (
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// ErrInvalidCredentials 表示"账号或口令不对"。故意不区分两种情况。
var ErrInvalidCredentials = errors.New("authn: 账号或口令不正确")

// ErrInvalidToken 表示令牌不可用（格式错、签名错或已过期）。
var ErrInvalidToken = errors.New("authn: 令牌无效或已过期")

// ErrWeakSecret 表示签名密钥不合要求。宁可拒绝启动，也不要带着弱密钥上线。
var ErrWeakSecret = errors.New("authn: 签名密钥太短")

const (
	// defaultIterations 是新增口令的迭代次数。旧哈希串里的次数不会被改动。
	defaultIterations = 210_000
	saltBytes         = 16
	keyBytes          = 32
	minSecretBytes    = 32
)

// HashPassword 生成可入库的口令哈希串。
//
// 格式：pbkdf2$sha256$<iterations>$<salt-b64>$<hash-b64>
// 把算法与参数一起存下来，是为了让"以后换算法"不需要重置所有用户口令。
func HashPassword(password string) (string, error) {
	if strings.TrimSpace(password) == "" {
		return "", errors.New("authn: 口令不能为空")
	}
	salt := make([]byte, saltBytes)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("authn: 生成盐失败: %w", err)
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, defaultIterations, keyBytes)
	if err != nil {
		return "", fmt.Errorf("authn: 派生口令失败: %w", err)
	}
	return fmt.Sprintf("pbkdf2$sha256$%d$%s$%s",
		defaultIterations,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	), nil
}

// VerifyPassword 校验口令。任何解析失败都返回 ErrInvalidCredentials，
// 不把"哈希串损坏"这种内部状态暴露给调用方去区分。
func VerifyPassword(encoded, password string) error {
	parts := strings.Split(encoded, "$")
	if len(parts) != 5 || parts[0] != "pbkdf2" || parts[1] != "sha256" {
		return ErrInvalidCredentials
	}
	iterations, err := strconv.Atoi(parts[2])
	if err != nil || iterations <= 0 {
		return ErrInvalidCredentials
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil {
		return ErrInvalidCredentials
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return ErrInvalidCredentials
	}
	got, err := pbkdf2.Key(sha256.New, password, salt, iterations, len(want))
	if err != nil {
		return ErrInvalidCredentials
	}
	// 常量时间比较：避免通过响应时间猜出口令。
	if subtle.ConstantTimeCompare(got, want) != 1 {
		return ErrInvalidCredentials
	}
	return nil
}

// Issuer 签发与校验访问令牌。
type Issuer struct {
	secret []byte
	// now 可注入，便于测试过期逻辑而不必真的等待。
	now func() time.Time
}

// NewIssuer 构造签发器。密钥太短直接报错。
func NewIssuer(secret string, now func() time.Time) (*Issuer, error) {
	if len(secret) < minSecretBytes {
		return nil, fmt.Errorf("%w: 至少需要 %d 字节", ErrWeakSecret, minSecretBytes)
	}
	if now == nil {
		now = time.Now
	}
	return &Issuer{secret: []byte(secret), now: now}, nil
}

// Issue 签发一枚在 ttl 之后过期的令牌。
//
// 载荷是 "<userID>.<过期Unix秒>"，后面跟 HMAC 签名。
// 用点号分隔而不是 JSON，是为了让签名覆盖的字节序列完全确定。
func (i *Issuer) Issue(userID string, ttl time.Duration) (string, error) {
	if strings.TrimSpace(userID) == "" {
		return "", errors.New("authn: userID 不能为空")
	}
	if ttl <= 0 {
		return "", errors.New("authn: ttl 必须为正")
	}
	exp := i.now().Add(ttl).Unix()
	payload := userID + "." + strconv.FormatInt(exp, 10)
	sig := i.sign(payload)
	return base64.RawURLEncoding.EncodeToString([]byte(payload)) + "." + sig, nil
}

// Verify 校验令牌并返回其中的 userID。
func (i *Issuer) Verify(token string) (string, error) {
	raw, sig, ok := strings.Cut(token, ".")
	if !ok {
		return "", ErrInvalidToken
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return "", ErrInvalidToken
	}
	payload := string(payloadBytes)

	// 先验签再解析内容：未签名的字段一个都不能信。
	if subtle.ConstantTimeCompare([]byte(i.sign(payload)), []byte(sig)) != 1 {
		return "", ErrInvalidToken
	}

	userID, expStr, ok := strings.Cut(payload, ".")
	if !ok || userID == "" {
		return "", ErrInvalidToken
	}
	exp, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil {
		return "", ErrInvalidToken
	}
	if !i.now().Before(time.Unix(exp, 0)) {
		return "", ErrInvalidToken
	}
	return userID, nil
}

func (i *Issuer) sign(payload string) string {
	mac := hmac.New(sha256.New, i.secret)
	mac.Write([]byte(payload))
	return hex.EncodeToString(mac.Sum(nil))
}

// ParseBearer 从 Authorization 头里取出令牌。
func ParseBearer(header string) (string, bool) {
	const prefix = "Bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return "", false
	}
	token := strings.TrimSpace(header[len(prefix):])
	if token == "" {
		return "", false
	}
	return token, true
}
