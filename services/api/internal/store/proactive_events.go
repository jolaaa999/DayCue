package store

import (
	"context"
	"fmt"
	"time"
)

// DueProactiveEvent 是一条「已经到点、且服务端真的看得见」的业务事件。
//
// 服务端能看见什么，完全由客户端推上来的实体类型决定：
//   - task 两端都会同步，且载荷里有 remind_utc，所以任务提醒是可靠来源；
//   - memory 目前只有 iOS 端同步，所以回顾类事件在只有 Android 设备的账号上查不到。
//     这不是缺陷，是同步范围的现状——服务端不能为它看不见的数据凭空造提醒。
//
// 反过来，服务端**看不见**的东西也必须说明白：位置与课后追问都不在同步范围内
// （两端都不推 place / geo_rule / follow_up / course_instance），
// 因此这里永远不会给出 geo 或 follow_up 类事件。理由见 proactive.Producer 的说明。
type DueProactiveEvent struct {
	UserID string
	// Kind 只能是 task 对应的 reminder 或 memory 对应的 review。
	Kind string
	// Ref 业务对象 id（task / memory 的 id），用于拼稳定去重键与冷却键。
	Ref string
	// Title 通知标题。服务端只用客户端已经写好的内容，不自己编造文案。
	Title string
	Body  string
	// DeepLink 目前恒为空，理由见 sqlDueProactiveEvents 的注释。
	DeepLink string
	// OccurredAt 业务时刻（remind_utc / review_at），UTC。
	OccurredAt time.Time
}

// ProactiveEventSource 读取到期业务事件。
//
// 与编排层的 proactive.CandidateSource 是两个包里的同名概念：存储层不该依赖编排层，
// 否则依赖方向就反了（编排层才是策略所在）。两者的映射放在装配层做。
type ProactiveEventSource interface {
	DueProactiveEvents(ctx context.Context, from, to time.Time, limit int) ([]DueProactiveEvent, error)
}

// sqlDueProactiveEvents 取出窗口内到点的任务提醒与记忆回顾。
//
// 几个刻意的选择：
//   - 用 MATERIALIZED CTE 把「转换时间」与「按时间过滤/排序」分开。规划器不会把
//     过滤条件下推到 CTE 内部，于是 daycue_try_timestamptz 一定先跑完，
//     后面比较的就是干净的 timestamptz，而不是再对文本做一次可能抛错的转换。
//   - 状态白名单是 ('open','candidate')：task 的状态是 open/done/cancelled，
//     memory 的状态是 candidate/confirmed/retired/conflict。一个白名单同时正确覆盖
//     两张表，比按类型分支写两套判断更不容易写错，也天然排除了「已完成的任务还来提醒」。
//   - 不拼 deep_link：客户端**没有注册** daycue:// 的 URL scheme
//     （AndroidManifest 只有 MAIN/LAUNCHER，没有带 scheme 的 intent-filter），
//     填一个打不开的深链等于给用户一个点了没反应的入口。
//     落地页留空，由客户端按既有导航决定去哪；业务对象 id 仍通过 target_ref 带过去。
//   - 时间用 UTC 传入传出：账本里的绝对时刻一律 UTC，用户时区只影响预算与静默判定，
//     不影响「这条提醒本该什么时候响」。
const sqlDueProactiveEvents = `
WITH candidates AS MATERIALIZED (
  SELECT r.user_id,
         'reminder'::text                                  AS kind,
         r.entity_id,
         COALESCE(r.payload->>'title', '')                 AS title,
         COALESCE(r.payload->>'detail', '')                AS body,
         COALESCE(r.payload->>'status', '')                AS status,
         daycue_try_timestamptz(r.payload->>'remind_utc')  AS occurred_at
  FROM sync_record r
  WHERE r.entity_type = 'task'
    AND r.deleted_at IS NULL
  UNION ALL
  SELECT r.user_id,
         'review'::text                                    AS kind,
         r.entity_id,
         COALESCE(r.payload->>'statement', '')             AS title,
         ''::text                                          AS body,
         COALESCE(r.payload->>'status', '')                AS status,
         daycue_try_timestamptz(r.payload->>'review_at')   AS occurred_at
  FROM sync_record r
  WHERE r.entity_type = 'memory'
    AND r.deleted_at IS NULL
)
SELECT user_id, kind, entity_id, title, body, occurred_at
FROM candidates
WHERE occurred_at IS NOT NULL
  AND status IN ('open', 'candidate')
  AND occurred_at >= $1
  AND occurred_at <= $2
ORDER BY occurred_at ASC, user_id, entity_id
LIMIT $3
`

// DueProactiveEvents 实现 ProactiveEventSource。
func (p *Postgres) DueProactiveEvents(ctx context.Context, from, to time.Time, limit int) ([]DueProactiveEvent, error) {
	if p == nil || p.db == nil {
		return nil, fmt.Errorf("store: Postgres 未初始化")
	}
	if limit <= 0 {
		return nil, fmt.Errorf("store: 到期事件条数上限必须为正数，收到 %d", limit)
	}
	if to.Before(from) {
		return nil, fmt.Errorf("store: 到期事件时间窗结束早于开始")
	}
	rows, err := p.db.QueryContext(ctx, sqlDueProactiveEvents, from.UTC(), to.UTC(), limit)
	if err != nil {
		return nil, fmt.Errorf("store: 查询到期事件失败: %w", err)
	}
	defer rows.Close()

	var out []DueProactiveEvent
	for rows.Next() {
		var ev DueProactiveEvent
		if err := rows.Scan(&ev.UserID, &ev.Kind, &ev.Ref, &ev.Title, &ev.Body, &ev.OccurredAt); err != nil {
			return nil, fmt.Errorf("store: 扫描到期事件失败: %w", err)
		}
		ev.OccurredAt = ev.OccurredAt.UTC()
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历到期事件失败: %w", err)
	}
	return out, nil
}

// 编译期确认 Postgres 满足事件来源接口。
var _ ProactiveEventSource = (*Postgres)(nil)
