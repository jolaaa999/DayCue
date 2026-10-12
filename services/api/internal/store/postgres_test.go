package store

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
)

// 本文件只验证**不依赖真实数据库**也能验证的东西：构造参数校验与 SQL 的租户隔离属性。
//
// 明确未验证：事务、SELECT ... FOR UPDATE 的并发语义、nextval、JSONB 参数编解码、
// 部分唯一索引 uq_app_user_email_live、以及任何一条 SQL 在真实 PostgreSQL 上能否执行。
// 原因：本机没有 psql、没有 Docker daemon，也按硬约束不引入数据库驱动（无法 go get）。

func TestNewPostgresValidatesArgs(t *testing.T) {
	if _, err := NewPostgres(nil, nil); err == nil {
		t.Fatal("db 为 nil 时必须报错")
	}
	p, err := NewPostgres(&sql.DB{}, nil)
	if err != nil {
		t.Fatalf("合法参数不应报错: %v", err)
	}
	if p == nil {
		t.Fatal("构造函数返回了 nil 实现")
	}
	// 编译期断言写在 postgres.go 里；这里再确认一次实现体没有被替换成别的东西。
	var (
		_ UserStore   = p
		_ SyncStore   = p
		_ MemoryStore = p
		_ ExportStore = p
	)
}

func TestSQLStatementsAreTenantScoped(t *testing.T) {
	stmts := SQLStatements()
	if len(stmts) == 0 {
		t.Fatal("SQL 清单为空：租户隔离断言会变成空转")
	}
	seen := map[string]bool{}
	for _, st := range stmts {
		if strings.TrimSpace(st.Name) == "" || strings.TrimSpace(st.SQL) == "" {
			t.Errorf("清单里的语句必须有名字和 SQL: %+v", st)
			continue
		}
		if seen[st.Name] {
			t.Errorf("语句名重复: %s", st.Name)
		}
		seen[st.Name] = true

		if st.UserScoped {
			// 硬约束：用户数据表的每一条语句都必须带 user_id 过滤。
			if !strings.Contains(st.SQL, "user_id") {
				t.Errorf("用户域语句缺少 user_id 过滤: %s", st.Name)
			}
			continue
		}
		// 非用户域语句只允许操作账号表或取全局版本号。
		// 这条断言是为了防止将来有人把一条没有过滤的数据查询塞进"豁免"名单。
		if !strings.Contains(st.SQL, "app_user") && !strings.Contains(st.SQL, "sync_version_seq") {
			t.Errorf("非用户域语句只允许操作 app_user 或 sync_version_seq: %s", st.Name)
		}
	}
}

func TestSQLStatementsReturnsCopy(t *testing.T) {
	first := SQLStatements()
	first[0].SQL = "DELETE FROM sync_record"
	first[0].Name = "tampered"
	second := SQLStatements()
	if second[0].SQL == "DELETE FROM sync_record" || second[0].Name == "tampered" {
		t.Fatal("SQLStatements 必须返回副本，否则调用方能改掉执行器正在用的语句")
	}
}

func TestNormalizePayload(t *testing.T) {
	// 空负载（墓碑）必须变成合法的空 JSON 对象：sync_record.payload 是 NOT NULL 的 JSONB。
	got, err := normalizePayload(nil)
	if err != nil || string(got) != "{}" {
		t.Fatalf("空负载应归一为 {}，实得 %q err=%v", got, err)
	}
	if _, err := normalizePayload([]byte("{")); err == nil {
		t.Fatal("非法 JSON 必须报错，否则会把 DB 错误抛给上层")
	}
	valid := []byte(`{"a":1}`)
	got, err = normalizePayload(valid)
	if err != nil || string(got) != string(valid) {
		t.Fatalf("合法负载应原样返回，实得 %q err=%v", got, err)
	}
}

func TestNotFoundTranslation(t *testing.T) {
	if !errors.Is(notFound(sql.ErrNoRows), ErrNotFound) {
		t.Fatal("sql.ErrNoRows 必须翻译成 store.ErrNotFound")
	}
	// 查询失败不能被当成"不存在"：那会让同步把故障误判成删除。
	boom := errors.New("boom")
	if notFound(boom) != boom {
		t.Fatal("非 ErrNoRows 的错误必须原样返回")
	}
}
