//go:build postgres

// 真实 PostgreSQL 上的迁移验证。
//
// 为什么用隔离 schema 而不是直接往 public 上灌：
//   - schema_migration 和各个数据表都在 public 里，其他集成测试早已把它们建好；
//     在 public 上根本构造不出"只应用了前 N 个迁移"的旧库，因为表已经存在，
//     CREATE TABLE IF NOT EXISTS 会直接跳过，测出来的是"结构本来就在"。
//   - 每个用例建一个独立 schema，并让连接的 search_path 只指向它，于是"旧库"
//     从空结构开始，升级路径被测的是真实 SQL；用完 DROP SCHEMA ... CASCADE，
//     不碰 public 里的任何数据。
//
// 环境变量缺失时由 openTestDB 统一 t.Skip 并打印原因，绝不退回内存存储。
package store_test

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// isolatedSchemaDB 建一个只属于本测试的 schema，并返回 search_path 指向它的连接。
//
// 用 search_path 而不是给 SQL 加表名前缀：store 里的语句是写死的，只有让数据库
// 自己去解析不带限定名的表名，验证的才是生产环境真正执行的那条路径。
func isolatedSchemaDB(t *testing.T, admin *sql.DB) (*sql.DB, string) {
	t.Helper()
	schema := "it_mig_" + schemaSuffix(t)
	if _, err := admin.ExecContext(context.Background(), "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("创建隔离 schema %s 失败: %v", schema, err)
	}
	// 先注册"删 schema"、再注册"关连接"，t.Cleanup 是 LIFO：连接先关，schema 后删。
	t.Cleanup(func() {
		if _, err := admin.ExecContext(context.Background(), "DROP SCHEMA IF EXISTS "+schema+" CASCADE"); err != nil {
			t.Errorf("清理隔离 schema %s 失败: %v", schema, err)
		}
	})

	dsn := strings.TrimSpace(os.Getenv(testDSNEnv))
	if dsn == "" {
		// openTestDB 已经确认过 DSN 非空，这里为空只可能是环境被中途改掉；
		// 明确失败而不是退到默认 search_path，否则会写进 public。
		t.Fatalf("%s 在测试中途变为空，无法定位隔离 schema", testDSNEnv)
	}
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	db, err := sql.Open("pgx", dsn+sep+"search_path="+schema)
	if err != nil {
		t.Fatalf("打开隔离 schema 连接失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.PingContext(context.Background()); err != nil {
		t.Fatalf("连接隔离 schema %s 失败: %v", schema, err)
	}
	return db, schema
}

// schemaSuffix 生成 schema 名的随机后缀，保证可重复运行、多轮不打架。
func schemaSuffix(t *testing.T) string {
	t.Helper()
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatalf("生成 schema 随机后缀失败: %v", err)
	}
	return hex.EncodeToString(raw[:])
}

// applyMigrationsPrefix 把前若干个迁移当作"这个库以前已经正常应用过"。
//
// 与 store.Migrate 一样逐脚本独立事务：脚本与版本记录要么一起生效、要么一起没有，
// 否则构造出来的"旧库"本身就是坏状态，后面的升级断言没有意义。
func applyMigrationsPrefix(t *testing.T, db *sql.DB, ms []store.Migration) {
	t.Helper()
	ctx := context.Background()
	for _, m := range ms {
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatalf("旧库应用迁移 %d 开启事务失败: %v", m.Version, err)
		}
		if _, err := tx.ExecContext(ctx, m.SQL); err != nil {
			_ = tx.Rollback()
			t.Fatalf("旧库应用迁移 %d (%s) 失败: %v", m.Version, m.Name, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migration (version, applied_at) VALUES ($1, $2)`,
			m.Version, time.Now().UTC()); err != nil {
			_ = tx.Rollback()
			t.Fatalf("旧库记录迁移版本 %d 失败: %v", m.Version, err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatalf("旧库提交迁移 %d 失败: %v", m.Version, err)
		}
	}
}

func migrationVersions(t *testing.T, db *sql.DB) []int {
	t.Helper()
	rows, err := db.QueryContext(context.Background(), `SELECT version FROM schema_migration ORDER BY version`)
	if err != nil {
		t.Fatalf("查询迁移版本失败: %v", err)
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			t.Fatalf("扫描迁移版本失败: %v", err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("遍历迁移版本失败: %v", err)
	}
	return out
}

// migrationRecord 是一条 schema_migration 记录，用来比对重复执行前后是否完全一致。
type migrationRecord struct {
	version   int
	appliedAt time.Time
}

func migrationRows(t *testing.T, db *sql.DB) []migrationRecord {
	t.Helper()
	rows, err := db.QueryContext(context.Background(), `SELECT version, applied_at FROM schema_migration ORDER BY version`)
	if err != nil {
		t.Fatalf("查询迁移记录失败: %v", err)
	}
	defer rows.Close()
	var out []migrationRecord
	for rows.Next() {
		var r migrationRecord
		if err := rows.Scan(&r.version, &r.appliedAt); err != nil {
			t.Fatalf("扫描迁移记录失败: %v", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("遍历迁移记录失败: %v", err)
	}
	return out
}

// schemaTables 返回某 schema 下的全部基表，按字节序排序。
// 排序在 Go 侧做，避免数据库 collation 与测试预期不一致造成假失败。
func schemaTables(t *testing.T, db *sql.DB, schema string) []string {
	t.Helper()
	rows, err := db.QueryContext(context.Background(),
		`SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'`,
		schema)
	if err != nil {
		t.Fatalf("查询 schema %s 的表失败: %v", schema, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("扫描表名失败: %v", err)
		}
		out = append(out, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("遍历表名失败: %v", err)
	}
	sort.Strings(out)
	return out
}

// schemaSequences 返回某 schema 下的独立序列名（relkind='S'）。
// information_schema.sequences 对无人拥有的独立序列覆盖不全，所以查 pg_class。
func schemaSequences(t *testing.T, db *sql.DB, schema string) []string {
	t.Helper()
	rows, err := db.QueryContext(context.Background(),
		`SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE n.nspname = $1 AND c.relkind = 'S'`, schema)
	if err != nil {
		t.Fatalf("查询 schema %s 的序列失败: %v", schema, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("扫描序列名失败: %v", err)
		}
		out = append(out, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("遍历序列名失败: %v", err)
	}
	sort.Strings(out)
	return out
}

// schemaFingerprint 把某 schema 的"表 + 列 + 类型 + 可空性"压成有序字符串列表，
// 用来证明"旧库升级后的结构"和"全新建库的结构"完全一致，而不是只看表数量。
func schemaFingerprint(t *testing.T, db *sql.DB, schema string) []string {
	t.Helper()
	rows, err := db.QueryContext(context.Background(),
		`SELECT table_name, column_name, data_type, is_nullable
		 FROM information_schema.columns WHERE table_schema = $1`, schema)
	if err != nil {
		t.Fatalf("查询 schema %s 的列失败: %v", schema, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var table, column, dataType, nullable string
		if err := rows.Scan(&table, &column, &dataType, &nullable); err != nil {
			t.Fatalf("扫描列信息失败: %v", err)
		}
		out = append(out, fmt.Sprintf("%s.%s:%s:%s", table, column, dataType, nullable))
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("遍历列信息失败: %v", err)
	}
	sort.Strings(out)
	return out
}

// seedCanary 在"旧库"里放一条账号和一条同步记录。
// 升级完成后它们必须原封不动 —— 这是"迁移只做新增，不重建表"的证据。
func seedCanary(t *testing.T, db *sql.DB, id string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	if _, err := db.ExecContext(ctx,
		`INSERT INTO app_user (id, email, display_name, password_hash, created_at, updated_at)
		 VALUES ($1, $2, '升级哨兵', 'x', $3, $3)`,
		id, id+"@example.test", now); err != nil {
		t.Fatalf("写入哨兵账号失败: %v", err)
	}
	if _, err := db.ExecContext(ctx,
		`INSERT INTO sync_record (user_id, entity_type, entity_id, version, payload, updated_at)
		 VALUES ($1, 'task', $2, 424242, '{"canary":true}'::jsonb, $3)`,
		id, id+"_task", now); err != nil {
		t.Fatalf("写入哨兵同步记录失败: %v", err)
	}
}

func assertCanary(t *testing.T, db *sql.DB, id string) {
	t.Helper()
	ctx := context.Background()
	var n int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM app_user WHERE id = $1`, id).Scan(&n); err != nil {
		t.Fatalf("升级后查询哨兵账号失败: %v", err)
	}
	if n != 1 {
		t.Fatalf("升级后哨兵账号应恰好 1 行，实际 %d 行", n)
	}
	var (
		version int64
		payload []byte
	)
	if err := db.QueryRowContext(ctx,
		`SELECT version, payload FROM sync_record WHERE user_id = $1 AND entity_type = 'task' AND entity_id = $2`,
		id, id+"_task").Scan(&version, &payload); err != nil {
		t.Fatalf("升级后查询哨兵同步记录失败: %v", err)
	}
	if version != 424242 {
		t.Fatalf("升级改写了已有同步记录的版本：期望 424242，实际 %d", version)
	}
	if !json.Valid(payload) || !strings.Contains(string(payload), "canary") {
		t.Fatalf("升级丢失或改写了已有同步记录的内容: %s", payload)
	}
}

// TestIntegrationMigrationUpgradesOldDatabase 验证"只应用了前 N 个迁移的旧库"
// 能升级到当前版本，且升级后的结构与全新建库完全一致、已有数据不受损。
//
// 参数化到 N=0..len(migrations)：N=0 是空库首装，N=len 是"已经是最新"的重复执行。
// 仓库当前只有 0001_init.sql，所以真正有意义的 N 只有 0 和 1；
// 写成参数化是为了将来加迁移时自动获得覆盖，而不是现在伪造多个迁移。
func TestIntegrationMigrationUpgradesOldDatabase(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	migrations, err := store.LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移脚本失败: %v", err)
	}
	if len(migrations) == 0 {
		t.Fatal("没有迁移脚本，升级测试会变成空转")
	}

	// 参考结构：全新建库跑完整迁移，作为"当前版本应有的样子"。
	fresh, freshSchema := isolatedSchemaDB(t, db)
	if _, err := store.Migrate(ctx, fresh, time.Now); err != nil {
		t.Fatalf("参考库跑完整迁移失败: %v", err)
	}
	// 先确认参考结构自身完整：否则"升级结果 == 参考结构"可能因为两边都缺表而假通过。
	// proactive_budget_window 是 0003 新增的每日预算预留窗口表，属于当前版本应有的结构。
	wantTables := []string{"app_user", "device", "media_object", "memory_index", "memory_item", "proactive_budget_window", "proactive_message", "schema_migration", "sync_record"}
	if got := schemaTables(t, fresh, freshSchema); !reflect.DeepEqual(got, wantTables) {
		t.Fatalf("完整迁移后的表集合 %v 与预期 %v 不一致", got, wantTables)
	}
	if got := schemaSequences(t, fresh, freshSchema); !reflect.DeepEqual(got, []string{"sync_version_seq"}) {
		t.Fatalf("完整迁移后的序列 %v 与预期 [sync_version_seq] 不一致", got)
	}
	wantFingerprint := schemaFingerprint(t, fresh, freshSchema)

	wantVersions := make([]int, 0, len(migrations))
	for _, m := range migrations {
		wantVersions = append(wantVersions, m.Version)
	}

	for k := 0; k <= len(migrations); k++ {
		k := k
		t.Run(fmt.Sprintf("已应用%d个迁移共%d个", k, len(migrations)), func(t *testing.T) {
			sdb, schema := isolatedSchemaDB(t, db)

			// 1) 把库构造成"只应用了前 k 个迁移"的旧版本。
			applyMigrationsPrefix(t, sdb, migrations[:k])

			// 2) 旧库里放哨兵数据。k==0 时连表都不存在，放不进去，
			//    所以"哨兵仍在"这条断言只在 k>=1 时有意义。
			canary := ""
			if k >= 1 {
				canary = "canary_" + schemaSuffix(t)
				seedCanary(t, sdb, canary)
			}

			// 3) 跑完整迁移。
			applied, err := store.Migrate(ctx, sdb, time.Now)
			if err != nil {
				t.Fatalf("旧库升级失败: %v", err)
			}
			wantApplied := make([]int, 0, len(migrations)-k)
			for _, m := range migrations[k:] {
				wantApplied = append(wantApplied, m.Version)
			}
			// 用 slices.Equal 而不是 reflect.DeepEqual：Migrate 没东西可应用时返回 nil，
			// 而 wantApplied 是 make 出来的空切片，DeepEqual 会把两者判成不等。
			if !slices.Equal(applied, wantApplied) {
				t.Fatalf("升级应当只应用 %v，实际应用 %v", wantApplied, applied)
			}
			if got := migrationVersions(t, sdb); !slices.Equal(got, wantVersions) {
				t.Fatalf("升级后版本记录 %v 与全部迁移 %v 不一致", got, wantVersions)
			}

			// 4) 已有数据必须原样保留：迁移只做 CREATE/ALTER，绝不能重建表把数据抹掉。
			if canary != "" {
				assertCanary(t, sdb, canary)
			}

			// 5) 升级结果的结构必须与全新建库完全一致。
			if got := schemaFingerprint(t, sdb, schema); !reflect.DeepEqual(got, wantFingerprint) {
				t.Fatalf("旧库升级后的结构与全新建库不一致:\n升级库 %v\n全新建库 %v", got, wantFingerprint)
			}
		})
	}
}

// TestIntegrationMigrateIsIdempotentInIsolatedSchema 验证重复执行迁移是幂等的：
// 第二遍不应用任何脚本、不改写版本记录（含 applied_at）、也不改变结构。
//
// 用隔离 schema 是为了让"第一遍从零建库"这件事真实发生；
// 两份 now 用不同时间，是为了让"实现偷偷重写 applied_at"这种非幂等行为能被抓到。
func TestIntegrationMigrateIsIdempotentInIsolatedSchema(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	sdb, schema := isolatedSchemaDB(t, db)

	migrations, err := store.LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移脚本失败: %v", err)
	}
	wantVersions := make([]int, 0, len(migrations))
	for _, m := range migrations {
		wantVersions = append(wantVersions, m.Version)
	}
	firstNow := time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
	secondNow := time.Date(2025, 6, 7, 8, 9, 10, 0, time.UTC)

	first, err := store.Migrate(ctx, sdb, func() time.Time { return firstNow })
	if err != nil {
		t.Fatalf("第一次迁移失败: %v", err)
	}
	if !slices.Equal(first, wantVersions) {
		t.Fatalf("第一次迁移应当应用 %v，实际应用 %v", wantVersions, first)
	}
	before := migrationRows(t, sdb)
	fpBefore := schemaFingerprint(t, sdb, schema)

	second, err := store.Migrate(ctx, sdb, func() time.Time { return secondNow })
	if err != nil {
		t.Fatalf("第二次迁移失败: %v", err)
	}
	if len(second) != 0 {
		t.Fatalf("第二次迁移不应应用任何脚本，实际应用 %v", second)
	}

	after := migrationRows(t, sdb)
	if len(before) != len(after) {
		t.Fatalf("迁移记录条数变化: %d -> %d", len(before), len(after))
	}
	for i := range before {
		if before[i].version != after[i].version {
			t.Fatalf("第 %d 条记录版本从 %d 变成 %d", i, before[i].version, after[i].version)
		}
		if !before[i].appliedAt.Equal(after[i].appliedAt) {
			t.Fatalf("第二次迁移改写了版本 %d 的 applied_at: %s -> %s",
				before[i].version, before[i].appliedAt, after[i].appliedAt)
		}
	}
	if fpAfter := schemaFingerprint(t, sdb, schema); !reflect.DeepEqual(fpBefore, fpAfter) {
		t.Fatalf("重复迁移改变了表结构:\n前 %v\n后 %v", fpBefore, fpAfter)
	}
}
