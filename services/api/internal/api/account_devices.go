package api

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// errTooManyDevices 表示设备数量超限，属于可读的客户端错误而不是服务端故障。
var errTooManyDevices = errors.New("设备数量已达上限。")

type deviceResponse struct {
	ID           string          `json:"id"`
	Platform     string          `json:"platform"`
	Name         string          `json:"name"`
	Capabilities map[string]bool `json:"capabilities"`
	LastSeenAt   string          `json:"last_seen_at,omitempty"`
	CreatedAt    string          `json:"created_at"`
	UpdatedAt    string          `json:"updated_at"`
}

// deviceToResponse 不返回 push_token：客户端本来就持有它，回传只会增加它出现在日志、
// 缓存和代理链路里的机会。
func deviceToResponse(d store.Device) deviceResponse {
	out := deviceResponse{
		ID:           d.ID,
		Platform:     d.Platform,
		Name:         d.Name,
		Capabilities: d.Capabilities,
		CreatedAt:    d.CreatedAt.UTC().Format(time.RFC3339),
		UpdatedAt:    d.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if out.Capabilities == nil {
		out.Capabilities = map[string]bool{}
	}
	if !d.LastSeenAt.IsZero() {
		out.LastSeenAt = d.LastSeenAt.UTC().Format(time.RFC3339)
	}
	return out
}

type deviceListResponse struct {
	Devices []deviceResponse `json:"devices"`
}

// handleListDevices 只列当前令牌对应的账号的设备。
func (h *AccountHandler) handleListDevices(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	devices, err := h.deps.Users.DevicesByUser(r.Context(), userID)
	if err != nil {
		writeInternal(w, r, err)
		return
	}
	out := make([]deviceResponse, 0, len(devices))
	for _, d := range devices {
		out = append(out, deviceToResponse(d))
	}
	httpx.WriteJSON(w, http.StatusOK, deviceListResponse{Devices: out})
}

// handleUpsertDevice 登记或更新一台设备。
func (h *AccountHandler) handleUpsertDevice(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	// 复用注册时的 devicePayload：两个入口共用一套字段定义，才不会各自漂移。
	var req devicePayload
	if err := httpx.DecodeJSON(r, &req); err != nil {
		writeDecodeError(w, r, err)
		return
	}
	normalized, err := normalizeDevicePayload(req)
	if err != nil {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, err.Error())
		return
	}
	resp, created, err := h.applyDevice(r.Context(), userID, normalized)
	if err != nil {
		h.writeDeviceError(w, r, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, resp)
}

// handleDeleteDevice 注销设备。别人的设备与不存在的设备返回同一个 404。
func (h *AccountHandler) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		httpx.WriteError(w, r, httpx.CodeNotFound, "设备不存在。")
		return
	}
	if err := h.deps.Users.DeleteDevice(r.Context(), userID, id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			httpx.WriteError(w, r, httpx.CodeNotFound, "设备不存在。")
			return
		}
		writeInternal(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// applyDevice 写入设备并返回对外表示；created 表示这是新设备（决定 200 还是 201）。
func (h *AccountHandler) applyDevice(ctx context.Context, userID string, in devicePayload) (deviceResponse, bool, error) {
	now := h.now()
	createdAt := now
	created := true
	switch existing, err := h.deps.Users.DeviceByID(ctx, userID, in.ID); {
	case err == nil:
		createdAt = existing.CreatedAt
		created = false
	case errors.Is(err, store.ErrNotFound):
		// 新设备，按当前时间登记。
	default:
		return deviceResponse{}, false, err
	}

	if created {
		// 设备数量上限：防止一个账号无限登记设备，把推送扇出和存储都放大。
		devices, err := h.deps.Users.DevicesByUser(ctx, userID)
		if err != nil {
			return deviceResponse{}, false, err
		}
		if len(devices) >= maxDevices {
			return deviceResponse{}, false, errTooManyDevices
		}
	}

	d := store.Device{
		ID:           in.ID,
		UserID:       userID,
		Platform:     in.Platform,
		Name:         in.Name,
		Capabilities: in.Capabilities,
		PushToken:    in.PushToken,
		LastSeenAt:   now,
		CreatedAt:    createdAt,
		UpdatedAt:    now,
	}
	if err := h.deps.Users.UpsertDevice(ctx, d); err != nil {
		return deviceResponse{}, false, err
	}
	return deviceToResponse(d), created, nil
}

func (h *AccountHandler) writeDeviceError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, errTooManyDevices):
		httpx.WriteError(w, r, httpx.CodeUnprocessable, err.Error())
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrForeign):
		// 别人的设备 ID 一律当作"不存在"：返回 403/409 等于告诉对方"这个 ID 确实存在"。
		httpx.WriteError(w, r, httpx.CodeNotFound, "设备不存在。")
	default:
		writeInternal(w, r, err)
	}
}
