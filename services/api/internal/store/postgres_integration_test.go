//go:build postgres

// 真实 PostgreSQL 集成测试。
//
// 为什么需要单独的构建标签：默认构建刻意不引入任何数据库驱动
// （见 cmd/daycued/cloudsync.go），而 sql.Open 需要一个驱动。
// 把本文件挡在 postgres 标签后面，默认的 go build / go vet / go test
// 仍然零第三方依赖、全绿；只有显式 -tags postgres 时才去连真实数据库。
//
// 环境变量缺失时必须 t.Skip 并说明原因，绝不能悄悄退回内存存储：
// 那样测试会变绿，却没有验证任何持久化行为，属于最危险的假成功。
package store_test

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/jolaaa999/DayCue/services/api/internal/media"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

// testDSNEnv 是集成测试读取的连接串环境变量名。
// 刻意不复用 DAYCUE_DATABASE_URL：本测试会清理库里的数据，绝不能指向开发库或生产库。
const testDSNEnv = "DAYCUE_TEST_DATABASE_URL"

// openTestDB 打开并验证数据库连接。
//
// 分三种情形，处理方式刻意不同：
//  1. 未设置环境变量：跳过，并写明原因与恢复办法 —— 这是本机没有数据库时的正常路径；
//  2. 设置但连不上：直接失败，不跳过 —— 否则「数据库挂了」会被伪装成「跳过」；
//  3. 连得上：返回连接，并在测试结束时关闭。
func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv(testDSNEnv))
	if dsn == "" {
		t.Skip("未设置 DAYCUE_TEST_DATABASE_URL，跳过真实数据库集成测试；用 scripts/db-up.ps1 启动数据库后会打印该变量的值")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		t.Fatalf("连接 %s 指定的数据库失败: %v；先运行 scripts/db-up.ps1 把 daycue-postgres 拉起来", testDSNEnv, err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// ensureSchema 保证集成测试用到的表已存在。
// 每个测试都调用它，而不是依赖迁移测试先跑：go test -run 可以只挑一个测试，
// 那时没有别的测试替它建表。
func ensureSchema(t *testing.T, db *sql.DB) {
	t.Helper()
	if _, err := store.Migrate(context.Background(), db, time.Now); err != nil {
		t.Fatalf("准备数据库结构失败: %v", err)
	}
}

func newPostgres(t *testing.T, db *sql.DB) *store.Postgres {
	t.Helper()
	pg, err := store.NewPostgres(db, func() time.Time { return time.Now().UTC() })
	if err != nil {
		t.Fatalf("构造 Postgres 失败: %v", err)
	}
	return pg
}

// testIDPrefix 由测试名派生一个可读且全局唯一的 ID 前缀。
//
// 为什么要带随机后缀：本测试连的是共享数据库，若同一测试上一轮异常中断后留下了数据，
// 只按测试名派生会让「用户隔离」之类的断言把残留误判成泄漏；随机后缀让每次运行互不干扰。
func testIDPrefix(t *testing.T) string {
	t.Helper()
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatalf("生成随机前缀失败: %v", err)
	}
	name := sanitizeName(t.Name())
	if len(name) > 40 {
		name = name[:40]
	}
	return "it_" + name + "_" + hex.EncodeToString(raw[:])
}

// sanitizeName 把测试名里的非字母数字字符换成下划线，保证前缀只含合法 ID 字符。
func sanitizeName(name string) string {
	var b strings.Builder
	for _, r := range name {
		if (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) {
			b.WriteRune(r)
		} else {
			b.WriteByte(0x5F)
		}
	}
	return b.String()
}

func createTestUser(t *testing.T, pg *store.Postgres, id string) {
	t.Helper()
	now := time.Now().UTC()
	if err := pg.CreateUser(context.Background(), store.User{
		ID: id, Email: id + "@example.test", DisplayName: "集成测试用户",
		PasswordHash: "x", CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("创建测试用户 %s 失败: %v", id, err)
	}
}

// registerCleanup 物理清掉测试产生的行，保证可重复运行。
//
// 用原始 SQL 而不是 store.Purge：Purge 只给账号写墓碑、保留 app_user 行，
// 多轮运行会不断堆积残留账号。这里按 user_id 逐表删除，顺序上先清没有外键的表，
// 再删 app_user（device / media_object / memory_item / proactive_message 依赖 ON DELETE CASCADE）。
func registerCleanup(t *testing.T, db *sql.DB, userIDs ...string) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		for _, id := range userIDs {
			if id == "" {
				continue
			}
			for _, stmt := range []string{
				"DELETE FROM sync_record WHERE user_id = $1",
				"DELETE FROM memory_index WHERE user_id = $1",
				"DELETE FROM media_object WHERE user_id = $1",
				"DELETE FROM memory_item WHERE user_id = $1",
				"DELETE FROM device WHERE user_id = $1",
				"DELETE FROM app_user WHERE id = $1",
			} {
				if _, err := db.ExecContext(ctx, stmt, id); err != nil {
					t.Errorf("清理用户 %s 的数据失败 %s: %v", id, stmt, err)
				}
			}
		}
	})
}

// mustJSON 把测试负载序列化成 JSON 字节，避免在测试里手写带转义的 JSON 字符串。
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("序列化测试负载失败: %v", err)
	}
	return b
}

func countMigrations(t *testing.T, db *sql.DB) int {
	t.Helper()
	var n int
	if err := db.QueryRowContext(context.Background(), "SELECT COUNT(*) FROM schema_migration").Scan(&n); err != nil {
		t.Fatalf("统计 schema_migration 失败: %v", err)
	}
	return n
}

// TestIntegrationMigrateIsIdempotent 验证迁移可重复执行：第二次不应用任何脚本，也不产生重复行。
func TestIntegrationMigrateIsIdempotent(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	if _, err := store.Migrate(ctx, db, time.Now); err != nil {
		t.Fatalf("第一次迁移失败: %v", err)
	}
	before := countMigrations(t, db)

	migrations, err := store.LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移脚本失败: %v", err)
	}
	if before != len(migrations) {
		t.Fatalf("schema_migration 记录数 %d 与迁移脚本数 %d 不一致", before, len(migrations))
	}

	applied, err := store.Migrate(ctx, db, time.Now)
	if err != nil {
		t.Fatalf("第二次迁移失败: %v", err)
	}
	if len(applied) != 0 {
		t.Errorf("第二次迁移不应再应用任何脚本，实际应用了 %v", applied)
	}
	after := countMigrations(t, db)
	if after != before {
		t.Fatalf("迁移必须幂等：schema_migration 计数从 %d 变成 %d", before, after)
	}
}

// TestIntegrationUserIsolation 验证用户 A 写的数据不会被用户 B 看到。
func TestIntegrationUserIsolation(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	userA := prefix + "_a"
	userB := prefix + "_b"
	createTestUser(t, pg, userA)
	createTestUser(t, pg, userB)
	registerCleanup(t, db, userA, userB)

	now := time.Now().UTC()
	entityID := prefix + "_task"
	if _, err := pg.Push(ctx, store.Record{UserID: userA, Type: store.EntityTask, ID: entityID, Payload: mustJSON(t, map[string]string{"title": "A 的任务"})}, 0); err != nil {
		t.Fatalf("A 写入同步记录失败: %v", err)
	}
	devID := prefix + "_dev"
	if err := pg.UpsertDevice(ctx, store.Device{
		ID: devID, UserID: userA, Platform: "ios", Name: "A 的手机",
		Capabilities: map[string]bool{"push": true}, LastSeenAt: now, CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("A 登记设备失败: %v", err)
	}
	memID := prefix + "_mem"
	if err := pg.UpsertMemory(ctx, store.MemoryItem{
		ID: memID, UserID: userA, Category: "preference", Statement: "A 喜欢早上学习",
		Status: "confirmed", SourceKind: "user_statement", Confidence: 0.9, Revision: 1,
		CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("A 写入记忆失败: %v", err)
	}

	// 先证明 A 自己看得见：否则下面「B 看不到」可能只是因为压根没写进去。
	own, ownCursor, err := pg.Pull(ctx, userA, "", 0)
	if err != nil {
		t.Fatalf("A 拉取失败: %v", err)
	}
	if len(own) != 1 {
		t.Fatalf("A 应当看到自己写的 1 条记录，实际 %d 条", len(own))
	}
	if ownCursor == "" {
		t.Fatal("A 有数据时游标不应为空")
	}

	// B 拉取必须为空，游标也必须为空。
	changes, cursor, err := pg.Pull(ctx, userB, "", 0)
	if err != nil {
		t.Fatalf("B 拉取失败: %v", err)
	}
	if len(changes) != 0 {
		t.Fatalf("用户隔离失败：B 看到了 A 的 %d 条同步记录", len(changes))
	}
	if cursor != "" {
		t.Fatalf("B 没有任何记录，游标应为空，实际 %q", cursor)
	}

	// B 用 A 的 ID 查询：必须 ErrNotFound，而不是拿到别人的数据。
	if _, err := pg.DeviceByID(ctx, userB, devID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("B 查询 A 的设备应当 ErrNotFound，实际: %v", err)
	}
	mems, err := pg.MemoriesByUser(ctx, userB, true)
	if err != nil {
		t.Fatalf("B 查询记忆失败: %v", err)
	}
	if len(mems) != 0 {
		t.Fatalf("用户隔离失败：B 看到了 A 的 %d 条记忆", len(mems))
	}
	bundleB, err := pg.Export(ctx, userB)
	if err != nil {
		t.Fatalf("B 导出失败: %v", err)
	}
	if len(bundleB.Records) != 0 || len(bundleB.Memories) != 0 || len(bundleB.Devices) != 0 {
		t.Fatalf("用户隔离失败：B 的导出里出现了 A 的数据 %d/%d/%d", len(bundleB.Records), len(bundleB.Memories), len(bundleB.Devices))
	}
	if c, err := pg.Cursor(ctx, userB); err != nil || c != "" {
		t.Fatalf("B 的游标应为空，实际 %q err=%v", c, err)
	}

	// 反向确认 A 的导出确实包含这三样，证明断言不是空转。
	bundleA, err := pg.Export(ctx, userA)
	if err != nil {
		t.Fatalf("A 导出失败: %v", err)
	}
	if len(bundleA.Records) != 1 || len(bundleA.Memories) != 1 || len(bundleA.Devices) != 1 {
		t.Fatalf("A 的导出应含 1 条记录、1 条记忆、1 台设备，实际 %d/%d/%d", len(bundleA.Records), len(bundleA.Memories), len(bundleA.Devices))
	}
}

// TestIntegrationPushConflictCarriesServerContent 验证用旧版本推送会冲突，
// 且冲突结果里真的带上了服务端当前内容。
func TestIntegrationPushConflictCarriesServerContent(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	user := prefix + "_u"
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	entityID := prefix + "_task"
	first, err := pg.Push(ctx, store.Record{UserID: user, Type: store.EntityTask, ID: entityID, Payload: mustJSON(t, map[string]string{"title": "第一版"})}, 0)
	if err != nil {
		t.Fatalf("首次推送失败: %v", err)
	}
	if first.Version <= 0 {
		t.Fatalf("首次推送应得到正版本号，实际 %d", first.Version)
	}
	second, err := pg.Push(ctx, store.Record{UserID: user, Type: store.EntityTask, ID: entityID, Payload: mustJSON(t, map[string]string{"title": "服务端第二版"})}, first.Version)
	if err != nil {
		t.Fatalf("基于正确版本的第二次推送失败: %v", err)
	}
	if second.Version <= first.Version {
		t.Fatalf("版本必须递增：%d -> %d", first.Version, second.Version)
	}

	// 存储层：用已经过期的 Version 推同一条记录，必须 ErrConflict 且不覆盖服务端数据。
	stale := mustJSON(t, map[string]string{"title": "客户端旧版"})
	if _, err := pg.Push(ctx, store.Record{UserID: user, Type: store.EntityTask, ID: entityID, Payload: stale}, first.Version); !errors.Is(err, store.ErrConflict) {
		t.Fatalf("用旧 Version 推送必须返回 ErrConflict，实际: %v", err)
	}
	cur, _, err := pg.Pull(ctx, user, strconv.FormatInt(first.Version, 10), 0)
	if err != nil {
		t.Fatalf("冲突后拉取失败: %v", err)
	}
	if len(cur) != 1 || cur[0].Record.Version != second.Version {
		t.Fatalf("冲突不得改动服务端数据：期望版本 %d，实际 %+v", second.Version, cur)
	}

	// syncsvc 层：冲突结算结果必须真的带回服务端当前内容，而不是空。
	svc := &syncsvc.Service{Sync: pg, Exporter: pg}
	results, err := svc.Push(ctx, user, []syncsvc.PushItem{{
		Type: store.EntityTask, ID: entityID, BaseVersion: first.Version, Payload: stale,
	}})
	if err != nil {
		t.Fatalf("syncsvc 推送失败: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("应当只有 1 条结算结果，实际 %d 条", len(results))
	}
	r := results[0]
	if r.Outcome != syncsvc.OutcomeConflict {
		t.Fatalf("旧版本推送应结算为 conflict，实际 %s", r.Outcome)
	}
	if r.ServerVersion != second.Version {
		t.Fatalf("冲突结果的服务端版本应为 %d，实际 %d", second.Version, r.ServerVersion)
	}
	if len(r.ServerPayload) == 0 {
		t.Fatal("冲突结果没有带上服务端内容，客户端无法让用户对比两版")
	}
	if r.ServerDeleted {
		t.Fatal("服务端记录并未删除，ServerDeleted 不应为 true")
	}
	var serverContent map[string]any
	if err := json.Unmarshal(r.ServerPayload, &serverContent); err != nil {
		t.Fatalf("冲突带回的服务端内容不是合法 JSON: %v", err)
	}
	if serverContent["title"] != "服务端第二版" {
		t.Fatalf("冲突带回的内容不是服务端当前版本: %s", r.ServerPayload)
	}
}

// TestIntegrationTombstonePropagates 验证删除写墓碑、抬高版本，并能被 Pull 交给客户端。
func TestIntegrationTombstonePropagates(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	user := prefix + "_u"
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	entityID := prefix + "_task"
	rec, err := pg.Push(ctx, store.Record{UserID: user, Type: store.EntityTask, ID: entityID, Payload: mustJSON(t, map[string]string{"title": "将被删除"})}, 0)
	if err != nil {
		t.Fatalf("写入待删除记录失败: %v", err)
	}

	deletedAt := time.Now().UTC()
	tomb, err := pg.Push(ctx, store.Record{UserID: user, Type: store.EntityTask, ID: entityID, DeletedAt: &deletedAt}, rec.Version)
	if err != nil {
		t.Fatalf("写墓碑失败: %v", err)
	}
	if tomb.Version <= rec.Version {
		t.Fatalf("删除必须抬高 Version：%d -> %d", rec.Version, tomb.Version)
	}
	if !tomb.Deleted() {
		t.Fatal("返回的记录应当是墓碑")
	}

	changes, cursor, err := pg.Pull(ctx, user, "", 0)
	if err != nil {
		t.Fatalf("拉取失败: %v", err)
	}
	if len(changes) != 1 {
		t.Fatalf("应当只有 1 条变更，实际 %d 条", len(changes))
	}
	c := changes[0]
	if !c.Tombstone || !c.Record.Deleted() {
		t.Fatalf("Pull 必须把删除作为墓碑交给客户端: %+v", c)
	}
	if c.Record.Version != tomb.Version {
		t.Fatalf("拉到的版本应为 %d，实际 %d", tomb.Version, c.Record.Version)
	}
	if cursor != strconv.FormatInt(tomb.Version, 10) {
		t.Fatalf("游标应推进到墓碑版本 %d，实际 %q", tomb.Version, cursor)
	}
	// 墓碑不应保留原正文：留着正文等于「删了行却还在库里」。
	if len(c.Record.Payload) > 0 && string(c.Record.Payload) != "{}" {
		t.Fatalf("墓碑不应保留正文: %s", c.Record.Payload)
	}

	// 离线设备从删除前的游标重新上线，也必须学到这次删除。
	after, _, err := pg.Pull(ctx, user, strconv.FormatInt(rec.Version, 10), 0)
	if err != nil {
		t.Fatalf("从删除前游标拉取失败: %v", err)
	}
	if len(after) != 1 || !after[0].Tombstone {
		t.Fatalf("从删除前游标应能看到 1 条墓碑，实际 %+v", after)
	}
}

// TestIntegrationPullCursorAdvances 验证游标严格递增，且旧游标不会重复交付已拉过的变更。
func TestIntegrationPullCursorAdvances(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	user := prefix + "_u"
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	ids := []string{prefix + "_t1", prefix + "_t2", prefix + "_t3"}
	versions := make([]int64, 0, len(ids))
	for _, id := range ids {
		rec, err := pg.Push(ctx, store.Record{UserID: user, Type: store.EntityTask, ID: id, Payload: mustJSON(t, map[string]int{"n": 1})}, 0)
		if err != nil {
			t.Fatalf("写入 %s 失败: %v", id, err)
		}
		versions = append(versions, rec.Version)
	}
	for i := 1; i < len(versions); i++ {
		if versions[i] <= versions[i-1] {
			t.Fatalf("同一用户内的版本必须严格递增：%v", versions)
		}
	}

	first, c1, err := pg.Pull(ctx, user, "", 2)
	if err != nil {
		t.Fatalf("首批拉取失败: %v", err)
	}
	if len(first) != 2 {
		t.Fatalf("limit=2 应拉到 2 条，实际 %d 条", len(first))
	}
	if first[0].Record.Version >= first[1].Record.Version {
		t.Fatalf("拉取结果必须按版本升序：%d, %d", first[0].Record.Version, first[1].Record.Version)
	}
	if c1 != strconv.FormatInt(versions[1], 10) {
		t.Fatalf("首批游标应为 %d，实际 %q", versions[1], c1)
	}

	rest, c2, err := pg.Pull(ctx, user, c1, 0)
	if err != nil {
		t.Fatalf("续拉失败: %v", err)
	}
	if len(rest) != 1 || rest[0].Record.Version != versions[2] {
		t.Fatalf("续拉应只剩第 3 条，实际 %+v", rest)
	}
	c1n, err := strconv.ParseInt(c1, 10, 64)
	if err != nil {
		t.Fatalf("游标不是整数: %q", c1)
	}
	c2n, err := strconv.ParseInt(c2, 10, 64)
	if err != nil {
		t.Fatalf("游标不是整数: %q", c2)
	}
	if c2n <= c1n {
		t.Fatalf("游标必须严格递增：%s -> %s", c1, c2)
	}

	// 用旧游标再拉一次，不能重复交付已经拉过的变更。
	again, _, err := pg.Pull(ctx, user, c1, 0)
	if err != nil {
		t.Fatalf("用旧游标拉取失败: %v", err)
	}
	for _, ch := range again {
		if ch.Record.Version <= c1n {
			t.Fatalf("旧游标重复交付了变更 v=%d", ch.Record.Version)
		}
	}

	// 拉到最新之后再用当前游标拉取应当为空，且游标保持不变。
	tail, c3, err := pg.Pull(ctx, user, c2, 0)
	if err != nil {
		t.Fatalf("尾部拉取失败: %v", err)
	}
	if len(tail) != 0 {
		t.Fatalf("拉到最新后不应再有变更，实际 %d 条", len(tail))
	}
	if c3 != c2 {
		t.Fatalf("没有新变更时游标不应变化：%s -> %s", c2, c3)
	}
}

// TestIntegrationDeleteMediaForUserOnly 验证按用户清理媒体元数据，且不误删其他用户的数据。
func TestIntegrationDeleteMediaForUserOnly(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()
	prefix := testIDPrefix(t)
	userA := prefix + "_a"
	userB := prefix + "_b"
	createTestUser(t, pg, userA)
	createTestUser(t, pg, userB)
	registerCleanup(t, db, userA, userB)

	ownerID := prefix + "_task"
	objA := media.Object{ID: prefix + "_med_a1", UserID: userA, OwnerType: "task", OwnerID: ownerID, ContentType: "image/png", ByteSize: 3, SHA256: "aa", StorageKey: "k/a1.png"}
	objA2 := media.Object{ID: prefix + "_med_a2", UserID: userA, OwnerType: "task", OwnerID: ownerID, ContentType: "audio/m4a", ByteSize: 5, SHA256: "bb", StorageKey: "k/a2.m4a"}
	objB := media.Object{ID: prefix + "_med_b1", UserID: userB, OwnerType: "note", OwnerID: prefix + "_note", ContentType: "image/jpeg", ByteSize: 7, SHA256: "cc", StorageKey: "k/b1.jpg"}
	for _, o := range []media.Object{objA, objA2, objB} {
		if err := pg.Insert(ctx, o); err != nil {
			t.Fatalf("登记媒体 %s 失败: %v", o.ID, err)
		}
	}

	removed, err := pg.DeleteAllForUser(ctx, userA)
	if err != nil {
		t.Fatalf("按用户清理媒体失败: %v", err)
	}
	if len(removed) != 2 {
		t.Fatalf("应当只删掉 A 的 2 条媒体元数据，实际 %d 条", len(removed))
	}

	listA, err := pg.ByOwner(ctx, userA, "task", ownerID)
	if err != nil {
		t.Fatalf("查询 A 的媒体失败: %v", err)
	}
	if len(listA) != 0 {
		t.Fatalf("清理后 A 的媒体元数据必须为空，实际还剩 %d 条", len(listA))
	}
	if _, err := pg.ByID(ctx, userA, objA.ID); !errors.Is(err, media.ErrNotFound) {
		t.Fatalf("清理后按 ID 查 A 的媒体应当 ErrNotFound，实际: %v", err)
	}

	keptB, err := pg.ByID(ctx, userB, objB.ID)
	if err != nil {
		t.Fatalf("按用户清理媒体误删了其他用户的数据: %v", err)
	}
	if keptB.ID != objB.ID || keptB.UserID != userB {
		t.Fatalf("B 的媒体元数据被改动了: %+v", keptB)
	}
}
