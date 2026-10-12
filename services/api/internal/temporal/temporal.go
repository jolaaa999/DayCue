// Package temporal 提供确定性的中文时间表达解析。
//
// 设计原则（对应设计文档第 7 节与 13 节）：模型只负责指出「时间表达是什么」，
// 绝对时刻一律由本包用真实日历和 IANA 时区算出。绝不让模型口算日期，
// 也不接受模型自报的解析结果，这样跨月、跨年、夏令时、跨午夜才不会出错。
package temporal

import (
	"regexp"
	"strings"
	"time"
)

// 解析结果的种类。
const (
	KindNone     = "none"
	KindDate     = "date"
	KindDatetime = "datetime"
)

// 歧义码，与 contracts/v1/extraction-response.schema.json 的枚举保持一致。
const (
	AmbDeadlineOnly    = "deadline_only"
	AmbMissingYear     = "missing_year"
	AmbWeekdayConflict = "weekday_date_conflict"
	AmbAmpm            = "ambiguous_ampm"
	AmbUnresolved      = "unresolved_date"
	AmbPastTime        = "past_time"
	AmbDSTNonexistent  = "dst_nonexistent"
	AmbDSTAmbiguous    = "dst_ambiguous"
	AmbAssumedNextDay  = "assumed_next_day"
)

// Ambiguity 是必须回传给用户确认的一个不确定点。
type Ambiguity struct {
	Code    string
	Field   string
	Message string
}

// Resolution 是一次时间解析的完整结果。
// Local 是用户时区下的墙上时间；UTC 只在 KindDatetime 时有值，
// 日期型截止日绝不伪造成 UTC 午夜。
type Resolution struct {
	Kind        string
	Local       string
	UTC         string
	Ambiguities []Ambiguity
}

func (r *Resolution) addAmb(code, field, msg string) {
	for _, a := range r.Ambiguities {
		if a.Code == code && a.Field == field {
			return
		}
	}
	r.Ambiguities = append(r.Ambiguities, Ambiguity{Code: code, Field: field, Message: msg})
}

var (
	reRelHour  = regexp.MustCompile("([0-9]{1,3}|[一二三四五六七八九十两]{1,3})(?:个?小时|个?钟头)(?:后|以后|之后)")
	reRelMin   = regexp.MustCompile("([0-9]{1,3}|[一二三四五六七八九十两]{1,3})分钟(?:后|以后|之后)")
	reRelDay   = regexp.MustCompile("([0-9]{1,3}|[一二三四五六七八九十两]{1,3})(?:天|日)(?:后|以后|之后)")
	reRelWeek  = regexp.MustCompile("([0-9]{1,3}|[一二三四五六七八九十两]{1,2})(?:周|星期)(?:后|以后|之后)")
	reRelMonth = regexp.MustCompile("([0-9]{1,3}|[一二三四五六七八九十两]{1,3})(?:个?月)(?:后|以后|之后)")
	reMonthDay = regexp.MustCompile("([0-9]{1,2})月([0-9]{1,2})[日号]")
	reSlashDay = regexp.MustCompile("(?:^|[^0-9])([0-9]{1,2})/([0-9]{1,2})(?:[^0-9]|$)")
	reWeekday  = regexp.MustCompile("(下下|下|这|本)?(?:周|星期|礼拜)([一二三四五六日天])")
	reClockHM  = regexp.MustCompile("([0-9]{1,2}):([0-9]{1,2})")
	reClockCha = regexp.MustCompile("差([0-9]{1,2}|[一二三四五六七八九十两]{1,3})分([0-9]{1,2}|[一二三四五六七八九十两]{1,3})点")
	reClockDia = regexp.MustCompile("(凌晨|清晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|夜间|晚)?([0-9]{1,2}|[一二三四五六七八九十两]{1,3})点(半|([0-9]{1,2}|[一二三四五六七八九十]{1,3})分)?")
	// 点在中文里还表示「一点点」「一点都」，这些不是时刻，必须排除。
	reNotClockSuffix = regexp.MustCompile("^(儿|都|也|钟头)")
)

// 关键词按长度从长到短排列，保证「明天晚上」先于「明天」命中。
var dayKeywords = []struct {
	kw      string
	offset  int
	evening bool
	morning bool
}{
	{"大后天", 3, false, false},
	{"明天晚上", 1, true, false},
	{"今天晚上", 0, true, false},
	{"明天早上", 1, false, true},
	{"明天上午", 1, false, true},
	{"今天早上", 0, false, true},
	{"今天上午", 0, false, true},
	{"后天", 2, false, false},
	{"明晚", 1, true, false},
	{"今晚", 0, true, false},
	{"后晚", 2, true, false},
	{"明早", 1, false, true},
	{"今早", 0, false, true},
	{"明天", 1, false, false},
	{"明日", 1, false, false},
	{"今天", 0, false, false},
	{"今日", 0, false, false},
	{"昨天", -1, false, false},
	{"昨日", -1, false, false},
	{"前天", -2, false, false},
}

type dayHint struct {
	evening bool
	morning bool
}

type clockResult struct {
	ok     bool
	hour   int
	minute int
	mod    string // "", "am", "pm", "noon"
}

// Resolve 把一句时间表达解析成结构化结果。expr 为空时返回 KindNone 且不带歧义，
// 表示用户根本没提时间，而不是解析失败。
func Resolve(expr string, ref time.Time, loc *time.Location) Resolution {
	res := Resolution{Kind: KindNone}
	if loc == nil {
		loc = time.UTC
	}
	s := normalize(expr)
	if s == "" {
		return res
	}
	localRef := ref.In(loc)
	base := time.Date(localRef.Year(), localRef.Month(), localRef.Day(), 0, 0, 0, 0, loc)
	deadline := isDeadline(s)

	// 「N 小时后」这类相对时刻不需要日期与时钟组合，先单独处理。
	if inst, ok := parseRelativeInstant(s, localRef); ok {
		return finishDatetime(res, inst, loc, localRef, false)
	}

	day, hasDay, hint, dayAmbs := parseDay(s, base, localRef)
	res.Ambiguities = append(res.Ambiguities, dayAmbs...)
	clk := parseClock(s, hint)

	if !hasDay && !clk.ok {
		res.addAmb(AmbUnresolved, "date_expression", "无法确定「"+clip(expr, 24)+"」的具体时间，需要补充。")
		return res
	}

	// 只有日期没有时刻：这是截止日，不是提醒时刻。绝不替用户编造一个提醒时间。
	if !clk.ok {
		res.Kind = KindDate
		res.Local = day.Format("2006-01-02")
		res.addAmb(AmbDeadlineOnly, "remind", deadlineMessage(expr, deadline))
		endOfDay := time.Date(day.Year(), day.Month(), day.Day(), 23, 59, 59, 0, loc)
		if endOfDay.Before(localRef) {
			res.addAmb(AmbPastTime, "due", "该日期已经过去，请确认是否要改到未来。")
		}
		return res
	}

	target := day
	if !hasDay {
		target = base
	}
	inst, ambs := combine(target, hasDay, clk, hint, localRef, loc)
	res.Ambiguities = append(res.Ambiguities, ambs...)
	return finishDatetime(res, inst, loc, localRef, hasDay)
}

func finishDatetime(res Resolution, inst time.Time, loc *time.Location, localRef time.Time, explicitDay bool) Resolution {
	// 没写日期却落在过去时按「次日」理解：晚上十点说「凌晨一点」指的是几个小时以后。
	// 写明了日期却落在过去，则不擅自挪动，交给用户确认。
	if !explicitDay && inst.Before(localRef) {
		inst = inst.AddDate(0, 0, 1)
		res.addAmb(AmbAssumedNextDay, "due", "未写日期且该时刻已过，已按次日理解。")
	}
	res.Kind = KindDatetime
	res.Local = inst.Format("2006-01-02T15:04:05")
	res.UTC = inst.UTC().Format("2006-01-02T15:04:05Z")
	if inst.Before(localRef) {
		res.addAmb(AmbPastTime, "due", "该时刻已经过去，请确认是否要改到未来。")
	}
	_ = loc
	return res
}

// combine 把「哪一天」和「几点」合成一个本地时刻，并处理 12/24 小时歧义。
func combine(target time.Time, hasDay bool, c clockResult, hint dayHint, localRef time.Time, loc *time.Location) (time.Time, []Ambiguity) {
	var ambs []Ambiguity
	hour := c.hour
	dayShift := 0

	switch c.mod {
	case "am":
		if hour == 12 {
			hour = 0
		}
	case "noon":
		hour = 12
	case "pm":
		if hour == 12 {
			// 「晚上12点」口语指午夜，属于次日 00:00。
			hour = 24
		} else if hour < 12 {
			hour += 12
		}
	default:
		switch {
		case hint.evening:
			if hour < 12 {
				hour += 12
			}
		case hint.morning:
			if hour == 12 {
				hour = 0
			}
		case hour <= 12:
			// 完全没写上午/下午：先合成两个候选，再挑一个不早于当前时刻的。
			h12 := hour % 12
			first, a1 := buildLocal(target.Year(), target.Month(), target.Day(), h12, c.minute, loc)
			second, a2 := buildLocal(target.Year(), target.Month(), target.Day(), h12+12, c.minute, loc)
			ambs = append(ambs, a1...)
			ambs = append(ambs, a2...)
			ambs = append(ambs, Ambiguity{Code: AmbAmpm, Field: "due", Message: "没有写明上午或下午，已按不早于当前时刻的解释处理。"})
			if !second.Before(localRef) && (first.Before(localRef) || second.Before(first)) {
				return second, ambs
			}
			if first.Before(localRef) && second.Before(localRef) {
				return second, ambs
			}
			return first, ambs
		}
	}

	if hour >= 24 {
		hour -= 24
		dayShift = 1
	}
	inst, a := buildLocal(target.Year(), target.Month(), target.Day(), hour, c.minute, loc)
	ambs = append(ambs, a...)
	if dayShift == 1 {
		inst = inst.AddDate(0, 0, 1)
	}
	_ = hasDay
	return inst, ambs
}

// buildLocal 构造本地时刻，并识别夏令时导致的不存在/重复时刻。
func buildLocal(y int, mo time.Month, d, h, mi int, loc *time.Location) (time.Time, []Ambiguity) {
	t := time.Date(y, mo, d, h, mi, 0, 0, loc)
	var ambs []Ambiguity
	if t.Year() != y || t.Month() != mo || t.Day() != d || t.Hour() != h || t.Minute() != mi {
		ambs = append(ambs, Ambiguity{Code: AmbDSTNonexistent, Field: "due", Message: "该本地时间因夏令时不存在，已顺延到有效时刻。"})
		return t, ambs
	}
	// 秋季回拨时同一墙上时间对应两个 UTC 时刻：前后各挪一小时，
	// 若墙上时间不变，说明这个本地时间在当天出现了两次。
	if sameWallClock(t.Add(time.Hour).In(loc), t) || sameWallClock(t.Add(-time.Hour).In(loc), t) {
		ambs = append(ambs, Ambiguity{Code: AmbDSTAmbiguous, Field: "due", Message: "该本地时间因夏令时出现两次，需要用户确认具体时刻。"})
	}
	return t, ambs
}

func sameWallClock(a, b time.Time) bool {
	return a.Year() == b.Year() && a.Month() == b.Month() && a.Day() == b.Day() &&
		a.Hour() == b.Hour() && a.Minute() == b.Minute()
}

func parseRelativeInstant(s string, localRef time.Time) (time.Time, bool) {
	if m := reRelHour.FindStringSubmatch(s); m != nil {
		if n := cnNumber(m[1]); n >= 0 {
			return localRef.Add(time.Duration(n) * time.Hour), true
		}
	}
	if m := reRelMin.FindStringSubmatch(s); m != nil {
		if n := cnNumber(m[1]); n >= 0 {
			return localRef.Add(time.Duration(n) * time.Minute), true
		}
	}
	return time.Time{}, false
}

func parseDay(s string, base, localRef time.Time) (time.Time, bool, dayHint, []Ambiguity) {
	var ambs []Ambiguity
	var hint dayHint

	if m := reRelDay.FindStringSubmatch(s); m != nil {
		if n := cnNumber(m[1]); n >= 0 {
			return base.AddDate(0, 0, n), true, hint, ambs
		}
	}
	if m := reRelWeek.FindStringSubmatch(s); m != nil {
		if n := cnNumber(m[1]); n >= 0 {
			return base.AddDate(0, 0, n*7), true, hint, ambs
		}
	}
	if m := reRelMonth.FindStringSubmatch(s); m != nil {
		if n := cnNumber(m[1]); n >= 0 {
			return base.AddDate(0, n, 0), true, hint, ambs
		}
	}

	// 明确写出的月日：缺年份时按「不早于今天」的最近一次理解。
	if m := reMonthDay.FindStringSubmatch(s); m != nil {
		if mo, day := cnNumber(m[1]), cnNumber(m[2]); mo >= 1 && mo <= 12 && day >= 1 && day <= 31 {
			t := time.Date(localRef.Year(), time.Month(mo), day, 0, 0, 0, 0, localRef.Location())
			if t.Before(base) {
				t = t.AddDate(1, 0, 0)
				ambs = append(ambs, Ambiguity{Code: AmbMissingYear, Field: "due", Message: "原文没有年份，已按下一年的同一日期理解。"})
			}
			if conflictWeekday(s, t) {
				ambs = append(ambs, Ambiguity{Code: AmbWeekdayConflict, Field: "due", Message: "日期与星期不一致，已以明确写出的日期为准。"})
			}
			return t, true, hint, ambs
		}
	}
	if m := reSlashDay.FindStringSubmatch(s); m != nil {
		if mo, day := cnNumber(m[1]), cnNumber(m[2]); mo >= 1 && mo <= 12 && day >= 1 && day <= 31 {
			t := time.Date(localRef.Year(), time.Month(mo), day, 0, 0, 0, 0, localRef.Location())
			if t.Before(base) {
				t = t.AddDate(1, 0, 0)
				ambs = append(ambs, Ambiguity{Code: AmbMissingYear, Field: "due", Message: "原文没有年份，已按下一年的同一日期理解。"})
			}
			return t, true, hint, ambs
		}
	}

	if m := reWeekday.FindStringSubmatch(s); m != nil {
		t, ok := resolveWeekday(m[1], m[2], base, localRef)
		if ok {
			return t, true, hint, ambs
		}
	}

	for _, k := range dayKeywords {
		if strings.Contains(s, k.kw) {
			hint.evening = k.evening
			hint.morning = k.morning
			return base.AddDate(0, 0, k.offset), true, hint, ambs
		}
	}
	return time.Time{}, false, hint, ambs
}

// resolveWeekday 按「周一为一周之始」的中文习惯计算目标日期。
func resolveWeekday(prefix, wd string, base, localRef time.Time) (time.Time, bool) {
	table := map[string]int{"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 0, "天": 0}
	target, ok := table[wd]
	if !ok {
		return time.Time{}, false
	}
	refWd := int(localRef.Weekday()) // 0=周日
	monday := base.AddDate(0, 0, -((refWd + 6) % 7))
	t := monday.AddDate(0, 0, (target+6)%7)

	switch prefix {
	case "下":
		t = t.AddDate(0, 0, 7)
	case "下下":
		t = t.AddDate(0, 0, 14)
	case "这", "本":
		// 保持本周
	default:
		// 没写前缀：本周内还没到就本周，已经过了就下周。
		if t.Before(base) {
			t = t.AddDate(0, 0, 7)
		}
	}
	return t, true
}

func conflictWeekday(s string, t time.Time) bool {
	m := reWeekday.FindStringSubmatch(s)
	if m == nil || reMonthDay.FindStringSubmatch(s) == nil {
		return false
	}
	table := map[string]int{"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 0, "天": 0}
	wd, ok := table[m[2]]
	if !ok {
		return false
	}
	return int(t.Weekday()) != wd
}

func parseClock(s string, hint dayHint) clockResult {
	// 24 小时制写法最明确，优先。
	if m := reClockHM.FindStringSubmatch(s); m != nil {
		h, mi := cnNumber(m[1]), cnNumber(m[2])
		if h >= 0 && h <= 24 && mi >= 0 && mi <= 59 {
			return clockResult{ok: true, hour: h % 24, minute: mi, mod: "am"}
		}
	}
	if m := reClockCha.FindStringSubmatch(s); m != nil {
		mi, h := cnNumber(m[1]), cnNumber(m[2])
		if mi > 0 && mi < 60 && h > 0 && h <= 24 {
			return clockResult{ok: true, hour: (h - 1 + 24) % 24, minute: 60 - mi, mod: "am"}
		}
	}
	// 「X点」需要在多个匹配里挑一个真正表示时刻的，跳过「一点儿」「一点都」。
	idx := 0
	for idx < len(s) {
		loc := reClockDia.FindStringSubmatchIndex(s[idx:])
		if loc == nil {
			break
		}
		mod := ""
		if loc[2] >= 0 {
			mod = s[idx+loc[2] : idx+loc[3]]
		}
		hourStr := s[idx+loc[4] : idx+loc[5]]
		hour := cnNumber(hourStr)
		minute := 0
		if loc[6] >= 0 {
			tail := s[idx+loc[6] : idx+loc[7]]
			if tail == "半" {
				minute = 30
			} else if loc[8] >= 0 {
				minute = cnNumber(s[idx+loc[8] : idx+loc[9]])
			}
		}
		after := s[idx+loc[1]:]
		// 命中「一点儿」「一点都」这类副词时不算时刻，继续往后找。
		if hour >= 0 && hour <= 24 && minute >= 0 && minute < 60 && !reNotClockSuffix.MatchString(after) {
			return clockResult{ok: true, hour: hour, minute: minute, mod: meridiemOf(mod)}
		}
		idx += loc[1]
		if loc[1] == 0 {
			idx++
		}
	}
	return clockResult{}
}

func meridiemOf(mod string) string {
	switch mod {
	case "凌晨", "清晨", "早上", "早晨", "上午":
		return "am"
	case "中午":
		return "noon"
	case "下午", "傍晚", "晚上", "夜里", "夜间", "晚":
		return "pm"
	default:
		return ""
	}
}

func isDeadline(s string) bool {
	if strings.Contains(s, "之前") || strings.Contains(s, "以前") || strings.Contains(s, "截止") || strings.Contains(s, "为止") {
		return true
	}
	return strings.HasSuffix(s, "前")
}

func deadlineMessage(expr string, deadline bool) string {
	if deadline {
		return "「" + clip(expr, 24) + "」表示的是截止日，尚未设置提醒时间。"
	}
	return "只有截止日期，尚未设置提醒时间。"
}

// normalize 做全角转半角与去空白，避免「８点」「明 晚 八 点」这类写法解析失败。
// normalize 做全角转半角与去空白，避免「８点」「明 晚 八 点」这类写法解析失败。
func normalize(s string) string {
	s = strings.TrimSpace(s)
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case r >= '０' && r <= '９':
			b.WriteRune(r - '０' + '0')
		case r == '：':
			b.WriteRune(':')
		case isSkippableSpace(r):
			// 空白直接丢弃：中文口语里的时间表达常被空格切开
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// isSkippableSpace 用码点而不是转义字符书写，避免控制字符在不同工具链之间被二次转写。
func isSkippableSpace(r rune) bool {
	switch r {
	case 0x20, 0x09, 0x0A, 0x0D, 0x3000:
		return true
	}
	return false
}

func clip(s string, n int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= n {
		return string(r)
	}
	return string(r[:n]) + "…"
}
