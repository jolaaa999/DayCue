package extract

import (
	"strings"
	"time"
)

// systemPrompt 是固定指令。最重要的两条：
// 1. 模型不得做日期换算，只输出原文里的时间说法；
// 2. 区分"笔记"和"行动任务"，不要把课堂内容变成提醒。
const systemPrompt = `你是 DayCue 的信息整理引擎，把用户随手记录的一段中文内容拆成结构化候选。

只输出一个 JSON 对象，不要输出解释、Markdown 代码块或多余文字。格式：
{"items":[{"kind":"task","title":"...","detail":"...","source_evidence":"...","date_expression":"...","course_hint":"...","place_hint":"...","confidence":0.0}],"warnings":[]}

字段规则：
- kind：只有"明确的行动意图"才是 task（要交、要复习、要买、要打电话等）；课堂知识、感想、纯记录是 note。
- title：简短可执行，不超过 40 个汉字。note 用陈述性短句。
- detail：补充说明，可留空字符串。
- source_evidence：必须是原文里连续出现的一段文字，用来让用户核对依据；不允许改写或翻译。
- date_expression：只填原文里的时间说法本身（例如"明晚八点""周五之前""下周三下午三点"）。原文没有提到时间就填空字符串。
- 绝对禁止自己计算或输出任何具体日期、时刻、时间戳。日期换算由服务端完成。
- course_hint / place_hint：原文明确提到的课程名或地点名；没有就填空字符串。
- confidence：0 到 1 之间的数字，仅作参考。
- 一条输入可以拆出多条候选；没有可拆分内容时返回空 items 数组。
- 不要编造原文没有的信息。`

// outputContractReminder 是**必须随每条 user 消息一起发出去**的最小输出要求。
//
// 为什么不能只写在 system 里：这是已复现的端点兼容性问题——把契约放在 system 消息里时，
// 同一个端点返回的是 {"intent":"create_reminder",…} 这种自造结构的 JSON；同一份指令改放到
// user 消息里，输出立刻符合契约。中转内部怎么处理消息我们看不到，也不去猜；这里只按
// 「哪种请求形状在这个端点上能得到合格输出」来定。
// 对正常端点只是几行冗余指令，不影响结果。
const outputContractReminder = `
输出要求（服务端会严格校验，不符合即判为失败）：
1. 只输出一个 JSON 对象，顶层必须有 items 数组；没有可整理的内容时就用 {"items":[]}。
2. items 元素字段：kind（只能是 "task" 或 "note"）、title（不超过 40 个汉字）、detail、source_evidence（原文里的连续片段，用来核对依据）、date_expression（原文里的时间说法，没有就填空字符串）、course_hint、place_hint、confidence（0~1）。
3. 绝对不要输出任何具体日期或时刻，日期换算由服务端完成。`

// BuildUserMessage 把录入时间、时区与原文拼成用户消息。
// 明确告诉模型「不要算日期」，是为了让它把算数责任交回服务端的确定性代码。
func BuildUserMessage(req Request, recordedAt time.Time, loc *time.Location) string {
	var b strings.Builder
	b.WriteString("录入时刻（UTC）：")
	b.WriteString(recordedAt.UTC().Format(time.RFC3339))
	b.WriteString("\n用户所在时区：")
	b.WriteString(req.Timezone)
	b.WriteString("\n录入时刻（本地）：")
	b.WriteString(recordedAt.In(loc).Format("2006-01-02 15:04:05"))
	b.WriteString("\n来源类型：")
	b.WriteString(req.Source.Type)
	b.WriteString("\n\n原文：\n")
	b.WriteString(req.Source.Text)
	b.WriteString("\n")
	b.WriteString(outputContractReminder)
	b.WriteString("\n请只输出 JSON。")
	return b.String()
}

// BuildRepairMessage 是一次「有界格式纠正」用的用户消息：原文不变，附上上一轮为什么不合格。
//
// 为什么要带上失败原因：模型看到「上一次没有 items 数组」才会去改形状，
// 只重复原指令大概率再错一次。这个纠正最多做一次，见 Extract。
func BuildRepairMessage(req Request, recordedAt time.Time, loc *time.Location, reason string) string {
	var b strings.Builder
	b.WriteString(BuildUserMessage(req, recordedAt, loc))
	b.WriteString("\n\n上一轮的输出没有通过校验：")
	b.WriteString(reason)
	b.WriteString("\n请重新输出：只要一个 JSON 对象，顶层是 items 数组，字段完全按上面的要求。")
	return b.String()
}

// SystemPrompt 暴露给测试与文档使用。
func SystemPrompt() string { return systemPrompt }
