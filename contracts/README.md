# DayCue 契约（contracts）

这里是 iOS 客户端与 Go 后端之间**唯一**的接口事实来源。任何一方改动字段，都必须先改本目录。

| 文件 | 用途 |
|---|---|
| `v1/extraction-request.schema.json` | `POST /v1/extractions` 请求体 |
| `v1/extraction-response.schema.json` | `POST /v1/extractions` 响应体（结构化候选） |
| `v1/transcription-response.schema.json` | `POST /v1/transcriptions` 响应体 |
| `v1/error.schema.json` | 所有非 2xx 响应的统一错误体 |
| `fixtures/extract-os-pv.request.json` | 设计文档 5.1 的语音样例请求 |
| `fixtures/extract-os-pv.response.json` | 同一输入期望的候选结果（1 笔记 + 2 任务） |
| `fixtures/error.model_output_invalid.json` | 模型返回非法 JSON 时的错误样例 |

## 关键约定

1. **时间是三段信息**：原始表达 `date_expression`、解析结果 `due`/`remind`、时区 `timezone`。客户端必须把三段都展示给用户确认。
2. **绝对时刻传 UTC，浮动本地时间传 local**。`due.local` 是用户时区下的墙上时间，`due.utc` 由服务端用 IANA 时区换算，绝不由模型口算。
3. **截止时间与提醒时间分离**。`due` 可以存在而 `remind` 为 `null`（例如「周五之前」），此时必须带 `deadline_only` 歧义标记，客户端不得自行补一个提醒时刻。
4. **`mode` 字段区分真实与模拟**：`live` 表示真实模型调用，`fixture` 表示显式启用的模拟结果。客户端 UI 必须把 `fixture` 显示为「模拟结果」。
5. `ambiguities[].code` 是开放枚举，客户端遇到未知 code 时按「需要澄清」处理，不能忽略。

## 歧义码的兼容策略

`ambiguity.code` 在 schema 里是**开放字符串**而不是硬枚举，只给出已知清单：

```
deadline_only, missing_year, weekday_date_conflict, ambiguous_ampm, ambiguous_place,
unresolved_date, past_time, dst_nonexistent, dst_ambiguous, assumed_next_day, model_uncertain
```

这样做是为了让服务端将来新增歧义码时不会让旧客户端解析失败。客户端的义务是：
**遇到不认识的 code 必须当作「需要用户澄清」处理，而不是忽略。**

第一阶段服务端**实际会发出**的是其中除 `ambiguous_place` 之外的部分——
地点歧义需要先有地点解析能力，而第一阶段不做地点解析，`place_hint` 只是原样透传。
`ambiguous_place` 因此是**预留**的码，当前不会有服务端数据产生它。
