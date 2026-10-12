package proactive

import (
	"errors"
	"testing"
	"time"
)

// 固定时区与固定"现在"，绝不读系统时钟：跨零点、跨时区这类逻辑
// 一旦依赖执行日期，测试就会在半夜或换时区时莫名其妙地红。
var sh = mustLoad("Asia/Shanghai")

func mustLoad(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	return loc
}

// at 构造上海本地时刻。
func at(y int, mo time.Month, d, h, mi int) time.Time {
	return time.Date(y, mo, d, h, mi, 0, 0, sh)
}

func TestParseClock(t *testing.T) {
	c, err := ParseClock("22:30")
	if err != nil || c.Hour != 22 || c.Minute != 30 {
		t.Fatalf("解析 22:30 失败: %+v %v", c, err)
	}
	for _, bad := range []string{"24:00", "12:60", "-1:00", "abc", ""} {
		if _, err := ParseClock(bad); err == nil {
			t.Errorf("%q 应解析失败", bad)
		}
	}
}

func TestSendsWhenAllowed(t *testing.T) {
	p := DefaultPolicy()
	now := at(2026, 10, 12, 12, 0)
	d := Decide(p, Candidate{
		DedupeKey: "geo:place-1:2026-10-12", ScheduledAt: now.Add(-time.Minute),
	}, History{}, now, sh)

	if !d.Send || d.Suppressed || d.Deferred {
		t.Fatalf("正常情况应直接发送，实际 %+v", d)
	}
}

func TestExpiredIsSuppressedNotDeferred(t *testing.T) {
	exp := at(2026, 10, 12, 11, 0)
	now := at(2026, 10, 12, 12, 0)
	d := Decide(DefaultPolicy(), Candidate{ScheduledAt: now.Add(-2 * time.Hour), ExpiresAt: &exp}, History{}, now, sh)

	// 过期的提醒比不提醒更糟，必须彻底放弃而不是推迟。
	if !d.Suppressed || d.Reason != ReasonExpired {
		t.Fatalf("过期应被放弃，实际 %+v", d)
	}
	if d.Reason.Chinese() == "" {
		t.Fatal("抑制原因必须有中文说明")
	}
}

func TestDedupeSuppressesSameKeySameDay(t *testing.T) {
	now := at(2026, 10, 12, 12, 0)
	d := Decide(DefaultPolicy(), Candidate{DedupeKey: "k", ScheduledAt: now.Add(-time.Minute)},
		History{SameKeyDeliveredToday: true}, now, sh)

	if !d.Suppressed || d.Reason != ReasonDedupe {
		t.Fatalf("同日同键应去重，实际 %+v", d)
	}
}

func TestBudgetSuppressesAfterLimit(t *testing.T) {
	p := DefaultPolicy() // 预算 3
	now := at(2026, 10, 12, 12, 0)

	if d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)}, History{DeliveredToday: 2}, now, sh); !d.Send {
		t.Fatalf("第 3 条应当还能发，实际 %+v", d)
	}
	d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)}, History{DeliveredToday: 3}, now, sh)
	if !d.Suppressed || d.Reason != ReasonBudget {
		t.Fatalf("超过预算应被抑制，实际 %+v", d)
	}
}

func TestBudgetResetsAcrossMidnight(t *testing.T) {
	p := DefaultPolicy()
	// 23:50 已经用满预算，日键是 10-12。
	before := at(2026, 10, 12, 23, 50)
	if d := Decide(p, Candidate{ScheduledAt: before.Add(-time.Minute)}, History{DeliveredToday: 3}, before, sh); !d.Suppressed {
		t.Fatalf("深夜用满预算应被抑制，实际 %+v", d)
	}
	// 跨过零点后是新的自然日，计数必须重置。
	// 注意要取静默时段**结束之后**的时刻：00:10 仍在 22:30–07:30 静默期内，
	// 那时被推迟是正确的，不能拿来验证预算。
	after := at(2026, 10, 13, 9, 0)
	if DayKey(before, sh) == DayKey(after, sh) {
		t.Fatal("跨零点后日键必须变化")
	}
	if d := Decide(p, Candidate{ScheduledAt: after.Add(-time.Minute)}, History{DeliveredToday: 0}, after, sh); !d.Send {
		t.Fatalf("新的一天应能重新发送，实际 %+v", d)
	}
	// 顺带确认：零点刚过仍在静默期，此时是推迟而不是"新一天立刻狂发"。
	midnight := at(2026, 10, 13, 0, 10)
	if d := Decide(p, Candidate{ScheduledAt: midnight.Add(-time.Minute)}, History{DeliveredToday: 0}, midnight, sh); !d.Deferred {
		t.Fatalf("零点刚过应仍处于静默期而推迟，实际 %+v", d)
	}
}

func TestQuietHoursDefersInsteadOfDropping(t *testing.T) {
	p := DefaultPolicy() // 22:30–07:30 静默
	now := at(2026, 10, 12, 23, 0)
	d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)}, History{}, now, sh)

	if d.Suppressed {
		t.Fatal("静默时段不应把消息丢掉")
	}
	if !d.Deferred || d.Reason != ReasonQuietDeferred {
		t.Fatalf("静默时段应推迟，实际 %+v", d)
	}
	// 应推迟到次日 07:30（本地）。
	want := at(2026, 10, 13, 7, 30)
	if !d.DeliverAt.Equal(want) {
		t.Fatalf("应推迟到 %s，实际 %s", want, d.DeliverAt)
	}
}

func TestQuietHoursBeforeDawnStillSameDay(t *testing.T) {
	p := DefaultPolicy()
	now := at(2026, 10, 12, 6, 0) // 凌晨 6 点，仍在静默期
	d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)}, History{}, now, sh)

	if !d.Deferred {
		t.Fatalf("凌晨应被推迟，实际 %+v", d)
	}
	// 已经过了零点且早于 07:30，所以当天 07:30 就结束，不该推到第二天。
	want := at(2026, 10, 12, 7, 30)
	if !d.DeliverAt.Equal(want) {
		t.Fatalf("应推迟到当天 %s，实际 %s", want, d.DeliverAt)
	}
}

func TestQuietHoursDeferralRespectsExpiry(t *testing.T) {
	p := DefaultPolicy()
	now := at(2026, 10, 12, 23, 0)
	// 过期时刻落在静默期之内：推迟过去也已经没意义了，应当放弃。
	exp := at(2026, 10, 13, 1, 0)
	d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute), ExpiresAt: &exp}, History{}, now, sh)

	if !d.Suppressed || d.Reason != ReasonExpired {
		t.Fatalf("推迟后才过期的应被放弃，实际 %+v", d)
	}
}

func TestNoQuietHoursWhenStartEqualsEnd(t *testing.T) {
	p := DefaultPolicy()
	p.QuietStart = Clock{0, 0}
	p.QuietEnd = Clock{0, 0}
	now := at(2026, 10, 12, 23, 0)
	if d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)}, History{}, now, sh); !d.Send {
		t.Fatalf("静默时段两端相等表示不启用，应直接发送，实际 %+v", d)
	}
}

func TestCooldownSuppressesSameKind(t *testing.T) {
	p := DefaultPolicy() // 冷却 1 小时
	now := at(2026, 10, 12, 12, 0)

	d := Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)},
		History{LastDeliveredSameKind: now.Add(-30 * time.Minute)}, now, sh)
	if !d.Suppressed || d.Reason != ReasonCooldown {
		t.Fatalf("冷却期内应被抑制，实际 %+v", d)
	}

	d = Decide(p, Candidate{ScheduledAt: now.Add(-time.Minute)},
		History{LastDeliveredSameKind: now.Add(-90 * time.Minute)}, now, sh)
	if !d.Send {
		t.Fatalf("冷却结束后应可发送，实际 %+v", d)
	}
}

func TestNotYetDueIsDeferredNotSuppressed(t *testing.T) {
	now := at(2026, 10, 12, 12, 0)
	future := now.Add(20 * time.Minute)
	d := Decide(DefaultPolicy(), Candidate{ScheduledAt: future}, History{}, now, sh)

	if d.Suppressed {
		t.Fatal("还没到点不应被当成失败丢弃")
	}
	if !d.Deferred || !d.DeliverAt.Equal(future) {
		t.Fatalf("应推迟到计划时刻，实际 %+v", d)
	}
}

func TestExpiryWinsOverEverythingElse(t *testing.T) {
	// 判定顺序里过期最优先：即使同时命中预算与静默，也应当是"过期"。
	exp := at(2026, 10, 12, 11, 0)
	now := at(2026, 10, 12, 23, 0)
	d := Decide(DefaultPolicy(), Candidate{ScheduledAt: now.Add(-time.Hour), ExpiresAt: &exp},
		History{DeliveredToday: 99, SameKeyDeliveredToday: true}, now, sh)

	if d.Reason != ReasonExpired {
		t.Fatalf("过期应优先于预算与去重，实际 %+v", d)
	}
}

func TestPolicyValidate(t *testing.T) {
	if err := DefaultPolicy().Validate(); err != nil {
		t.Fatalf("默认策略应合法: %v", err)
	}
	bad := DefaultPolicy()
	bad.DailyBudget = -1
	if err := bad.Validate(); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("负预算应被判非法，实际 %v", err)
	}
	bad2 := DefaultPolicy()
	bad2.Cooldown = -time.Minute
	if err := bad2.Validate(); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("负冷却应被判非法，实际 %v", err)
	}
}

func TestDayKeyUsesLocalCalendarDay(t *testing.T) {
	// UTC 15:40 在上海是次日 23:40，日键必须按用户本地时区算。
	utc := time.Date(2026, 10, 12, 15, 40, 0, 0, time.UTC)
	if got := DayKey(utc, sh); got != "2026-10-12" {
		t.Fatalf("上海日键应为 2026-10-12，实际 %s", got)
	}
	if got := DayKey(utc, time.UTC); got != "2026-10-12" {
		t.Fatalf("UTC 日键应为 2026-10-12，实际 %s", got)
	}
	// 上海时间已经跨到 13 日的那一刻。
	late := time.Date(2026, 10, 12, 16, 30, 0, 0, time.UTC)
	if got := DayKey(late, sh); got != "2026-10-13" {
		t.Fatalf("上海此时应是 2026-10-13，实际 %s", got)
	}
}
