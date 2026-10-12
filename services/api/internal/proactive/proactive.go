// Package proactive 决定"这条主动消息现在该不该发"。
//
// 设计取舍：
//   - 判定是**纯函数 + 显式时间基准**：预算、静默时段、冷却、去重全部由入参决定，
//     不读系统时钟、不读全局状态。这样跨零点、跨时区这些最容易错的地方才测得动。
//   - 静默时段内**延迟而不是丢弃**：用户半夜收到通知才是真正的打扰，
//     但把消息直接扔掉又会让"到图书馆提醒还书"永远不出现。
//   - 预算按**自然日**（用户所在时区）计算，跨零点必须重置。
//   - 去重键由业务给出（例如 "geo:place-1:2026-10-12"），同一天同一键只发一次。
package proactive

import (
	"errors"
	"fmt"
	"time"
)

// Clock 是"每天几点"的本地时刻，用分钟表示，便于比较且不受日期影响。
type Clock struct {
	Hour   int
	Minute int
}

// Minutes 返回自零点起的分钟数。
func (c Clock) Minutes() int { return c.Hour*60 + c.Minute }

// Valid 判断时刻是否合法。
func (c Clock) Valid() bool {
	return c.Hour >= 0 && c.Hour < 24 && c.Minute >= 0 && c.Minute < 60
}

// ParseClock 解析 "HH:MM"。
func ParseClock(s string) (Clock, error) {
	var h, m int
	if _, err := fmt.Sscanf(s, "%d:%d", &h, &m); err != nil {
		return Clock{}, fmt.Errorf("proactive: 无法解析时刻 %q: %w", s, err)
	}
	c := Clock{Hour: h, Minute: m}
	if !c.Valid() {
		return Clock{}, fmt.Errorf("proactive: 时刻越界 %q", s)
	}
	return c, nil
}

// Policy 是主动消息的发送策略。零值不可用，请用 DefaultPolicy 或显式构造。
type Policy struct {
	// DailyBudget 是每个自然日最多发出的主动消息条数。<=0 表示不限。
	DailyBudget int
	// QuietStart / QuietEnd 是静默时段（本地时刻，含起不含止）。
	// 两者相等表示没有静默时段。
	QuietStart Clock
	QuietEnd   Clock
	// Cooldown 是同类消息之间的最小间隔。
	Cooldown time.Duration
}

// DefaultPolicy 给出保守的默认值：每天 3 条、22:30–07:30 静默、冷却 1 小时。
func DefaultPolicy() Policy {
	return Policy{
		DailyBudget: 3,
		QuietStart:  Clock{22, 30},
		QuietEnd:    Clock{7, 30},
		Cooldown:    time.Hour,
	}
}

// SuppressReason 说明消息为什么没发出去。用常量而不是裸字符串，
// 是为了让界面能稳定地把原因翻成中文，而不是靠匹配自由文本。
type SuppressReason string

const (
	ReasonNone          SuppressReason = ""
	ReasonDedupe        SuppressReason = "dedupe"
	ReasonBudget        SuppressReason = "daily_budget"
	ReasonCooldown      SuppressReason = "cooldown"
	ReasonExpired       SuppressReason = "expired"
	ReasonNotYetDue     SuppressReason = "not_due_yet"
	ReasonQuietDeferred SuppressReason = "quiet_hours_deferred"
)

// Chinese 返回给用户看的中文说明。
func (r SuppressReason) Chinese() string {
	switch r {
	case ReasonNone:
		return ""
	case ReasonDedupe:
		return "今天已经发过同一条提醒"
	case ReasonBudget:
		return "已达今日主动消息上限"
	case ReasonCooldown:
		return "距离同类上一条提醒太近"
	case ReasonExpired:
		return "这条提醒已经过期"
	case ReasonNotYetDue:
		return "还没到发送时间"
	case ReasonQuietDeferred:
		return "处于静默时段，已推迟到静默结束"
	default:
		return string(r)
	}
}

// Candidate 是一条待判定的主动消息。
type Candidate struct {
	// DedupeKey 由业务给出；同一天内相同键只允许发一次。
	DedupeKey string
	// ScheduledAt 是业务希望发出的时刻（UTC）。
	ScheduledAt time.Time
	// ExpiresAt 为空表示不过期。过期之后不再发送，也不再推迟。
	ExpiresAt *time.Time
}

// History 是判定所需的既有事实，由调用方从存储读出。
type History struct {
	// DeliveredToday 是该自然日已发出的主动消息条数。
	DeliveredToday int
	// LastDeliveredSameKey 是同一去重键最近一次发出的时刻；零值表示没发过。
	LastDeliveredSameKey time.Time
	// LastDeliveredSameKind 是同类消息最近一次发出的时刻；零值表示没发过。
	LastDeliveredSameKind time.Time
	// SameKeyDeliveredToday 表示同一去重键今天已经发过。
	SameKeyDeliveredToday bool
}

// Decision 是判定结果。
type Decision struct {
	// Send 为 true 表示"现在就发"。
	Send bool
	// DeliverAt 在 Send 为 true 时等于 now（或推迟后的时刻）；
	// 在因静默时段被推迟时给出推迟到的时刻。
	DeliverAt time.Time
	// Suppressed 为 true 表示这条消息被彻底放弃了（超预算、冷却、过期、去重）。
	Suppressed bool
	// Deferred 为 true 表示只是推迟，之后仍应重试。
	Deferred bool
	Reason   SuppressReason
}

// Decide 判定一条候选消息。
//
// 判定顺序是有意的，不要随意调换：
//  1. 过期 → 直接放弃（过期的提醒比不提醒更糟）；
//  2. 去重 → 直接放弃（同一天不重复打扰）；
//  3. 未到点 → 推迟（还不是发送时机，不是失败）；
//  4. 预算 / 冷却 → 放弃（今天已经够多了）；
//  5. 静默时段 → 推迟到静默结束（不丢弃）。
func Decide(p Policy, c Candidate, h History, now time.Time, loc *time.Location) Decision {
	if loc == nil {
		loc = time.UTC
	}

	if c.ExpiresAt != nil && !now.Before(*c.ExpiresAt) {
		return Decision{Suppressed: true, Reason: ReasonExpired}
	}

	if c.DedupeKey != "" && h.SameKeyDeliveredToday {
		return Decision{Suppressed: true, Reason: ReasonDedupe}
	}

	if now.Before(c.ScheduledAt) {
		return Decision{Deferred: true, DeliverAt: c.ScheduledAt, Reason: ReasonNotYetDue}
	}

	if p.DailyBudget > 0 && h.DeliveredToday >= p.DailyBudget {
		return Decision{Suppressed: true, Reason: ReasonBudget}
	}

	if p.Cooldown > 0 && !h.LastDeliveredSameKind.IsZero() &&
		now.Sub(h.LastDeliveredSameKind) < p.Cooldown {
		return Decision{Suppressed: true, Reason: ReasonCooldown}
	}

	if deferred, ok := deferPastQuietHours(p, now, loc); ok {
		// 推迟后可能已经越过过期时刻，那就索性放弃，避免发出过期内容。
		if c.ExpiresAt != nil && !deferred.Before(*c.ExpiresAt) {
			return Decision{Suppressed: true, Reason: ReasonExpired}
		}
		return Decision{Deferred: true, DeliverAt: deferred, Reason: ReasonQuietDeferred}
	}

	return Decision{Send: true, DeliverAt: now}
}

// deferPastQuietHours 判断 now 是否落在静默时段；若是，返回静默结束时刻。
//
// 跨零点的静默时段（例如 22:30–07:30）必须当成"跨越两天"来处理，
// 这是最容易写错的地方：只比较分钟数会在 23:00 和 06:00 给出不同答案。
func deferPastQuietHours(p Policy, now time.Time, loc *time.Location) (time.Time, bool) {
	if !p.QuietStart.Valid() || !p.QuietEnd.Valid() {
		return time.Time{}, false
	}
	if p.QuietStart == p.QuietEnd {
		return time.Time{}, false
	}

	local := now.In(loc)
	cur := local.Hour()*60 + local.Minute()
	start := p.QuietStart.Minutes()
	end := p.QuietEnd.Minutes()

	inQuiet := false
	if start < end {
		// 同一天内，例如 12:00–14:00。
		inQuiet = cur >= start && cur < end
	} else {
		// 跨零点，例如 22:30–07:30。
		inQuiet = cur >= start || cur < end
	}
	if !inQuiet {
		return time.Time{}, false
	}

	// 静默结束时刻：若当前已过零点且早于 end，当天就能结束；
	// 否则要等到第二天的 end。
	endLocal := time.Date(local.Year(), local.Month(), local.Day(), p.QuietEnd.Hour, p.QuietEnd.Minute, 0, 0, loc)
	if !endLocal.After(local) {
		endLocal = endLocal.AddDate(0, 0, 1)
	}
	return endLocal, true
}

// DayKey 返回某个时刻在指定时区下的自然日键（YYYY-MM-DD）。
// 预算与去重都按这个键分桶，跨零点自动重置。
func DayKey(t time.Time, loc *time.Location) string {
	if loc == nil {
		loc = time.UTC
	}
	return t.In(loc).Format("2006-01-02")
}

// ErrInvalidPolicy 表示策略本身不合法。
var ErrInvalidPolicy = errors.New("proactive: 策略不合法")

// Validate 检查策略。宁可启动时拒绝，也不要在运行期发出多余打扰。
func (p Policy) Validate() error {
	if p.DailyBudget < 0 {
		return fmt.Errorf("%w: 每日预算不能为负", ErrInvalidPolicy)
	}
	if p.QuietStart.Valid() != p.QuietEnd.Valid() {
		return fmt.Errorf("%w: 静默时段两端必须同时有效", ErrInvalidPolicy)
	}
	if p.Cooldown < 0 {
		return fmt.Errorf("%w: 冷却时间不能为负", ErrInvalidPolicy)
	}
	return nil
}
