//go:build postgres

package store_test

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// 真实 PostgreSQL 上的「到期事件来源」验证。
//
// 这一层的输入是**客户端推上来的载荷**，所以最重要的不是「正常数据能查出来」，
// 而是「畸形数据不能把整条链路打垮」。下面单独有一条用例证明这一点。

// insertSyncRecord 直接写一条同步记录。走 SQL 而不是仓储，是因为这里要构造的是
// 客户端可能推上来的任意载荷，包括仓储永远不会产生的畸形值。
func insertSyncRecord(t *testing.T, db *sql.DB, userID, entityType, entityID string, version int64, payload string) {
	t.Helper()
	if _, err := db.ExecContext(context.Background(),
		"INSERT INTO sync_record (user_id, entity_type, entity_id, version, payload, updated_at) "+
			"VALUES ($1, $2, $3, $4, $5::jsonb, now())",
		userID, entityType, entityID, version, payload); err != nil {
		t.Fatalf("写入同步记录失败: %v", err)
	}
}

// sprintfTask 拼一条任务载荷。把时间文本做成参数而不是写死，是为了让
// 「它正是要被反复替换成畸形值的东西」在用例里一眼可见。
func sprintfTask(title, status, remindUTC string) string {
	return fmt.Sprintf(`{"title":"%s","detail":"备注","status":"%s","remind_utc":"%s"}`, title, status, remindUTC)
}

// filterByUser 只留本用例的用户：并发跑测试时库里会有别人的行，
// 直接断言整体条数会随机失败。
func filterByUser(events []store.DueProactiveEvent, userID string) []store.DueProactiveEvent {
	var mine []store.DueProactiveEvent
	for _, ev := range events {
		if ev.UserID == userID {
			mine = append(mine, ev)
		}
	}
	return mine
}

// suffixLetter 生成 a/b/c...，用于拼唯一的实体 id。
func suffixLetter(i int) string { return string(rune('a' + i)) }

func TestIntegrationDueProactiveEventsReadsOnlyDueOpenTasks(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	user := testIDPrefix(t)
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	now := time.Now().UTC().Truncate(time.Second)
	due := now.Add(-5 * time.Minute).Format(time.RFC3339)
	future := now.Add(6 * time.Hour).Format(time.RFC3339)
	past := now.Add(-72 * time.Hour).Format(time.RFC3339)

	insertSyncRecord(t, db, user, "task", user+"_due", 1, sprintfTask("交操作系统作业", "open", due))
	// 已完成的任务绝不能再来提醒：用户已经在本地把它勾掉了。
	insertSyncRecord(t, db, user, "task", user+"_done", 2, sprintfTask("已完成的作业", "done", due))
	// 已取消同理。
	insertSyncRecord(t, db, user, "task", user+"_cancelled", 3, sprintfTask("已取消的作业", "cancelled", due))
	// 还没到点的不该提前发。
	insertSyncRecord(t, db, user, "task", user+"_future", 4, sprintfTask("明天的事", "open", future))
	// 早就过期的（超出回溯窗口）不该补发：设备离线三天后重开，
	// 补一堆三天前的提醒比不提醒更糟。
	insertSyncRecord(t, db, user, "task", user+"_stale", 5, sprintfTask("三天前的作业", "open", past))
	// 没有提醒时刻的任务只是待办，不是提醒。
	insertSyncRecord(t, db, user, "task", user+"_noremind", 6,
		`{"title":"没有提醒的待办","status":"open"}`)
	// 墓碑行必须被排除。
	insertSyncRecord(t, db, user, "task", user+"_tombstone", 7, sprintfTask("已删除的作业", "open", due))
	if _, err := db.ExecContext(ctx,
		"UPDATE sync_record SET deleted_at = now() WHERE user_id = $1 AND entity_id = $2",
		user, user+"_tombstone"); err != nil {
		t.Fatalf("标记墓碑失败: %v", err)
	}

	events, err := pg.DueProactiveEvents(ctx, now.Add(-2*time.Hour), now, 50)
	if err != nil {
		t.Fatalf("查询到期事件失败: %v", err)
	}
	mine := filterByUser(events, user)
	if len(mine) != 1 {
		t.Fatalf("窗口内应当只有一条到期未完成的提醒，实际 %d 条: %+v", len(mine), mine)
	}
	if mine[0].Ref != user+"_due" {
		t.Fatalf("取到的应当是那条待办，实际 %q", mine[0].Ref)
	}
	if mine[0].Kind != "reminder" {
		t.Fatalf("任务事件的种类应为 reminder，实际 %q", mine[0].Kind)
	}
	if mine[0].Title != "交操作系统作业" {
		t.Fatalf("标题应来自客户端载荷，实际 %q", mine[0].Title)
	}
	if mine[0].OccurredAt.Location() != time.UTC {
		t.Fatalf("时刻一律按 UTC 返回，实际 %v", mine[0].OccurredAt.Location())
	}
}

func TestIntegrationDueProactiveEventsIncludesDueMemoryReviews(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	user := testIDPrefix(t)
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	now := time.Now().UTC().Truncate(time.Second)
	due := now.Add(-time.Hour).Format(time.RFC3339)

	insertSyncRecord(t, db, user, "memory", user+"_m_due", 1,
		`{"statement":"PV 操作要配信号量","status":"candidate","review_at":"`+due+`"}`)
	// 已确认的记忆不再需要提醒复核。
	insertSyncRecord(t, db, user, "memory", user+"_m_confirmed", 2,
		`{"statement":"已确认的记忆","status":"confirmed","review_at":"`+due+`"}`)

	events, err := pg.DueProactiveEvents(ctx, now.Add(-2*time.Hour), now, 50)
	if err != nil {
		t.Fatalf("查询到期事件失败: %v", err)
	}
	mine := filterByUser(events, user)
	if len(mine) != 1 {
		t.Fatalf("应当只有一条到期待复核的记忆，实际 %d 条: %+v", len(mine), mine)
	}
	if mine[0].Kind != "review" || mine[0].Ref != user+"_m_due" {
		t.Fatalf("记忆事件的种类应为 review，实际 %q / %q", mine[0].Kind, mine[0].Ref)
	}
}

// TestIntegrationDueProactiveEventsSurvivesMalformedTimestamp 是本文件最重要的一条。
//
// 载荷里的时间文本由客户端写，服务端无法保证它合法。若直接强转 timestamptz，
// 一台设备推上来一句「昨天下午」就会让整个查询抛错，**所有用户**的提醒都发不出去。
// 这里证明畸形值只影响它自己那一条，好数据照常返回。
func TestIntegrationDueProactiveEventsSurvivesMalformedTimestamp(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	user := testIDPrefix(t)
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	now := time.Now().UTC().Truncate(time.Second)
	due := now.Add(-5 * time.Minute).Format(time.RFC3339)

	malformed := []string{
		"昨天下午",
		"2026-13-45T99:99:99Z",
		"",
		"   ",
		"not-a-date",
		"2026-10-12",
	}
	for i, bad := range malformed {
		insertSyncRecord(t, db, user, "task", user+"_bad"+suffixLetter(i), int64(10+i),
			sprintfTask("畸形时间", "open", bad))
	}
	insertSyncRecord(t, db, user, "task", user+"_good", 30, sprintfTask("正常提醒", "open", due))

	events, err := pg.DueProactiveEvents(ctx, now.Add(-2*time.Hour), now, 50)
	if err != nil {
		t.Fatalf("畸形时间不得让整条查询失败，实际报错: %v", err)
	}
	mine := filterByUser(events, user)
	if len(mine) != 1 {
		t.Fatalf("应当只返回那条时间合法的提醒，实际 %d 条: %+v", len(mine), mine)
	}
	if mine[0].Ref != user+"_good" {
		t.Fatalf("返回的应当是合法那条，实际 %q", mine[0].Ref)
	}
}

func TestIntegrationDueProactiveEventsRespectsLimitAndValidation(t *testing.T) {
	db := openTestDB(t)
	ensureSchema(t, db)
	pg := newPostgres(t, db)
	ctx := context.Background()

	user := testIDPrefix(t)
	createTestUser(t, pg, user)
	registerCleanup(t, db, user)

	now := time.Now().UTC().Truncate(time.Second)
	for i := 0; i < 5; i++ {
		at := now.Add(-time.Duration(i+1) * time.Minute).Format(time.RFC3339)
		insertSyncRecord(t, db, user, "task", user+"_l"+suffixLetter(i), int64(40+i),
			sprintfTask("提醒"+suffixLetter(i), "open", at))
	}

	events, err := pg.DueProactiveEvents(ctx, now.Add(-2*time.Hour), now, 2)
	if err != nil {
		t.Fatalf("查询失败: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("条数上限应当生效，实际 %d 条", len(events))
	}
	// 按到期时刻升序：最先到点的先发，否则用户会先收到后面那条。
	if !events[0].OccurredAt.Before(events[1].OccurredAt) {
		t.Fatalf("应按到期时刻升序返回，实际 %v 然后 %v", events[0].OccurredAt, events[1].OccurredAt)
	}

	if _, err := pg.DueProactiveEvents(ctx, now.Add(-2*time.Hour), now, 0); err == nil {
		t.Fatal("条数上限为 0 应当被拒绝，而不是退化成「不限制」")
	}
	if _, err := pg.DueProactiveEvents(ctx, now, now.Add(-time.Hour), 10); err == nil {
		t.Fatal("时间窗倒置应当被拒绝")
	}
}
