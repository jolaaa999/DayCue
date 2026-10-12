package temporal

import (
	"testing"
	"time"

	// 内嵌 IANA 时区库，保证在 Windows 等没有系统 tzdata 的环境里也能正确换算。
	_ "time/tzdata"
)

func mustLoc(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("加载时区 %s 失败: %v", name, err)
	}
	return loc
}

func hasAmb(res Resolution, code string) bool {
	for _, a := range res.Ambiguities {
		if a.Code == code {
			return true
		}
	}
	return false
}

func TestCNNumber(t *testing.T) {
	cases := map[string]int{
		"8": 8, "12": 12, "零": 0, "一": 1, "两": 2, "八": 8,
		"十": 10, "十五": 15, "二十": 20, "二十三": 23, "三十一": 31,
		"重点": -1,
	}
	for in, want := range cases {
		if got := cnNumber(in); got != want {
			t.Errorf("cnNumber(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestResolveShanghai(t *testing.T) {
	loc := mustLoc(t, "Asia/Shanghai")

	type tc struct {
		name      string
		ref       time.Time
		expr      string
		wantKind  string
		wantLocal string
		wantUTC   string
		wantAmbs  []string
	}
	ref1 := time.Date(2026, 10, 11, 19, 30, 0, 0, loc) // 周日 19:30
	ref2 := time.Date(2026, 10, 11, 22, 0, 0, 0, loc)
	ref3 := time.Date(2026, 10, 11, 9, 0, 0, 0, loc)
	ref4 := time.Date(2026, 10, 11, 23, 30, 0, 0, loc)

	cases := []tc{
		{name: "空表达", ref: ref1, expr: "", wantKind: KindNone},
		{name: "无时间信息", ref: ref1, expr: "老师讲得很快", wantKind: KindNone, wantAmbs: []string{AmbUnresolved}},
		{name: "明晚八点", ref: ref1, expr: "明晚八点", wantKind: KindDatetime,
			wantLocal: "2026-10-12T20:00:00", wantUTC: "2026-10-12T12:00:00Z"},
		{name: "明天只有日期", ref: ref1, expr: "明天", wantKind: KindDate,
			wantLocal: "2026-10-12", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "周五之前", ref: ref1, expr: "周五之前", wantKind: KindDate,
			wantLocal: "2026-10-16", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "周五之前带上下文", ref: ref1, expr: "周五之前交实验报告", wantKind: KindDate,
			wantLocal: "2026-10-16", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "明确月日", ref: ref1, expr: "10月20日", wantKind: KindDate,
			wantLocal: "2026-10-20", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "缺年份跨年", ref: ref1, expr: "1月5日", wantKind: KindDate,
			wantLocal: "2027-01-05", wantAmbs: []string{AmbDeadlineOnly, AmbMissingYear}},
		{name: "下周一", ref: ref1, expr: "下周一", wantKind: KindDate,
			wantLocal: "2026-10-12", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "本周未到的周三", ref: ref1, expr: "周三", wantKind: KindDate,
			wantLocal: "2026-10-14", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "后天", ref: ref1, expr: "后天", wantKind: KindDate,
			wantLocal: "2026-10-13", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "相对天数", ref: ref1, expr: "3天后", wantKind: KindDate,
			wantLocal: "2026-10-14", wantAmbs: []string{AmbDeadlineOnly}},
		{name: "相对小时", ref: ref1, expr: "2小时后", wantKind: KindDatetime,
			wantLocal: "2026-10-11T21:30:00", wantUTC: "2026-10-11T13:30:00Z"},
		{name: "明早七点半", ref: ref1, expr: "明早七点半", wantKind: KindDatetime,
			wantLocal: "2026-10-12T07:30:00", wantUTC: "2026-10-11T23:30:00Z"},
		{name: "下周三下午三点", ref: ref1, expr: "下周三下午3点", wantKind: KindDatetime,
			wantLocal: "2026-10-14T15:00:00", wantUTC: "2026-10-14T07:00:00Z"},
		{name: "晚上八点", ref: ref1, expr: "晚上8点", wantKind: KindDatetime,
			wantLocal: "2026-10-11T20:00:00", wantUTC: "2026-10-11T12:00:00Z"},
		{name: "已过去的今天下午", ref: ref1, expr: "今天下午三点", wantKind: KindDatetime,
			wantLocal: "2026-10-11T15:00:00", wantUTC: "2026-10-11T07:00:00Z", wantAmbs: []string{AmbPastTime}},
		{name: "跨午夜凌晨一点", ref: ref2, expr: "凌晨1点", wantKind: KindDatetime,
			wantLocal: "2026-10-12T01:00:00", wantUTC: "2026-10-11T17:00:00Z", wantAmbs: []string{AmbAssumedNextDay}},
		{name: "未写上午下午", ref: ref3, expr: "8点", wantKind: KindDatetime,
			wantLocal: "2026-10-11T20:00:00", wantUTC: "2026-10-11T12:00:00Z", wantAmbs: []string{AmbAmpm}},
		{name: "今晚已过时刻", ref: ref4, expr: "今晚11点", wantKind: KindDatetime,
			wantLocal: "2026-10-11T23:00:00", wantUTC: "2026-10-11T15:00:00Z", wantAmbs: []string{AmbPastTime}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Resolve(c.expr, c.ref, loc)
			if got.Kind != c.wantKind {
				t.Fatalf("kind = %q, want %q", got.Kind, c.wantKind)
			}
			if c.wantLocal != "" && got.Local != c.wantLocal {
				t.Errorf("local = %q, want %q", got.Local, c.wantLocal)
			}
			if got.UTC != c.wantUTC {
				t.Errorf("utc = %q, want %q", got.UTC, c.wantUTC)
			}
			for _, code := range c.wantAmbs {
				if !hasAmb(got, code) {
					t.Errorf("缺少歧义码 %q，实得 %v", code, got.Ambiguities)
				}
			}
			if len(c.wantAmbs) == 0 && len(got.Ambiguities) != 0 {
				t.Errorf("不期望歧义，实得 %v", got.Ambiguities)
			}
		})
	}
}

func TestResolveDST(t *testing.T) {
	loc := mustLoc(t, "America/New_York")

	spring := time.Date(2026, 3, 1, 12, 0, 0, 0, loc)
	res := Resolve("3月8日凌晨2点30分", spring, loc)
	if res.Kind != KindDatetime {
		t.Fatalf("kind = %q, want datetime", res.Kind)
	}
	if !hasAmb(res, AmbDSTNonexistent) {
		t.Errorf("夏令时不存在时刻未被识别: %v", res.Ambiguities)
	}

	fall := time.Date(2026, 10, 20, 12, 0, 0, 0, loc)
	res = Resolve("11月1日凌晨1点30分", fall, loc)
	if res.Kind != KindDatetime {
		t.Fatalf("kind = %q, want datetime", res.Kind)
	}
	if !hasAmb(res, AmbDSTAmbiguous) {
		t.Errorf("夏令时重复时刻未被识别: %v", res.Ambiguities)
	}
}

func TestResolveDateNeverCarriesUTC(t *testing.T) {
	loc := mustLoc(t, "Asia/Shanghai")
	ref := time.Date(2026, 10, 11, 19, 30, 0, 0, loc)
	res := Resolve("周五之前", ref, loc)
	if res.Kind != KindDate {
		t.Fatalf("kind = %q, want date", res.Kind)
	}
	// 日期型截止日不能被伪造成 UTC 午夜，否则用户会看到偏移一天的时间。
	if res.UTC != "" {
		t.Errorf("日期型截止日不该带 UTC，实得 %q", res.UTC)
	}
	if len(res.Local) != 10 {
		t.Errorf("日期型截止日应为 YYYY-MM-DD，实得 %q", res.Local)
	}
}
