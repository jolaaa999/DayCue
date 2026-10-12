// Package syncsvc 编排增量同步：批量推送、增量拉取、冲突上报与删除传播。
//
// 设计取舍：
//   - 服务端**不替用户解决冲突**。同一实体被两端同时修改时，返回双方内容，
//     由客户端呈现给用户逐字段决定。自动选边会造成静默数据丢失。
//   - 推送是**逐条独立结算**的：一条冲突不影响其余条目落库。
//     整批回滚会让用户以为"全都没保存"，而实际只是其中一条有冲突。
//   - 删除走墓碑（baseVersion 必须正确），绝不物理删行 ——
//     否则离线设备永远学不到删除，本地会留下幽灵数据。
package syncsvc

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// PushItem 是客户端提交的一条变更。
type PushItem struct {
	Type store.EntityType
	ID   string
	// BaseVersion 是客户端所基于的服务端版本；0 表示"我认为这是新增"。
	BaseVersion int64
	Payload     []byte
	UpdatedAt   time.Time
	// Deleted 为 true 时写墓碑而不是内容。
	Deleted bool
}

// PushOutcome 是一条变更的结算结果。
type PushOutcome string

const (
	// OutcomeAccepted 表示已落库。
	OutcomeAccepted PushOutcome = "accepted"
	// OutcomeConflict 表示版本冲突，需要用户处理，服务端不改动任何数据。
	OutcomeConflict PushOutcome = "conflict"
	// OutcomeRejected 表示这条请求本身不合法（例如缺 ID），与数据无关。
	OutcomeRejected PushOutcome = "rejected"
)

// PushResult 是逐条结算结果。
type PushResult struct {
	Type    store.EntityType
	ID      string
	Outcome PushOutcome
	// Version 在 Accepted 时是新版本号。
	Version int64
	// ServerVersion / ServerPayload 在 Conflict 时给出服务端现状，
	// 供客户端展示"本地这版 vs 服务端那版"。
	ServerVersion int64
	ServerPayload []byte
	ServerDeleted bool
	// Reason 是给用户看的中文原因；Rejected 时必填。
	Reason string
}

// Service 是同步用例的入口。
type Service struct {
	Sync store.SyncStore
	// 字段名叫 Exporter 而不是 Export：本类型另有一个 Export 方法，
	// 同名字段与方法在 Go 里直接冲突（编译不过），换个名字最省事也最清晰。
	Exporter store.ExportStore
	Now      func() time.Time
}

// Push 逐条处理客户端变更。
//
// 返回的切片与入参**一一对应且同序**：客户端要能按位置对上自己发的内容，
// 否则一条冲突之后，后面的结果就全错位了。
func (s *Service) Push(ctx context.Context, userID string, items []PushItem) ([]PushResult, error) {
	if strings.TrimSpace(userID) == "" {
		return nil, errors.New("syncsvc: userID 不能为空")
	}
	now := s.now()

	results := make([]PushResult, 0, len(items))
	for _, it := range items {
		results = append(results, s.pushOne(ctx, userID, it, now))
	}
	return results, nil
}

func (s *Service) pushOne(ctx context.Context, userID string, it PushItem, now time.Time) PushResult {
	res := PushResult{Type: it.Type, ID: it.ID}

	if strings.TrimSpace(it.ID) == "" || strings.TrimSpace(string(it.Type)) == "" {
		res.Outcome = OutcomeRejected
		res.Reason = "缺少实体类型或 ID"
		return res
	}
	if it.BaseVersion < 0 {
		res.Outcome = OutcomeRejected
		res.Reason = "基准版本不能为负"
		return res
	}

	rec := store.Record{
		UserID:    userID,
		Type:      it.Type,
		ID:        it.ID,
		UpdatedAt: it.UpdatedAt,
		Payload:   it.Payload,
	}
	if it.Deleted {
		t := it.UpdatedAt
		if t.IsZero() {
			t = now
		}
		rec.DeletedAt = &t
		// 墓碑不该带着内容：留着正文等于"删了行却还在库里"。
		rec.Payload = nil
	}

	saved, err := s.Sync.Push(ctx, rec, it.BaseVersion)
	switch {
	case err == nil:
		res.Outcome = OutcomeAccepted
		res.Version = saved.Version
	case errors.Is(err, store.ErrConflict):
		res.Outcome = OutcomeConflict
		// 冲突时必须把服务端现状带回去，否则客户端无法让用户比较。
		if cur, gerr := s.currentVersion(ctx, userID, it.Type, it.ID); gerr == nil {
			res.ServerVersion = cur
		}
		res.Reason = "该条目在服务端已被修改，请逐项确认保留哪一版"
	case errors.Is(err, store.ErrNotFound):
		res.Outcome = OutcomeConflict
		res.Reason = "该条目在服务端已不存在，请重新拉取后再试"
	default:
		return PushResult{Type: it.Type, ID: it.ID, Outcome: OutcomeRejected,
			Reason: fmt.Sprintf("写入失败: %v", err)}
	}
	return res
}

// currentVersion 读取服务端某条记录的当前版本与内容，用于冲突展示。
func (s *Service) currentVersion(ctx context.Context, userID string, t store.EntityType, id string) (int64, error) {
	changes, _, err := s.Sync.Pull(ctx, userID, "", 0)
	if err != nil {
		return 0, err
	}
	for _, c := range changes {
		if c.Record.Type == t && c.Record.ID == id {
			return c.Record.Version, nil
		}
	}
	return 0, store.ErrNotFound
}

// Conflict 是需要用户处理的冲突项。
type Conflict struct {
	Type          store.EntityType
	ID            string
	ServerVersion int64
	ServerDeleted bool
	ServerPayload []byte
}

// PushAndCollectConflicts 是 Push 的便利封装：把冲突单独摘出来。
//
// 之所以单独给一个方法，是因为调用方很容易只处理"成功/失败"而把冲突
// 当成失败丢掉 —— 那等于把用户的数据静默丢在服务端。
func (s *Service) PushAndCollectConflicts(ctx context.Context, userID string, items []PushItem) ([]PushResult, []Conflict, error) {
	results, err := s.Push(ctx, userID, items)
	if err != nil {
		return nil, nil, err
	}
	var conflicts []Conflict
	for _, r := range results {
		if r.Outcome == OutcomeConflict {
			conflicts = append(conflicts, Conflict{
				Type: r.Type, ID: r.ID, ServerVersion: r.ServerVersion,
				ServerDeleted: r.ServerDeleted, ServerPayload: r.ServerPayload,
			})
		}
	}
	return results, conflicts, nil
}

// PullResult 是一次增量拉取的结果。
type PullResult struct {
	Changes []store.Change
	Cursor  string
	// HasMore 表示服务端还有更多变更，客户端应当继续拉。
	HasMore bool
}

// Pull 拉取游标之后的变更。
func (s *Service) Pull(ctx context.Context, userID, cursor string, limit int) (PullResult, error) {
	if strings.TrimSpace(userID) == "" {
		return PullResult{}, errors.New("syncsvc: userID 不能为空")
	}
	if limit <= 0 {
		limit = 200
	}
	// 多取一条用来判断"还有更多"，避免客户端为了知道有没有下一页而多跑一次。
	changes, next, err := s.Sync.Pull(ctx, userID, cursor, limit+1)
	if err != nil {
		return PullResult{}, fmt.Errorf("syncsvc: 拉取失败: %w", err)
	}
	hasMore := len(changes) > limit
	if hasMore {
		changes = changes[:limit]
		next = fmt.Sprintf("%d", changes[len(changes)-1].Record.Version)
	}
	return PullResult{Changes: changes, Cursor: next, HasMore: hasMore}, nil
}

// Export 导出用户全部数据（含墓碑）。
func (s *Service) Export(ctx context.Context, userID string) (store.ExportBundle, error) {
	if strings.TrimSpace(userID) == "" {
		return store.ExportBundle{}, errors.New("syncsvc: userID 不能为空")
	}
	b, err := s.Exporter.Export(ctx, userID)
	if err != nil {
		return store.ExportBundle{}, fmt.Errorf("syncsvc: 导出失败: %w", err)
	}
	// 导出顺序必须稳定，否则同样的数据两次导出得到不同文件，用户会以为数据变了。
	sort.Slice(b.Records, func(i, j int) bool {
		if b.Records[i].Type != b.Records[j].Type {
			return b.Records[i].Type < b.Records[j].Type
		}
		return b.Records[i].ID < b.Records[j].ID
	})
	return b, nil
}

// Purge 彻底删除用户数据。
func (s *Service) Purge(ctx context.Context, userID string) error {
	if strings.TrimSpace(userID) == "" {
		return errors.New("syncsvc: userID 不能为空")
	}
	return s.Exporter.Purge(ctx, userID)
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}
