// Package store 定义 DayCue 服务端的数据访问边界。
//
// 设计取舍：接口放在这里，内存实现与 PostgreSQL 实现分别在 memory.go / postgres.go。
// 之所以坚持"接口 + 两个实现"，是因为本机没有可用的 PostgreSQL —— 领域逻辑
// （用户隔离、同步冲突、删除传播）必须能在纯 Go 单元测试里被真正验证，
// 而不是靠"读一遍 SQL 觉得没问题"。
package store

import (
	"context"
	"errors"
	"time"
)

// ErrNotFound 表示记录不存在。调用方必须区分它与"查询失败"：
// 把查询失败当成不存在，会导致同步时误删用户数据。
var ErrNotFound = errors.New("store: 记录不存在")

// ErrConflict 表示版本冲突，需要上层交给用户处理，不得自动选边。
var ErrConflict = errors.New("store: 版本冲突")

// EntityType 是同步实体的种类。取值直接进库，发布后不可改名。
type EntityType string

const (
	EntityTask             EntityType = "task"
	EntityNote             EntityType = "note"
	EntityCapture          EntityType = "capture"
	EntityCourse           EntityType = "course"
	EntityCourseInstance   EntityType = "course_instance"
	EntityFollowUp         EntityType = "follow_up"
	EntityMemory           EntityType = "memory"
	EntityPlace            EntityType = "place"
	EntityGeoRule          EntityType = "geo_rule"
	EntityProactiveMessage EntityType = "proactive_message"
)

// Record 是参与同步的记录的通用形态。
//
// Payload 保存实体自身的 JSON。之所以不用泛型 + 具体结构体，是因为同步层
// 需要把任意实体统一地比较哈希、写墓碑、算版本；把实体差异挡在编解码之外更简单。
type Record struct {
	UserID    string
	Type      EntityType
	ID        string
	Version   int64
	UpdatedAt time.Time
	DeletedAt *time.Time
	Payload   []byte
}

// Deleted 表示这条记录当前是墓碑（已删除）。
func (r Record) Deleted() bool { return r.DeletedAt != nil }

// Change 是一次同步拉取返回的变更。
type Change struct {
	Record    Record
	Tombstone bool
}

// User 是账号。云同步是可选的：没有账号时客户端完全走本地库。
type User struct {
	ID           string
	Email        string
	DisplayName  string
	PasswordHash string
	// TimeZone 是用户上报的 IANA 时区名（例如 Asia/Shanghai）。
	//
	// 语义与库里的可空列一致：空串表示**未知**，读取时必须回退 UTC（见 store.UserTimeZone）。
	// "未知"与"UTC"刻意区分开：前者是没信息，后者是一个确定的选择。
	// 凡是与"今天""静默时段"有关的判定都必须按它来，而账本里的绝对时刻一律仍存 UTC。
	TimeZone  string
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

// Device 是一台已登记的客户端设备。
type Device struct {
	ID           string
	UserID       string
	Platform     string
	Name         string
	Capabilities map[string]bool
	PushToken    string
	LastSeenAt   time.Time
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// MediaObject 是私有媒体对象。服务端只保存元数据，字节流由 MediaStore 负责。
type MediaObject struct {
	ID          string
	UserID      string
	OwnerType   string
	OwnerID     string
	ContentType string
	ByteSize    int64
	SHA256      string
	StorageKey  string
	CreatedAt   time.Time
}

// MemoryItem 是长期记忆在服务端的投影。
type MemoryItem struct {
	ID          string
	UserID      string
	Category    string
	Statement   string
	Status      string
	SourceKind  string
	Confidence  float64
	SourceRef   string
	Revision    int64
	EffectiveTo *time.Time
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   *time.Time
}

// ExportBundle 是数据导出结果。导出必须含墓碑，否则用户无法知道"这里曾经有东西"。
type ExportBundle struct {
	UserID     string
	ExportedAt time.Time
	Records    []Record
	Memories   []MemoryItem
	Devices    []Device
}

// UserStore 管理账号与设备。所有方法都必须按 userID 隔离。
type UserStore interface {
	CreateUser(ctx context.Context, u User) error
	UserByEmail(ctx context.Context, email string) (User, error)
	UserByID(ctx context.Context, id string) (User, error)
	SoftDeleteUser(ctx context.Context, id string, at time.Time) error
	// SetUserTimeZone 写入 IANA 时区名；空串表示清空为"未知"。
	// 非法时区名必须被拒绝：写进去读不出来的值等于用户以为自己设了时区、实际按 UTC 算。
	SetUserTimeZone(ctx context.Context, userID string, tz string, at time.Time) error
	// UserTimeZone 返回用户时区名（原样，可能为空串表示未知）。
	//
	// 返回名字而不是 *time.Location：本包不替调用方决定"未知时用什么"，
	// 回退策略由调用方（调度层）显式给出，免得两处口径不一致。
	UserTimeZone(ctx context.Context, userID string) (string, error)

	UpsertDevice(ctx context.Context, d Device) error
	DeviceByID(ctx context.Context, userID, id string) (Device, error)
	DevicesByUser(ctx context.Context, userID string) ([]Device, error)
	DeleteDevice(ctx context.Context, userID, id string) error
}

// SyncStore 是增量同步的存储边界。
//
// 语义约定（实现与测试都必须遵守）：
//   - 每个 (user, type, id) 只保留**一条当前记录**，配上单调递增的 Version。
//     不做追加式 oplog：客户端要的是"现在是什么样"，不是历史。
//   - 删除不删行，而是写墓碑（DeletedAt 非空）并抬高 Version，
//     这样已经拉到旧版本的客户端下次仍能通过游标看到"它被删了"。
//   - 因此从空游标拉取得到的是**当前快照**（含墓碑），而不是全部历史。
//     把查询失败或空结果当成"没有"，会直接导致误删客户端数据。
type SyncStore interface {
	// Pull 返回 cursor 之后的变更。cursor 为空表示从头拉取当前快照（含墓碑）。
	Pull(ctx context.Context, userID string, after string, limit int) ([]Change, string, error)
	// Push 写入一条变更。baseVersion 为 0 表示新增；版本不匹配返回 ErrConflict。
	Push(ctx context.Context, rec Record, baseVersion int64) (Record, error)
	// Cursor 返回该用户当前的同步游标。
	Cursor(ctx context.Context, userID string) (string, error)
}

// MemoryStore 是记忆的服务端存储边界。
type MemoryStore interface {
	UpsertMemory(ctx context.Context, m MemoryItem) error
	MemoriesByUser(ctx context.Context, userID string, includeDeleted bool) ([]MemoryItem, error)
	DeleteMemory(ctx context.Context, userID, id string, at time.Time) error
}

// ExportStore 负责导出与彻底删除。
type ExportStore interface {
	Export(ctx context.Context, userID string) (ExportBundle, error)
	Purge(ctx context.Context, userID string) error
}
