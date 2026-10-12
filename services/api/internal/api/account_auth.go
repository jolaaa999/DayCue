package api

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/authn"
	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

const (
	minPasswordBytes = 8
	maxPasswordBytes = 1024
	maxEmailChars    = 320
	maxDeviceName    = 120
)

// dummyPasswordHash 与真实口令哈希同格式、同迭代次数，用来在"账号不存在"时也跑一次
// 口令派生。不这么做的话，登录接口的响应时间会直接暴露账号是否存在 —— 错误文案一致
// 只能挡住肉眼观察，挡不住计时攻击。
//
// 迭代次数与 authn.defaultIterations 保持一致；两边都改之前请先确认这一点。
// 用 strings.Repeat 拼盐和目标值，是为了保证 base64 长度一定合法（手写容易数错）。
var dummyPasswordHash = "pbkdf2$sha256$210000$" +
	strings.Repeat("A", 22) + "$" + strings.Repeat("A", 43)

// devicePayload 是客户端提交的设备信息。
// 注意这里没有 user_id 字段，而 httpx.DecodeJSON 拒绝未知字段：带 user_id 的请求会 400。
type devicePayload struct {
	ID           string          `json:"id"`
	Platform     string          `json:"platform"`
	Name         string          `json:"name"`
	Capabilities map[string]bool `json:"capabilities"`
	PushToken    string          `json:"push_token"`
}

type registerRequest struct {
	Email       string         `json:"email"`
	Password    string         `json:"password"`
	DisplayName string         `json:"display_name"`
	Device      *devicePayload `json:"device"`
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type authResponse struct {
	UserID      string          `json:"user_id"`
	Email       string          `json:"email"`
	DisplayName string          `json:"display_name,omitempty"`
	Token       string          `json:"token"`
	ExpiresAt   string          `json:"expires_at"`
	Device      *deviceResponse `json:"device,omitempty"`
}

// handleRegister 注册账号并顺带登记设备（如果请求里带了）。
func (h *AccountHandler) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		writeDecodeError(w, r, err)
		return
	}

	// 先做完整校验再落库：宁可让客户端把参数一次改对，也不要留下"账号建了但设备没登记"的半成品。
	email := strings.TrimSpace(req.Email)
	if !validEmail(email) {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, "邮箱格式不正确。")
		return
	}
	if err := validatePassword(req.Password); err != nil {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, err.Error())
		return
	}
	var device *devicePayload
	if req.Device != nil {
		normalized, err := normalizeDevicePayload(*req.Device)
		if err != nil {
			httpx.WriteError(w, r, httpx.CodeUnprocessable, err.Error())
			return
		}
		device = &normalized
	}

	ctx := r.Context()
	// 先查一次是为了给出明确提示；真正的唯一性由存储层保证，并发下也不会建出两个账号。
	if _, err := h.deps.Users.UserByEmail(ctx, email); err == nil {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, "该邮箱已被注册。")
		return
	} else if !errors.Is(err, store.ErrNotFound) {
		writeInternal(w, r, err)
		return
	}

	hash, err := authn.HashPassword(req.Password)
	if err != nil {
		writeInternal(w, r, err)
		return
	}
	now := h.now()
	user := store.User{
		ID:           newOpaqueID("usr_"),
		Email:        email,
		DisplayName:  strings.TrimSpace(req.DisplayName),
		PasswordHash: hash,
		CreatedAt:    now,
		UpdatedAt:    now,
	}
	if err := h.deps.Users.CreateUser(ctx, user); err != nil {
		// 并发注册同一邮箱时唯一索引会拦下第二次插入；这时要如实报"邮箱已注册"，而不是 500。
		if _, probeErr := h.deps.Users.UserByEmail(ctx, email); probeErr == nil {
			httpx.WriteError(w, r, httpx.CodeUnprocessable, "该邮箱已被注册。")
			return
		}
		writeInternal(w, r, err)
		return
	}

	var registered *deviceResponse
	if device != nil {
		resp, _, derr := h.applyDevice(ctx, user.ID, *device)
		if derr != nil {
			// 账号已经建好，设备登记失败不该让客户端以为注册失败；
			// 但也不能装作成功：如实记日志，响应里省略 device，客户端可再调一次设备接口。
			slog.Warn("注册时登记设备失败",
				"trace_id", httpx.RequestID(r), "reason", derr.Error())
		} else {
			registered = &resp
		}
	}

	token, expiresAt, err := h.issue(user.ID)
	if err != nil {
		writeInternal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, authResponse{
		UserID:      user.ID,
		Email:       user.Email,
		DisplayName: user.DisplayName,
		Token:       token,
		ExpiresAt:   expiresAt,
		Device:      registered,
	})
}

// handleLogin 签发令牌。
//
// 账号不存在与口令错误返回**同一个** 401 响应：否则这个接口就是账号枚举器。
func (h *AccountHandler) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		writeDecodeError(w, r, err)
		return
	}
	ctx := r.Context()

	user, err := h.deps.Users.UserByEmail(ctx, strings.TrimSpace(req.Email))
	switch {
	case errors.Is(err, store.ErrNotFound):
		// 账号不存在时也跑一次派生，抹平与"口令错误"的响应时间差。
		_ = authn.VerifyPassword(dummyPasswordHash, req.Password)
		writeInvalidCredentials(w, r)
		return
	case err != nil:
		writeInternal(w, r, err)
		return
	}
	if err := authn.VerifyPassword(user.PasswordHash, req.Password); err != nil {
		writeInvalidCredentials(w, r)
		return
	}

	token, expiresAt, err := h.issue(user.ID)
	if err != nil {
		writeInternal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, authResponse{
		UserID:      user.ID,
		Email:       user.Email,
		DisplayName: user.DisplayName,
		Token:       token,
		ExpiresAt:   expiresAt,
	})
}

// issue 签发令牌并给出到期时刻（响应里带到期时间，客户端据此提前续期）。
func (h *AccountHandler) issue(userID string) (string, string, error) {
	token, err := h.deps.Issuer.Issue(userID, h.deps.TokenTTL)
	if err != nil {
		return "", "", err
	}
	expiresAt := h.now().Add(h.deps.TokenTTL).UTC().Format(time.RFC3339)
	return token, expiresAt, nil
}

// writeInvalidCredentials 是登录唯一的失败响应。
func writeInvalidCredentials(w http.ResponseWriter, r *http.Request) {
	httpx.WriteError(w, r, httpx.CodeUnauthorized, "邮箱或口令不正确。")
}

// validEmail 只挡住明显不是邮箱的输入：真正的有效性要靠发信验证，
// 服务端在这里追求的是"格式合理 + 长度可控"。
func validEmail(email string) bool {
	if email == "" || len(email) > maxEmailChars {
		return false
	}
	if strings.ContainsAny(email, " \t\r\n") {
		return false
	}
	at := strings.Index(email, "@")
	if at <= 0 || at == len(email)-1 {
		return false
	}
	return !strings.Contains(email[at+1:], "@")
}

func validatePassword(pw string) error {
	if len(pw) < minPasswordBytes {
		return errors.New("口令至少需要 8 个字符。")
	}
	if len(pw) > maxPasswordBytes {
		return errors.New("口令过长。")
	}
	return nil
}

// normalizeDevicePayload 校验并补全设备字段。
//
// ID 缺省时由服务端生成：客户端从不需要自己造一个全局唯一 ID，也就没有机会
// 用别人的 ID 做覆盖写。
func normalizeDevicePayload(in devicePayload) (devicePayload, error) {
	out := in
	out.Platform = strings.TrimSpace(in.Platform)
	if out.Platform == "" {
		out.Platform = "unknown"
	}
	if !validPlatform(out.Platform) {
		return devicePayload{}, errors.New("platform 只能是 ios、android、macos 或 unknown。")
	}
	out.ID = strings.TrimSpace(in.ID)
	if out.ID == "" {
		out.ID = newOpaqueID("dev_")
	} else if !validOpaqueID(out.ID) {
		return devicePayload{}, errors.New("设备 ID 格式不正确。")
	}
	out.Name = strings.TrimSpace(in.Name)
	if len(out.Name) > maxDeviceName {
		return devicePayload{}, errors.New("设备名称过长。")
	}
	if out.Capabilities == nil {
		out.Capabilities = map[string]bool{}
	}
	return out, nil
}

// validPlatform 与 0001_init.sql 中 device.platform 的 CHECK 约束保持一致：
// 在这里挡住非法值，才能给出可读的 422，而不是让数据库抛约束错误。
func validPlatform(p string) bool {
	switch p {
	case "ios", "android", "macos", "unknown":
		return true
	default:
		return false
	}
}
