package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

// ---------- 推送 ----------

// syncPushItem 是客户端提交的一条变更。字段名与 syncsvc.PushItem 对齐，
// 但**没有 user_id**：归属只由令牌决定。
type syncPushItem struct {
	Type        store.EntityType `json:"type"`
	ID          string           `json:"id"`
	BaseVersion int64            `json:"base_version"`
	Payload     json.RawMessage  `json:"payload"`
	UpdatedAt   time.Time        `json:"updated_at"`
	Deleted     bool             `json:"deleted"`
}

type syncPushRequest struct {
	Items []syncPushItem `json:"items"`
}

// syncPushResult 是一条变更的结算结果。
type syncPushResult struct {
	Type          store.EntityType    `json:"type"`
	ID            string              `json:"id"`
	Outcome       syncsvc.PushOutcome `json:"outcome"`
	Version       int64               `json:"version,omitempty"`
	ServerVersion int64               `json:"server_version,omitempty"`
	ServerDeleted bool                `json:"server_deleted,omitempty"`
	ServerPayload json.RawMessage     `json:"server_payload,omitempty"`
	Reason        string              `json:"reason,omitempty"`
}

type syncPushResponse struct {
	Results []syncPushResult `json:"results"`
}

// handleSyncPush 批量推送并**逐条结算**。
//
// 返回结果与入参一一对应且同序：客户端要能按位置对上自己发的内容，
// 否则一条冲突之后，后面的结果就全部错位了。
func (h *AccountHandler) handleSyncPush(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	var req syncPushRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		writeDecodeError(w, r, err)
		return
	}
	if len(req.Items) > maxPushItems {
		httpx.WriteError(w, r, httpx.CodeUnprocessable, "单次推送条目过多，请分批提交。")
		return
	}

	items := make([]syncsvc.PushItem, 0, len(req.Items))
	for _, it := range req.Items {
		items = append(items, syncsvc.PushItem{
			Type:        it.Type,
			ID:          it.ID,
			BaseVersion: it.BaseVersion,
			Payload:     []byte(it.Payload),
			UpdatedAt:   it.UpdatedAt,
			Deleted:     it.Deleted,
		})
	}

	results, err := h.deps.Sync.Push(r.Context(), userID, items)
	if err != nil {
		writeInternal(w, r, err)
		return
	}
	out := make([]syncPushResult, 0, len(results))
	for _, res := range results {
		out = append(out, syncPushResult{
			Type:          res.Type,
			ID:            res.ID,
			Outcome:       res.Outcome,
			Version:       res.Version,
			ServerVersion: res.ServerVersion,
			ServerDeleted: res.ServerDeleted,
			ServerPayload: rawOrNull(res.ServerPayload),
			Reason:        res.Reason,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, syncPushResponse{Results: out})
}

// ---------- 拉取 ----------

type syncPullChange struct {
	Type      store.EntityType `json:"type"`
	ID        string           `json:"id"`
	Version   int64            `json:"version"`
	UpdatedAt time.Time        `json:"updated_at"`
	Deleted   bool             `json:"deleted"`
	Tombstone bool             `json:"tombstone"`
	Payload   json.RawMessage  `json:"payload"`
}

type syncPullResponse struct {
	Changes []syncPullChange `json:"changes"`
	Cursor  string           `json:"cursor"`
	HasMore bool             `json:"has_more"`
}

// handleSyncPull 拉取游标之后的变更。
func (h *AccountHandler) handleSyncPull(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}

	cursor := strings.TrimSpace(r.URL.Query().Get("cursor"))
	// 游标严格校验：坏游标必须报 400，绝不能静默当成空游标 ——
	// 那会让客户端重放整份快照，或者被误读成"服务端没有变更"。
	if cursor != "" {
		if _, err := strconv.ParseInt(cursor, 10, 64); err != nil {
			httpx.WriteError(w, r, httpx.CodeInvalidRequest, "cursor 必须是整数版本号。")
			return
		}
	}
	limit := 0
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 || n > maxPullLimit {
			httpx.WriteError(w, r, httpx.CodeInvalidRequest, "limit 必须是 1 到 500 之间的整数。")
			return
		}
		limit = n
	}

	res, err := h.deps.Sync.Pull(r.Context(), userID, cursor, limit)
	if err != nil {
		writeInternal(w, r, err)
		return
	}
	changes := make([]syncPullChange, 0, len(res.Changes))
	for _, c := range res.Changes {
		changes = append(changes, syncPullChange{
			Type:      c.Record.Type,
			ID:        c.Record.ID,
			Version:   c.Record.Version,
			UpdatedAt: c.Record.UpdatedAt,
			Deleted:   c.Record.Deleted(),
			Tombstone: c.Tombstone,
			Payload:   rawOrNull(c.Record.Payload),
		})
	}
	httpx.WriteJSON(w, http.StatusOK, syncPullResponse{
		Changes: changes,
		Cursor:  res.Cursor,
		HasMore: res.HasMore,
	})
}

// ---------- 导出 ----------

type exportRecord struct {
	Type      store.EntityType `json:"type"`
	ID        string           `json:"id"`
	Version   int64            `json:"version"`
	UpdatedAt time.Time        `json:"updated_at"`
	Deleted   bool             `json:"deleted"`
	Tombstone bool             `json:"tombstone"`
	Payload   json.RawMessage  `json:"payload"`
}

type exportMemory struct {
	ID          string  `json:"id"`
	Category    string  `json:"category"`
	Statement   string  `json:"statement"`
	Status      string  `json:"status"`
	SourceKind  string  `json:"source_kind"`
	Confidence  float64 `json:"confidence"`
	SourceRef   string  `json:"source_ref"`
	Revision    int64   `json:"revision"`
	EffectiveTo string  `json:"effective_to,omitempty"`
	CreatedAt   string  `json:"created_at"`
	UpdatedAt   string  `json:"updated_at"`
	Deleted     bool    `json:"deleted"`
}

type exportResponse struct {
	SchemaVersion string           `json:"schema_version"`
	UserID        string           `json:"user_id"`
	ExportedAt    string           `json:"exported_at"`
	Records       []exportRecord   `json:"records"`
	Memories      []exportMemory   `json:"memories"`
	Devices       []deviceResponse `json:"devices"`
}

// handleExport 导出当前账号的全部数据。
//
// 导出**包含墓碑**：用户需要知道"这里曾经有过东西"，客户端也据此清理本地残留。
func (h *AccountHandler) handleExport(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	bundle, err := h.deps.Sync.Export(r.Context(), userID)
	if err != nil {
		writeInternal(w, r, err)
		return
	}

	resp := exportResponse{
		SchemaVersion: "1.0",
		UserID:        userID,
		ExportedAt:    bundle.ExportedAt.UTC().Format(time.RFC3339),
		Records:       make([]exportRecord, 0, len(bundle.Records)),
		Memories:      make([]exportMemory, 0, len(bundle.Memories)),
		Devices:       make([]deviceResponse, 0, len(bundle.Devices)),
	}
	for _, rec := range bundle.Records {
		resp.Records = append(resp.Records, exportRecord{
			Type:      rec.Type,
			ID:        rec.ID,
			Version:   rec.Version,
			UpdatedAt: rec.UpdatedAt,
			Deleted:   rec.Deleted(),
			Tombstone: rec.Deleted(),
			Payload:   rawOrNull(rec.Payload),
		})
	}
	for _, m := range bundle.Memories {
		item := exportMemory{
			ID:         m.ID,
			Category:   m.Category,
			Statement:  m.Statement,
			Status:     m.Status,
			SourceKind: m.SourceKind,
			Confidence: m.Confidence,
			SourceRef:  m.SourceRef,
			Revision:   m.Revision,
			CreatedAt:  m.CreatedAt.UTC().Format(time.RFC3339),
			UpdatedAt:  m.UpdatedAt.UTC().Format(time.RFC3339),
			Deleted:    m.DeletedAt != nil,
		}
		if m.EffectiveTo != nil {
			item.EffectiveTo = m.EffectiveTo.UTC().Format(time.RFC3339)
		}
		resp.Memories = append(resp.Memories, item)
	}
	for _, d := range bundle.Devices {
		resp.Devices = append(resp.Devices, deviceToResponse(d))
	}

	// 导出是"下载一份文件"的语义：带上文件名，客户端才知道这是要落盘的东西。
	w.Header().Set("Content-Disposition", `attachment; filename="daycue-export.json"`)
	httpx.WriteJSON(w, http.StatusOK, resp)
}

// handleDeleteAccount 删除账号与全部数据。
//
// 返回 204：数据在存储层同一事务里清掉并写账号墓碑，调用方不需要解析响应体。
func (h *AccountHandler) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFrom(r.Context())
	if !ok {
		writeUnauthorized(w, r)
		return
	}
	if err := h.deps.Sync.Purge(r.Context(), userID); err != nil {
		writeInternal(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// rawOrNull 把空负载或非法负载降级成 JSON null。
//
// 直接把 []byte 塞进 json.RawMessage，只要库里有一条坏数据，整个响应就会因为序列化
// 失败变成 500，把其他健康数据一起拖下水。
func rawOrNull(payload []byte) json.RawMessage {
	if len(payload) == 0 || !json.Valid(payload) {
		return nil
	}
	return json.RawMessage(payload)
}
