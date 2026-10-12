package api

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/media"
)

const (
	maxOwnerTypeChars = 64
	maxOwnerIDChars   = 128
	// multipart 解析时驻留内存的上限；超出部分由标准库落到临时文件，避免大文件吃满内存。
	multipartMemoryBytes = 8 << 20
)

type mediaResponse struct {
	ID          string `json:"id"`
	OwnerType   string `json:"owner_type"`
	OwnerID     string `json:"owner_id"`
	ContentType string `json:"content_type"`
	ByteSize    int64  `json:"byte_size"`
	SHA256      string `json:"sha256"`
	CreatedAt   string `json:"created_at"`
}

// mediaToResponse 不下发 storage_key：那是服务端的落盘路径，客户端既不需要也不该知道。
func mediaToResponse(o media.Object) mediaResponse {
	return mediaResponse{
		ID:          o.ID,
		OwnerType:   o.OwnerType,
		OwnerID:     o.OwnerID,
		ContentType: o.ContentType,
		ByteSize:    o.ByteSize,
		SHA256:      o.SHA256,
		CreatedAt:   o.CreatedAt.UTC().Format(time.RFC3339),
	}
}

// handleMediaUpload 接收 multipart 上传并落盘。归属由令牌决定，owner 只描述挂在哪条记录上。
func (h *AccountHandler) handleMediaUpload(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	if err := r.ParseMultipartForm(multipartMemoryBytes); err != nil {
		if httpx.IsBodyTooLarge(err) {
			httpx.WriteError(w, r, httpx.CodePayloadTooLarge, "上传内容过大。")
			return
		}
		httpx.WriteError(w, r, httpx.CodeInvalidRequest, "请求必须是 multipart/form-data 上传。")
		return
	}
	// 临时文件必须清掉，否则每次上传都会在系统临时目录留下副本。
	defer func() { _ = r.MultipartForm.RemoveAll() }()

	ownerType := strings.TrimSpace(r.FormValue("owner_type"))
	if ownerType == "" || len(ownerType) > maxOwnerTypeChars {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, "owner_type 必填且长度不超过 64。")
		return
	}
	ownerID := strings.TrimSpace(r.FormValue("owner_id"))
	if ownerID == "" || len(ownerID) > maxOwnerIDChars {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, "owner_id 必填且长度不超过 128。")
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, "缺少 file 字段。")
		return
	}
	defer file.Close()

	contentType := strings.TrimSpace(header.Header.Get("Content-Type"))
	if contentType == "" {
		// 客户端没给类型时按前 512 字节嗅探；嗅探不出可用类型就交给媒体层按白名单拒绝。
		buf := make([]byte, 512)
		n, _ := io.ReadFull(file, buf)
		contentType = http.DetectContentType(buf[:n])
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			writeInternal(w, r, err)
			return
		}
	}

	obj, err := h.deps.Media.Put(r.Context(), userID, ownerType, ownerID, contentType, file)
	if err != nil {
		h.writeMediaError(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, mediaToResponse(obj))
}

// handleMediaDownload 下载媒体。别人的对象会被存储层按 userID 过滤掉，返回 404。
func (h *AccountHandler) handleMediaDownload(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		httpx.WriteError(w, r, httpx.CodeNotFound, "媒体不存在。")
		return
	}
	rc, obj, err := h.deps.Media.Open(r.Context(), userID, id)
	if err != nil {
		h.writeMediaError(w, r, err)
		return
	}
	defer rc.Close()

	w.Header().Set("Content-Type", obj.ContentType)
	w.Header().Set("Content-Length", strconv.FormatInt(obj.ByteSize, 10))
	// 私有内容：禁止中间层与浏览器缓存，否则同机其他用户可能从缓存里读到。
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-DayCue-SHA256", obj.SHA256)
	w.WriteHeader(http.StatusOK)
	if _, err := io.Copy(w, rc); err != nil {
		// 响应头已经发出，改不了状态码；记日志即可，字节数差异会体现在访问日志里。
		slog.Warn("下载媒体中断", "trace_id", httpx.RequestID(r), "reason", err.Error())
	}
}

// handleMediaDelete 删除媒体。
func (h *AccountHandler) handleMediaDelete(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		httpx.WriteError(w, r, httpx.CodeNotFound, "媒体不存在。")
		return
	}
	if err := h.deps.Media.Delete(r.Context(), userID, id); err != nil {
		h.writeMediaError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// writeMediaError 把媒体层错误映射成契约内的错误码。
func (h *AccountHandler) writeMediaError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, media.ErrTooLarge):
		httpx.WriteError(w, r, httpx.CodePayloadTooLarge, "文件超过大小上限。")
	case errors.Is(err, media.ErrUnsupportedType):
		httpx.WriteError(w, r, httpx.CodeUnsupportedMedia, "不支持的内容类型。")
	case errors.Is(err, media.ErrNotFound):
		httpx.WriteError(w, r, httpx.CodeNotFound, "媒体不存在。")
	case errors.Is(err, media.ErrEmptyUser):
		// 存储层没拿到 userID，说明是服务端接线错误，不是客户端的问题。
		writeInternal(w, r, err)
	default:
		writeInternal(w, r, err)
	}
}
