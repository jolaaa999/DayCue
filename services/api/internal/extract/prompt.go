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
	b.WriteString("\n\n请只输出 JSON。")
	return b.String()
}

// SystemPrompt 暴露给测试与文档使用。
func SystemPrompt() string { return systemPrompt }
