package store

import (
	"strings"
	"testing"
)

func TestLoadMigrationsIsOrderedAndNonEmpty(t *testing.T) {
	ms, err := LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移失败: %v", err)
	}
	if len(ms) == 0 {
		t.Fatal("应当至少有一个迁移脚本")
	}
	for i := 1; i < len(ms); i++ {
		if ms[i].Version <= ms[i-1].Version {
			t.Fatalf("迁移必须按版本号严格递增: %d 出现在 %d 之后", ms[i].Version, ms[i-1].Version)
		}
	}
	if ms[0].Version != 1 {
		t.Fatalf("第一个迁移应为版本 1，实际 %d", ms[0].Version)
	}
}

func TestMigrationsCoverEveryServerTable(t *testing.T) {
	ms, err := LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移失败: %v", err)
	}
	all := ""
	for _, m := range ms {
		all += m.SQL + "\n"
	}
	// 这些表是服务端功能的最小集合：少一张就有功能落不了地。
	for _, table := range []string{
		"schema_migration", "app_user", "device", "sync_record",
		"media_object", "memory_item", "memory_index", "proactive_message",
	} {
		if !strings.Contains(all, "CREATE TABLE IF NOT EXISTS "+table) {
			t.Errorf("迁移里缺少表 %s", table)
		}
	}
}

func TestEveryUserScopedTableHasUserIDColumn(t *testing.T) {
	ms, err := LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移失败: %v", err)
	}
	all := ""
	for _, m := range ms {
		all += m.SQL + "\n"
	}
	// 多租户隔离靠 SQL 里的 user_id 强制。这里用最朴素的方式兜住"漏过滤"：
	// 只要表名出现在下面的清单里，它就必须真的有 user_id 列。
	for _, table := range []string{
		"device", "sync_record", "media_object", "memory_item",
		"memory_index", "proactive_message",
	} {
		start := strings.Index(all, "CREATE TABLE IF NOT EXISTS "+table+" (")
		if start < 0 {
			t.Fatalf("找不到表 %s 的定义", table)
		}
		end := strings.Index(all[start:], ");")
		if end < 0 {
			t.Fatalf("表 %s 定义不完整", table)
		}
		body := all[start : start+end]
		if !strings.Contains(body, "user_id") {
			t.Errorf("表 %s 缺少 user_id 列，多租户隔离会被绕过", table)
		}
	}
}

func TestDeletesAreTombstonesNotRowRemovals(t *testing.T) {
	ms, err := LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移失败: %v", err)
	}
	all := ""
	for _, m := range ms {
		all += m.SQL + "\n"
	}
	// 同步表必须能表达"已删除"。没有 deleted_at 就只能删行，
	// 那样离线设备永远学不到删除，本地会留下幽灵数据。
	if !strings.Contains(all, "deleted_at") {
		t.Fatal("迁移里必须有 deleted_at 墓碑列")
	}
	if strings.Contains(all, "sync_record") && !strings.Contains(all, "idx_sync_record_cursor") {
		t.Fatal("同步表必须有游标索引，否则增量拉取会全表扫描")
	}
}

func TestMigrationFilesDeclareNoDestructiveStatements(t *testing.T) {
	ms, err := LoadMigrations()
	if err != nil {
		t.Fatalf("装载迁移失败: %v", err)
	}
	for _, m := range ms {
		up := strings.ToUpper(m.SQL)
		// 迁移脚本一旦包含这些语句，一次误跑就会把用户数据抹掉。
		for _, bad := range []string{"DROP DATABASE", "DROP TABLE ", "TRUNCATE "} {
			if strings.Contains(up, bad) {
				t.Errorf("迁移 %d 含破坏性语句 %s", m.Version, bad)
			}
		}
	}
}
