package store

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Memory 是 store 各接口的内存实现。
//
// 存在意义不是"跑得快的缓存"，而是让用户隔离、版本冲突、墓碑传播这些
// 容易写错又难复现的规则，在没有数据库的机器上也能被单元测试真正覆盖。
type Memory struct {
	mu       sync.RWMutex
	users    map[string]User
	devices  map[string]Device
	records  map[string]Record
	memories map[string]MemoryItem
	seq      int64
	// now 可注入，便于测试固定时间基准；绝不使用 time.Now 之外的行为差异。
	now func() time.Time
}

// NewMemory 构造内存实现。now 为空时使用 time.Now。
func NewMemory(now func() time.Time) *Memory {
	if now == nil {
		now = time.Now
	}
	return &Memory{
		users:    map[string]User{},
		devices:  map[string]Device{},
		records:  map[string]Record{},
		memories: map[string]MemoryItem{},
		now:      now,
	}
}

func recordKey(userID string, t EntityType, id string) string {
	return userID + "|" + string(t) + "|" + id
}

// ---------- UserStore ----------

func (m *Memory) CreateUser(ctx context.Context, u User) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.users[u.ID]; ok {
		return fmt.Errorf("store: 用户 %s 已存在", u.ID)
	}
	for _, e := range m.users {
		// 邮箱唯一性必须在这里挡，否则同一个邮箱会建出两个账号。
		if strings.EqualFold(e.Email, u.Email) && e.DeletedAt == nil {
			return fmt.Errorf("store: 邮箱已被占用")
		}
	}
	m.users[u.ID] = u
	return nil
}

func (m *Memory) UserByEmail(ctx context.Context, email string) (User, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, u := range m.users {
		if strings.EqualFold(u.Email, email) && u.DeletedAt == nil {
			return u, nil
		}
	}
	return User{}, ErrNotFound
}

func (m *Memory) UserByID(ctx context.Context, id string) (User, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	u, ok := m.users[id]
	if !ok || u.DeletedAt != nil {
		return User{}, ErrNotFound
	}
	return u, nil
}

func (m *Memory) SoftDeleteUser(ctx context.Context, id string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return ErrNotFound
	}
	t := at
	u.DeletedAt = &t
	u.UpdatedAt = at
	m.users[id] = u
	return nil
}

// SetUserTimeZone 写入用户时区；空串表示清空为"未知"。
func (m *Memory) SetUserTimeZone(ctx context.Context, userID string, tz string, at time.Time) error {
	normalized, err := normalizeTimeZone(tz)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[userID]
	if !ok || u.DeletedAt != nil {
		return ErrNotFound
	}
	u.TimeZone = normalized
	u.UpdatedAt = at
	m.users[userID] = u
	return nil
}

// UserTimeZone 返回用户时区名；未知时返回空串而不是 UTC。
//
// 刻意不在这里回退 UTC：回退是**策略**，属于调度层的决定；
// 存储层替调用方做决定会让"未知"这个事实彻底消失。
func (m *Memory) UserTimeZone(ctx context.Context, userID string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	u, ok := m.users[userID]
	if !ok || u.DeletedAt != nil {
		return "", ErrNotFound
	}
	return u.TimeZone, nil
}

func (m *Memory) UpsertDevice(ctx context.Context, d Device) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.users[d.UserID]; !ok {
		return ErrNotFound
	}
	m.devices[recordKey(d.UserID, "device", d.ID)] = d
	return nil
}

func (m *Memory) DeviceByID(ctx context.Context, userID, id string) (Device, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	d, ok := m.devices[recordKey(userID, "device", id)]
	if !ok {
		return Device{}, ErrNotFound
	}
	return d, nil
}

func (m *Memory) DevicesByUser(ctx context.Context, userID string) ([]Device, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []Device
	for _, d := range m.devices {
		if d.UserID == userID {
			out = append(out, d)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (m *Memory) DeleteDevice(ctx context.Context, userID, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := recordKey(userID, "device", id)
	if _, ok := m.devices[k]; !ok {
		return ErrNotFound
	}
	delete(m.devices, k)
	return nil
}

// ---------- SyncStore ----------

func (m *Memory) Push(ctx context.Context, rec Record, baseVersion int64) (Record, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := recordKey(rec.UserID, rec.Type, rec.ID)
	cur, exists := m.records[k]

	// 新增：库里不应已有记录，否则说明客户端与服务端的认知已经分叉。
	if baseVersion == 0 {
		if exists && cur.DeletedAt == nil {
			return Record{}, ErrConflict
		}
	} else {
		if !exists {
			return Record{}, ErrNotFound
		}
		// 版本必须严格递增匹配，否则就是并发写。
		if cur.Version != baseVersion {
			return Record{}, ErrConflict
		}
	}

	m.seq++
	next := Record{
		UserID:    rec.UserID,
		Type:      rec.Type,
		ID:        rec.ID,
		Version:   m.seq,
		UpdatedAt: rec.UpdatedAt,
		DeletedAt: rec.DeletedAt,
		Payload:   rec.Payload,
	}
	if next.UpdatedAt.IsZero() {
		next.UpdatedAt = m.now()
	}
	m.records[k] = next
	return next, nil
}

func (m *Memory) Pull(ctx context.Context, userID string, after string, limit int) ([]Change, string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	from := int64(0)
	if after != "" {
		v, err := strconv.ParseInt(after, 10, 64)
		if err != nil {
			return nil, "", fmt.Errorf("store: 非法游标 %q: %w", after, err)
		}
		from = v
	}

	var all []Record
	for _, r := range m.records {
		if r.UserID == userID && r.Version > from {
			all = append(all, r)
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].Version < all[j].Version })

	cursor := after
	if len(all) == 0 {
		return nil, cursor, nil
	}
	if limit <= 0 {
		limit = len(all)
	}
	if len(all) > limit {
		all = all[:limit]
	}

	out := make([]Change, 0, len(all))
	for _, r := range all {
		out = append(out, Change{Record: r, Tombstone: r.Deleted()})
		cursor = strconv.FormatInt(r.Version, 10)
	}
	return out, cursor, nil
}

func (m *Memory) Cursor(ctx context.Context, userID string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var max int64
	for _, r := range m.records {
		if r.UserID == userID && r.Version > max {
			max = r.Version
		}
	}
	if max == 0 {
		return "", nil
	}
	return strconv.FormatInt(max, 10), nil
}

// ---------- MemoryStore ----------

func (m *Memory) UpsertMemory(ctx context.Context, item MemoryItem) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.memories[recordKey(item.UserID, "memory", item.ID)] = item
	return nil
}

func (m *Memory) MemoriesByUser(ctx context.Context, userID string, includeDeleted bool) ([]MemoryItem, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []MemoryItem
	for _, it := range m.memories {
		if it.UserID != userID {
			continue
		}
		if it.DeletedAt != nil && !includeDeleted {
			continue
		}
		out = append(out, it)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (m *Memory) DeleteMemory(ctx context.Context, userID, id string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := recordKey(userID, "memory", id)
	it, ok := m.memories[k]
	if !ok {
		return ErrNotFound
	}
	t := at
	it.DeletedAt = &t
	it.UpdatedAt = at
	// 删除必须同时清掉派生索引：留着索引会让已删除的记忆继续出现在检索结果里。
	it.Statement = ""
	it.SourceRef = ""
	m.memories[k] = it
	return nil
}

// ---------- ExportStore ----------

func (m *Memory) Export(ctx context.Context, userID string) (ExportBundle, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	b := ExportBundle{UserID: userID, ExportedAt: m.now()}
	for _, r := range m.records {
		// 导出**包含**墓碑：用户需要知道"这里曾经有过东西"。
		if r.UserID == userID {
			b.Records = append(b.Records, r)
		}
	}
	sort.Slice(b.Records, func(i, j int) bool { return b.Records[i].Version < b.Records[j].Version })
	for _, it := range m.memories {
		if it.UserID == userID {
			b.Memories = append(b.Memories, it)
		}
	}
	sort.Slice(b.Memories, func(i, j int) bool { return b.Memories[i].ID < b.Memories[j].ID })
	for _, d := range m.devices {
		if d.UserID == userID {
			b.Devices = append(b.Devices, d)
		}
	}
	sort.Slice(b.Devices, func(i, j int) bool { return b.Devices[i].ID < b.Devices[j].ID })
	return b, nil
}

// Purge 彻底删除该用户的一切数据。只删自己的：请求里带别人的 ID 也不能越权。
func (m *Memory) Purge(ctx context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, r := range m.records {
		if r.UserID == userID {
			delete(m.records, k)
		}
	}
	for k, it := range m.memories {
		if it.UserID == userID {
			delete(m.memories, k)
		}
	}
	for k, d := range m.devices {
		if d.UserID == userID {
			delete(m.devices, k)
		}
	}
	if u, ok := m.users[userID]; ok {
		t := m.now()
		u.DeletedAt = &t
		u.UpdatedAt = t
		m.users[userID] = u
	}
	return nil
}
