package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

var (
	// ErrForeign 表示记录存在但属于其他用户。
	//
	// 内存实现按 (userID, id) 复合键存放，天然撞不到别人的记录；PostgreSQL 的
	// device / memory_item 主键只有 id，所以"这个 ID 被别人占着"必须显式报出来，
	// 不能用覆盖写蒙混过去。上层一律映射成 404，不得泄漏存在性。
	ErrForeign = errors.New("store: 资源属于其他用户")

	// errEmailTaken 与内存实现的错误文案保持一致，方便上层除了错误类型之外还能对齐提示。
	errEmailTaken = errors.New("store: 邮箱已被占用")
)

// Postgres 是 UserStore / SyncStore / MemoryStore / ExportStore 的 PostgreSQL 实现。
//
// 设计取舍：
//   - 本包**不 import 任何数据库驱动**：驱动由组装层以 *sql.DB 的形式注入。
//     这样 store 保持零第三方依赖，将来换 lib/pq / pgx / 云厂商代理都不用改这里。
//   - 同步写入必须在**同一事务**里完成"读现值 → 判版本 → 取新版本 → 写回"，
//     读取用 SELECT ... FOR UPDATE 锁住那一行。只靠一条 UPDATE ... WHERE version = $base
//     虽然也原子，但无法区分"版本不匹配（交给用户处理）"与"记录不存在（让客户端重拉）"
//     这两种完全不同的结局；而不带事务的读-判-写会在并发下丢更新。
type Postgres struct {
	db  *sql.DB
	now func() time.Time
}

// 编译期确认四个接口都被实现；接口一旦变更这里会直接编译失败，而不是等运行时。
var (
	_ UserStore   = (*Postgres)(nil)
	_ SyncStore   = (*Postgres)(nil)
	_ MemoryStore = (*Postgres)(nil)
	_ ExportStore = (*Postgres)(nil)
)

// NewPostgres 构造 PostgreSQL 实现。
//
// 刻意不做 Ping：构造不该依赖网络，连接可用性属于调用方（组装层）的职责。
// now 为空时使用 time.Now。
func NewPostgres(db *sql.DB, now func() time.Time) (*Postgres, error) {
	if db == nil {
		return nil, errors.New("store: db 不能为空")
	}
	if now == nil {
		now = time.Now
	}
	return &Postgres{db: db, now: now}, nil
}

// ---------- SQL 语句清单 ----------
//
// 下面这些常量是**执行器真正使用的**语句，Statement 清单只是把它们登记出来，
// 好让"每条用户数据查询都必须带 user_id"这条硬约束在没有数据库的机器上也能被
// 自动断言（见 postgres_test.go）。语句只写一份，杜绝清单与实现漂移。

const (
	// 账号域：app_user 自身以 id 为主键，没有 user_id 列，属于系统级查询。
	sqlUserCountLiveEmail = `SELECT id FROM app_user WHERE lower(email) = lower($1) AND deleted_at IS NULL`
	sqlUserInsert         = `INSERT INTO app_user (id, email, display_name, password_hash, created_at, updated_at, deleted_at) VALUES ($1, $2, $3, $4, $5, $6, $7)`
	sqlUserByEmail        = `SELECT id, email, display_name, password_hash, created_at, updated_at, deleted_at FROM app_user WHERE lower(email) = lower($1) AND deleted_at IS NULL`
	sqlUserByID           = `SELECT id, email, display_name, password_hash, created_at, updated_at, deleted_at FROM app_user WHERE id = $1 AND deleted_at IS NULL`
	sqlUserExists         = `SELECT 1 FROM app_user WHERE id = $1`
	// 不带 deleted_at IS NULL：与内存实现一致地"幂等删号"，重复删不报不存在。
	sqlUserSoftDelete = `UPDATE app_user SET deleted_at = $2, updated_at = $2 WHERE id = $1`

	// 设备域。
	sqlDeviceUpsert = `INSERT INTO device (id, user_id, platform, name, capabilities_json, push_token, last_seen_at, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT (id) DO UPDATE SET platform = EXCLUDED.platform, name = EXCLUDED.name, capabilities_json = EXCLUDED.capabilities_json, push_token = EXCLUDED.push_token, last_seen_at = EXCLUDED.last_seen_at, updated_at = EXCLUDED.updated_at WHERE device.user_id = EXCLUDED.user_id RETURNING id`
	sqlDeviceByID   = `SELECT id, user_id, platform, name, capabilities_json, push_token, last_seen_at, created_at, updated_at FROM device WHERE user_id = $1 AND id = $2`
	sqlDeviceList   = `SELECT id, user_id, platform, name, capabilities_json, push_token, last_seen_at, created_at, updated_at FROM device WHERE user_id = $1 ORDER BY id ASC`
	sqlDeviceDelete = `DELETE FROM device WHERE user_id = $1 AND id = $2`

	// 同步域。
	sqlSyncSelectForUpdate = `SELECT version, deleted_at FROM sync_record WHERE user_id = $1 AND entity_type = $2 AND entity_id = $3 FOR UPDATE`
	sqlSyncNextVersion     = `SELECT nextval('sync_version_seq')`
	sqlSyncUpsert          = `INSERT INTO sync_record (user_id, entity_type, entity_id, version, payload, updated_at, deleted_at) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (user_id, entity_type, entity_id) DO UPDATE SET version = EXCLUDED.version, payload = EXCLUDED.payload, updated_at = EXCLUDED.updated_at, deleted_at = EXCLUDED.deleted_at`
	sqlSyncPullLimited     = `SELECT user_id, entity_type, entity_id, version, payload, updated_at, deleted_at FROM sync_record WHERE user_id = $1 AND version > $2 ORDER BY version ASC LIMIT $3`
	sqlSyncPullAll         = `SELECT user_id, entity_type, entity_id, version, payload, updated_at, deleted_at FROM sync_record WHERE user_id = $1 AND version > $2 ORDER BY version ASC`
	sqlSyncCursor          = `SELECT COALESCE(MAX(version), 0) FROM sync_record WHERE user_id = $1`

	// 记忆域。DO UPDATE 上的 WHERE memory_item.user_id = EXCLUDED.user_id 用来挡住"拿别人的 id 覆盖写"。
	sqlMemoryUpsert      = `INSERT INTO memory_item (id, user_id, category, statement, status, source_kind, confidence, source_ref, revision, effective_to, created_at, updated_at, deleted_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) ON CONFLICT (id) DO UPDATE SET category = EXCLUDED.category, statement = EXCLUDED.statement, status = EXCLUDED.status, source_kind = EXCLUDED.source_kind, confidence = EXCLUDED.confidence, source_ref = EXCLUDED.source_ref, revision = EXCLUDED.revision, effective_to = EXCLUDED.effective_to, updated_at = EXCLUDED.updated_at, deleted_at = EXCLUDED.deleted_at WHERE memory_item.user_id = EXCLUDED.user_id RETURNING id`
	sqlMemoryListLive    = `SELECT id, user_id, category, statement, status, source_kind, confidence, source_ref, revision, effective_to, created_at, updated_at, deleted_at FROM memory_item WHERE user_id = $1 AND deleted_at IS NULL ORDER BY id ASC`
	sqlMemoryListAll     = `SELECT id, user_id, category, statement, status, source_kind, confidence, source_ref, revision, effective_to, created_at, updated_at, deleted_at FROM memory_item WHERE user_id = $1 ORDER BY id ASC`
	sqlMemoryDelete      = `UPDATE memory_item SET deleted_at = $3, updated_at = $3, statement = '', source_ref = '' WHERE user_id = $1 AND id = $2`
	sqlMemoryIndexDelete = `DELETE FROM memory_index WHERE user_id = $1 AND memory_id = $2`

	// 导出域。
	sqlExportRecords  = `SELECT user_id, entity_type, entity_id, version, payload, updated_at, deleted_at FROM sync_record WHERE user_id = $1 ORDER BY version ASC`
	sqlExportMemories = `SELECT id, user_id, category, statement, status, source_kind, confidence, source_ref, revision, effective_to, created_at, updated_at, deleted_at FROM memory_item WHERE user_id = $1 ORDER BY id ASC`
	sqlExportDevices  = `SELECT id, user_id, platform, name, capabilities_json, push_token, last_seen_at, created_at, updated_at FROM device WHERE user_id = $1 ORDER BY id ASC`

	// 彻底删除域。逐表按 user_id 删，不出现无条件的 DELETE。
	sqlPurgeSyncRecords = `DELETE FROM sync_record WHERE user_id = $1`
	sqlPurgeMemoryIndex = `DELETE FROM memory_index WHERE user_id = $1`
	sqlPurgeMemories    = `DELETE FROM memory_item WHERE user_id = $1`
	sqlPurgeMedia       = `DELETE FROM media_object WHERE user_id = $1`
	sqlPurgeDevices     = `DELETE FROM device WHERE user_id = $1`

	// 媒体元数据域（实现在 postgres_media.go）。
	sqlMediaInsert        = `INSERT INTO media_object (id, user_id, owner_type, owner_id, content_type, byte_size, sha256, storage_key, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`
	sqlMediaByID          = `SELECT id, user_id, owner_type, owner_id, content_type, byte_size, sha256, storage_key, created_at FROM media_object WHERE user_id = $1 AND id = $2`
	sqlMediaByOwner       = `SELECT id, user_id, owner_type, owner_id, content_type, byte_size, sha256, storage_key, created_at FROM media_object WHERE user_id = $1 AND owner_type = $2 AND owner_id = $3 ORDER BY id ASC`
	sqlMediaDelete        = `DELETE FROM media_object WHERE user_id = $1 AND id = $2`
	sqlMediaDeleteByOwner = `DELETE FROM media_object WHERE user_id = $1 AND owner_type = $2 AND owner_id = $3 RETURNING id, user_id, owner_type, owner_id, content_type, byte_size, sha256, storage_key, created_at`
)

// Statement 是一条登记在册的 SQL 及其隔离属性。
type Statement struct {
	// Name 是稳定标识，仅用于测试报错与排查。
	Name string
	// SQL 是执行器真正使用的语句文本。
	SQL string
	// UserScoped 为 true 表示这条语句读写用户数据，必须带 user_id 过滤；
	// 为 false 的只允许是账号表（app_user）或取全局版本号这类系统级语句。
	UserScoped bool
}

// sqlStatements 是全部 SQL 的登记表，供 SQLStatements 导出。
var sqlStatements = []Statement{
	{"user.count_live_email", sqlUserCountLiveEmail, false},
	{"user.insert", sqlUserInsert, false},
	{"user.by_email", sqlUserByEmail, false},
	{"user.by_id", sqlUserByID, false},
	{"user.exists", sqlUserExists, false},
	{"user.soft_delete", sqlUserSoftDelete, false},

	{"device.upsert", sqlDeviceUpsert, true},
	{"device.by_id", sqlDeviceByID, true},
	{"device.list", sqlDeviceList, true},
	{"device.delete", sqlDeviceDelete, true},

	{"sync.select_for_update", sqlSyncSelectForUpdate, true},
	{"sync.next_version", sqlSyncNextVersion, false},
	{"sync.upsert", sqlSyncUpsert, true},
	{"sync.pull_limited", sqlSyncPullLimited, true},
	{"sync.pull_all", sqlSyncPullAll, true},
	{"sync.cursor", sqlSyncCursor, true},

	{"memory.upsert", sqlMemoryUpsert, true},
	{"memory.list_live", sqlMemoryListLive, true},
	{"memory.list_all", sqlMemoryListAll, true},
	{"memory.delete", sqlMemoryDelete, true},
	{"memory_index.delete_by_memory", sqlMemoryIndexDelete, true},

	{"export.records", sqlExportRecords, true},
	{"export.memories", sqlExportMemories, true},
	{"export.devices", sqlExportDevices, true},

	{"purge.sync_records", sqlPurgeSyncRecords, true},
	{"purge.memory_index", sqlPurgeMemoryIndex, true},
	{"purge.memories", sqlPurgeMemories, true},
	{"purge.media", sqlPurgeMedia, true},
	{"purge.devices", sqlPurgeDevices, true},

	{"media.insert", sqlMediaInsert, true},
	{"media.by_id", sqlMediaByID, true},
	{"media.by_owner", sqlMediaByOwner, true},
	{"media.delete", sqlMediaDelete, true},
	{"media.delete_by_owner", sqlMediaDeleteByOwner, true},
}

// SQLStatements 返回登记在册的 SQL 清单的副本。
//
// 返回副本而不是切片本身：调用方（测试或排查工具）不该有能力改动执行器的语句。
func SQLStatements() []Statement {
	return append([]Statement(nil), sqlStatements...)
}

// ---------- 行扫描辅助 ----------

// rowScanner 抽象 *sql.Row 与 *sql.Rows 的共同能力，避免为两者各写一份扫描代码。
type rowScanner interface {
	Scan(dest ...any) error
}

func scanUser(s rowScanner) (User, error) {
	var (
		u         User
		deletedAt sql.NullTime
	)
	if err := s.Scan(&u.ID, &u.Email, &u.DisplayName, &u.PasswordHash, &u.CreatedAt, &u.UpdatedAt, &deletedAt); err != nil {
		return User{}, err
	}
	if deletedAt.Valid {
		t := deletedAt.Time
		u.DeletedAt = &t
	}
	return u, nil
}

func scanDevice(s rowScanner) (Device, error) {
	var (
		d        Device
		caps     []byte
		lastSeen sql.NullTime
	)
	if err := s.Scan(&d.ID, &d.UserID, &d.Platform, &d.Name, &caps, &d.PushToken, &lastSeen, &d.CreatedAt, &d.UpdatedAt); err != nil {
		return Device{}, err
	}
	d.Capabilities = map[string]bool{}
	if len(caps) > 0 {
		if err := json.Unmarshal(caps, &d.Capabilities); err != nil {
			return Device{}, fmt.Errorf("store: 设备能力字段不是合法 JSON: %w", err)
		}
	}
	if lastSeen.Valid {
		d.LastSeenAt = lastSeen.Time
	}
	return d, nil
}

func scanRecord(s rowScanner) (Record, error) {
	var (
		rec       Record
		etype     string
		deletedAt sql.NullTime
	)
	if err := s.Scan(&rec.UserID, &etype, &rec.ID, &rec.Version, &rec.Payload, &rec.UpdatedAt, &deletedAt); err != nil {
		return Record{}, err
	}
	rec.Type = EntityType(etype)
	if deletedAt.Valid {
		t := deletedAt.Time
		rec.DeletedAt = &t
	}
	return rec, nil
}

func scanMemory(s rowScanner) (MemoryItem, error) {
	var (
		m           MemoryItem
		effectiveTo sql.NullTime
		deletedAt   sql.NullTime
	)
	if err := s.Scan(&m.ID, &m.UserID, &m.Category, &m.Statement, &m.Status, &m.SourceKind,
		&m.Confidence, &m.SourceRef, &m.Revision, &effectiveTo, &m.CreatedAt, &m.UpdatedAt, &deletedAt); err != nil {
		return MemoryItem{}, err
	}
	if effectiveTo.Valid {
		t := effectiveTo.Time
		m.EffectiveTo = &t
	}
	if deletedAt.Valid {
		t := deletedAt.Time
		m.DeletedAt = &t
	}
	return m, nil
}

// notFound 把 database/sql 的"无行"翻译成 store.ErrNotFound。
// 只有这一种情况才算不存在：查询失败必须原样上报，否则同步会把故障当成删除。
func notFound(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// ---------- UserStore ----------

// CreateUser 新建账号。
func (p *Postgres) CreateUser(ctx context.Context, u User) error {
	if strings.TrimSpace(u.ID) == "" {
		return errors.New("store: 用户 ID 不能为空")
	}
	if strings.TrimSpace(u.Email) == "" {
		return errors.New("store: 邮箱不能为空")
	}
	// 先查后插，是为了给出与内存实现一致的中文错误；真正的唯一性由部分唯一索引
	// uq_app_user_email_live 兜底，并发下也不会建出两个同邮箱账号。
	live, err := p.UserByEmail(ctx, u.Email)
	switch {
	case err == nil && live.ID != "":
		return errEmailTaken
	case err != nil && !errors.Is(err, ErrNotFound):
		return err
	}

	createdAt := u.CreatedAt
	if createdAt.IsZero() {
		createdAt = p.now()
	}
	updatedAt := u.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = createdAt
	}
	var deletedAt any
	if u.DeletedAt != nil {
		deletedAt = u.DeletedAt.UTC()
	}
	if _, err := p.db.ExecContext(ctx, sqlUserInsert,
		u.ID, u.Email, u.DisplayName, u.PasswordHash, createdAt.UTC(), updatedAt.UTC(), deletedAt); err != nil {
		return fmt.Errorf("store: 创建用户失败: %w", err)
	}
	return nil
}

// UserByEmail 按邮箱查未删除账号，大小写不敏感。
func (p *Postgres) UserByEmail(ctx context.Context, email string) (User, error) {
	u, err := scanUser(p.db.QueryRowContext(ctx, sqlUserByEmail, email))
	if err != nil {
		return User{}, notFound(err)
	}
	return u, nil
}

// UserByID 按 ID 查未删除账号。
func (p *Postgres) UserByID(ctx context.Context, id string) (User, error) {
	u, err := scanUser(p.db.QueryRowContext(ctx, sqlUserByID, id))
	if err != nil {
		return User{}, notFound(err)
	}
	return u, nil
}

// SoftDeleteUser 写账号墓碑。已删除的账号再删一次不算错（与内存实现一致）。
func (p *Postgres) SoftDeleteUser(ctx context.Context, id string, at time.Time) error {
	res, err := p.db.ExecContext(ctx, sqlUserSoftDelete, id, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 删除用户失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取删除结果失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// UpsertDevice 登记或更新设备。
//
// 用 INSERT ... ON CONFLICT (id) DO UPDATE ... WHERE device.user_id = EXCLUDED.user_id
// 一条语句完成"别人的 ID 绝不能被我覆盖"：冲突行属于他人时 WHERE 不成立，
// 既不插入也不更新，RETURNING 无行，于是报 ErrForeign。
func (p *Postgres) UpsertDevice(ctx context.Context, d Device) error {
	var exists int
	if err := p.db.QueryRowContext(ctx, sqlUserExists, d.UserID).Scan(&exists); err != nil {
		return notFound(err)
	}
	caps := []byte("{}")
	if len(d.Capabilities) > 0 {
		var err error
		caps, err = json.Marshal(d.Capabilities)
		if err != nil {
			return fmt.Errorf("store: 序列化设备能力失败: %w", err)
		}
	}
	var lastSeen any
	if !d.LastSeenAt.IsZero() {
		lastSeen = d.LastSeenAt.UTC()
	}
	// JSONB 参数传字符串而不是 []byte：lib/pq 会把 []byte 当 bytea 发，写 jsonb 列会直接报类型错误。
	var id string
	err := p.db.QueryRowContext(ctx, sqlDeviceUpsert,
		d.ID, d.UserID, d.Platform, d.Name, string(caps), d.PushToken, lastSeen,
		d.CreatedAt.UTC(), d.UpdatedAt.UTC()).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrForeign
		}
		return fmt.Errorf("store: 写设备失败: %w", err)
	}
	return nil
}

// DeviceByID 按 (userID, id) 查设备。带 user_id 是硬性隔离要求。
func (p *Postgres) DeviceByID(ctx context.Context, userID, id string) (Device, error) {
	d, err := scanDevice(p.db.QueryRowContext(ctx, sqlDeviceByID, userID, id))
	if err != nil {
		return Device{}, notFound(err)
	}
	return d, nil
}

// DevicesByUser 列出用户全部设备，按 ID 排序保证结果稳定。
func (p *Postgres) DevicesByUser(ctx context.Context, userID string) ([]Device, error) {
	rows, err := p.db.QueryContext(ctx, sqlDeviceList, userID)
	if err != nil {
		return nil, fmt.Errorf("store: 查询设备列表失败: %w", err)
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 扫描设备失败: %w", err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历设备失败: %w", err)
	}
	return out, nil
}

// DeleteDevice 删除设备。删不到（包括别人的设备）返回 ErrNotFound。
func (p *Postgres) DeleteDevice(ctx context.Context, userID, id string) error {
	res, err := p.db.ExecContext(ctx, sqlDeviceDelete, userID, id)
	if err != nil {
		return fmt.Errorf("store: 删除设备失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取删除结果失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ---------- SyncStore ----------

// normalizePayload 把空负载统一成 '{}'。
//
// sync_record.payload 是 NOT NULL 的 JSONB：墓碑在协议里本来就不带内容（syncsvc 会置空），
// 直接写 NULL 会违反约束；同时这里顺手挡掉非法 JSON，避免 DB 层抛出难以归因的错误。
func normalizePayload(payload []byte) ([]byte, error) {
	if len(payload) == 0 {
		return []byte("{}"), nil
	}
	if !json.Valid(payload) {
		return nil, errors.New("store: 同步负载不是合法 JSON")
	}
	return payload, nil
}

// Push 写入一条同步记录。
//
// 事务内顺序：SELECT ... FOR UPDATE 锁行 → 判版本 → nextval 取新版本 → UPSERT → 提交。
// 锁行保证并发下后到的事务会等到前一个提交后再读，从而读到新版本并如实报冲突，
// 而不是两个事务都基于旧版本写、后者覆盖前者。
func (p *Postgres) Push(ctx context.Context, rec Record, baseVersion int64) (Record, error) {
	if baseVersion < 0 {
		return Record{}, errors.New("store: 基准版本不能为负")
	}
	payload, err := normalizePayload(rec.Payload)
	if err != nil {
		return Record{}, err
	}

	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return Record{}, fmt.Errorf("store: 开启事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var (
		curVersion int64
		curDeleted sql.NullTime
	)
	switch err := tx.QueryRowContext(ctx, sqlSyncSelectForUpdate,
		rec.UserID, string(rec.Type), rec.ID).Scan(&curVersion, &curDeleted); {
	case errors.Is(err, sql.ErrNoRows):
		// 只有"新增"（baseVersion==0）才允许库里没有；否则客户端基于的版本已经不存在了。
		if baseVersion != 0 {
			return Record{}, ErrNotFound
		}
	case err != nil:
		return Record{}, fmt.Errorf("store: 读取当前版本失败: %w", err)
	default:
		if baseVersion == 0 {
			// 已有未删除记录时再声称"新增"，说明两端认知已经分叉。
			if !curDeleted.Valid {
				return Record{}, ErrConflict
			}
		} else if curVersion != baseVersion {
			return Record{}, ErrConflict
		}
	}

	var next int64
	if err := tx.QueryRowContext(ctx, sqlSyncNextVersion).Scan(&next); err != nil {
		return Record{}, fmt.Errorf("store: 取新版本号失败: %w", err)
	}

	updatedAt := rec.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = p.now()
	}
	updatedAt = updatedAt.UTC()
	var deletedAt any
	var deletedAtPtr *time.Time
	if rec.DeletedAt != nil {
		t := rec.DeletedAt.UTC()
		deletedAt = t
		deletedAtPtr = &t
	}
	if _, err := tx.ExecContext(ctx, sqlSyncUpsert,
		rec.UserID, string(rec.Type), rec.ID, next, string(payload), updatedAt, deletedAt); err != nil {
		return Record{}, fmt.Errorf("store: 写同步记录失败: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return Record{}, fmt.Errorf("store: 提交事务失败: %w", err)
	}

	return Record{
		UserID:    rec.UserID,
		Type:      rec.Type,
		ID:        rec.ID,
		Version:   next,
		UpdatedAt: updatedAt,
		DeletedAt: deletedAtPtr,
		Payload:   payload,
	}, nil
}

// Pull 返回 after 之后的变更（含墓碑），按 version 升序。
//
// 游标解析失败必须报错：把坏游标当空游标会重放整份快照，或者更糟——被上层当成
// "服务端没有变更"，让客户端误以为本地数据仍然有效。
func (p *Postgres) Pull(ctx context.Context, userID string, after string, limit int) ([]Change, string, error) {
	from := int64(0)
	if after != "" {
		v, err := strconv.ParseInt(after, 10, 64)
		if err != nil {
			return nil, "", fmt.Errorf("store: 非法游标 %q: %w", after, err)
		}
		from = v
	}

	query := sqlSyncPullAll
	args := []any{userID, from}
	if limit > 0 {
		query = sqlSyncPullLimited
		args = append(args, limit)
	}
	rows, err := p.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, "", fmt.Errorf("store: 拉取变更失败: %w", err)
	}
	defer rows.Close()

	var changes []Change
	cursor := after
	for rows.Next() {
		rec, err := scanRecord(rows)
		if err != nil {
			return nil, "", fmt.Errorf("store: 扫描同步记录失败: %w", err)
		}
		changes = append(changes, Change{Record: rec, Tombstone: rec.Deleted()})
		cursor = strconv.FormatInt(rec.Version, 10)
	}
	if err := rows.Err(); err != nil {
		return nil, "", fmt.Errorf("store: 遍历同步记录失败: %w", err)
	}
	return changes, cursor, nil
}

// Cursor 返回该用户当前的同步游标；没有任何记录时返回空串。
func (p *Postgres) Cursor(ctx context.Context, userID string) (string, error) {
	var max int64
	if err := p.db.QueryRowContext(ctx, sqlSyncCursor, userID).Scan(&max); err != nil {
		return "", fmt.Errorf("store: 读取游标失败: %w", err)
	}
	if max == 0 {
		return "", nil
	}
	return strconv.FormatInt(max, 10), nil
}

// ---------- MemoryStore ----------

// UpsertMemory 写入记忆。
//
// 与设备同理：主键只有 id，必须靠 DO UPDATE ... WHERE memory_item.user_id = EXCLUDED.user_id
// 挡住跨用户覆盖；冲突行属于他人时 RETURNING 无行，报 ErrForeign。
func (p *Postgres) UpsertMemory(ctx context.Context, m MemoryItem) error {
	var effectiveTo any
	if m.EffectiveTo != nil {
		effectiveTo = m.EffectiveTo.UTC()
	}
	var deletedAt any
	if m.DeletedAt != nil {
		deletedAt = m.DeletedAt.UTC()
	}
	var id string
	err := p.db.QueryRowContext(ctx, sqlMemoryUpsert,
		m.ID, m.UserID, m.Category, m.Statement, m.Status, m.SourceKind, m.Confidence,
		m.SourceRef, m.Revision, effectiveTo, m.CreatedAt.UTC(), m.UpdatedAt.UTC(), deletedAt).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrForeign
		}
		return fmt.Errorf("store: 写记忆失败: %w", err)
	}
	return nil
}

// MemoriesByUser 列出用户的记忆；includeDeleted 决定是否包含已删除的。
func (p *Postgres) MemoriesByUser(ctx context.Context, userID string, includeDeleted bool) ([]MemoryItem, error) {
	query := sqlMemoryListLive
	if includeDeleted {
		query = sqlMemoryListAll
	}
	rows, err := p.db.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("store: 查询记忆失败: %w", err)
	}
	defer rows.Close()
	var out []MemoryItem
	for rows.Next() {
		m, err := scanMemory(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 扫描记忆失败: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历记忆失败: %w", err)
	}
	return out, nil
}

// DeleteMemory 写记忆墓碑，并清空正文与派生索引。
//
// 两件事必须在同一事务：只删正文不删索引，已删除的内容仍会出现在检索结果里，
// 用户以为"忘了"，实际数据还在被召回。
func (p *Postgres) DeleteMemory(ctx context.Context, userID, id string, at time.Time) error {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("store: 开启事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.ExecContext(ctx, sqlMemoryDelete, userID, id, at.UTC())
	if err != nil {
		return fmt.Errorf("store: 删除记忆失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取删除结果失败: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, sqlMemoryIndexDelete, userID, id); err != nil {
		return fmt.Errorf("store: 清理记忆索引失败: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: 提交事务失败: %w", err)
	}
	return nil
}

// ---------- ExportStore ----------

// Export 导出用户全部数据（**包含墓碑**）。
func (p *Postgres) Export(ctx context.Context, userID string) (ExportBundle, error) {
	bundle := ExportBundle{UserID: userID, ExportedAt: p.now().UTC()}

	records, err := p.queryRecords(ctx, sqlExportRecords, userID)
	if err != nil {
		return ExportBundle{}, err
	}
	bundle.Records = records

	memories, err := p.queryMemories(ctx, sqlExportMemories, userID)
	if err != nil {
		return ExportBundle{}, err
	}
	bundle.Memories = memories

	devices, err := p.DevicesByUser(ctx, userID)
	if err != nil {
		return ExportBundle{}, err
	}
	bundle.Devices = devices

	return bundle, nil
}

func (p *Postgres) queryRecords(ctx context.Context, query, userID string) ([]Record, error) {
	rows, err := p.db.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("store: 导出同步记录失败: %w", err)
	}
	defer rows.Close()
	var out []Record
	for rows.Next() {
		rec, err := scanRecord(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 扫描同步记录失败: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历同步记录失败: %w", err)
	}
	return out, nil
}

func (p *Postgres) queryMemories(ctx context.Context, query, userID string) ([]MemoryItem, error) {
	rows, err := p.db.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("store: 导出记忆失败: %w", err)
	}
	defer rows.Close()
	var out []MemoryItem
	for rows.Next() {
		m, err := scanMemory(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 扫描记忆失败: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历记忆失败: %w", err)
	}
	return out, nil
}

// Purge 彻底删除该用户的一切数据。
//
// 每条 DELETE 都带 user_id：请求里带着别人的 ID 也删不掉别人的数据。
// 账号行只写墓碑而不是物理删除，这样"删号后可用同一邮箱重新注册"才能成立
// （唯一索引 uq_app_user_email_live 只约束 deleted_at IS NULL 的行）。
func (p *Postgres) Purge(ctx context.Context, userID string) error {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("store: 开启事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	for _, stmt := range []string{
		sqlPurgeSyncRecords,
		sqlPurgeMemoryIndex,
		sqlPurgeMemories,
		sqlPurgeMedia,
		sqlPurgeDevices,
	} {
		if _, err := tx.ExecContext(ctx, stmt, userID); err != nil {
			return fmt.Errorf("store: 清理用户数据失败: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, sqlUserSoftDelete, userID, p.now().UTC()); err != nil {
		return fmt.Errorf("store: 删除账号失败: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: 提交事务失败: %w", err)
	}
	return nil
}
