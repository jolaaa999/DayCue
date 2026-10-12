package store

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

// Migration 是一个已经落到磁盘上的迁移脚本。
type Migration struct {
	Version int
	Name    string
	SQL     string
}

// LoadMigrations 读取内嵌的迁移脚本，按版本号排序。
//
// 文件名格式固定为 NNNN_name.sql。之所以用内嵌而不是运行目录读取，
// 是因为服务被部署成单个二进制时，工作目录里不会有 migrations/ 目录。
func LoadMigrations() ([]Migration, error) {
	entries, err := fs.ReadDir(migrationFS, "migrations")
	if err != nil {
		return nil, fmt.Errorf("store: 读取迁移目录失败: %w", err)
	}
	var out []Migration
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") {
			continue
		}
		base := strings.TrimSuffix(e.Name(), ".sql")
		idx := strings.Index(base, "_")
		if idx <= 0 {
			return nil, fmt.Errorf("store: 迁移文件名不符合 NNNN_name.sql: %s", e.Name())
		}
		v, err := strconv.Atoi(base[:idx])
		if err != nil {
			return nil, fmt.Errorf("store: 迁移版本号非法 %s: %w", e.Name(), err)
		}
		body, err := migrationFS.ReadFile("migrations/" + e.Name())
		if err != nil {
			return nil, fmt.Errorf("store: 读取 %s 失败: %w", e.Name(), err)
		}
		out = append(out, Migration{Version: v, Name: base[idx+1:], SQL: string(body)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })

	// 版本号重复意味着有人把两个迁移写成了同一个号，必须当场拒绝：
	// 否则后一个会被当成"已应用"而永远不执行。
	for i := 1; i < len(out); i++ {
		if out[i].Version == out[i-1].Version {
			return nil, fmt.Errorf("store: 迁移版本号重复: %d", out[i].Version)
		}
	}
	return out, nil
}

// Migrate 按顺序应用尚未执行的迁移。
//
// 每个迁移在**独立事务**里执行，并在同一事务内写入版本号：
// 这样"脚本执行了但版本没记上"或反之都不可能发生。
func Migrate(ctx context.Context, db *sql.DB, now func() time.Time) (applied []int, err error) {
	if now == nil {
		now = time.Now
	}
	migrations, err := LoadMigrations()
	if err != nil {
		return nil, err
	}

	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migration (
		version INTEGER PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		return nil, fmt.Errorf("store: 建迁移表失败: %w", err)
	}

	done := map[int]bool{}
	rows, err := db.QueryContext(ctx, `SELECT version FROM schema_migration`)
	if err != nil {
		return nil, fmt.Errorf("store: 读取迁移记录失败: %w", err)
	}
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return nil, fmt.Errorf("store: 扫描迁移版本失败: %w", err)
		}
		done[v] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("store: 遍历迁移版本失败: %w", err)
	}
	rows.Close()

	for _, m := range migrations {
		if done[m.Version] {
			continue
		}
		if err := applyOne(ctx, db, m, now); err != nil {
			return applied, err
		}
		applied = append(applied, m.Version)
	}
	return applied, nil
}

func applyOne(ctx context.Context, db *sql.DB, m Migration, now func() time.Time) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("store: 迁移 %d 开启事务失败: %w", m.Version, err)
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, m.SQL); err != nil {
		return fmt.Errorf("store: 迁移 %d (%s) 执行失败: %w", m.Version, m.Name, err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO schema_migration (version, applied_at) VALUES ($1, $2)`,
		m.Version, now().UTC()); err != nil {
		return fmt.Errorf("store: 迁移 %d 记录版本失败: %w", m.Version, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: 迁移 %d 提交失败: %w", m.Version, err)
	}
	return nil
}
