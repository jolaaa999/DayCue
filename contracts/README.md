# DayCue 契约（contracts）

这里是 iOS 客户端与 Go 后端之间**唯一**的接口事实来源。任何一方改动字段，都必须先改本目录。

| 文件 | 用途 |
|---|---|
| `v1/extraction-request.schema.json` | `POST /v1/extractions` 请求体 |
| `v1/extraction-response.schema.json` | `POST /v1/extractions` 响应体（结构化候选） |
| `v1/transcription-response.schema.json` | `POST /v1/transcriptions` 响应体 |
| `v1/error.schema.json` | 所有非 2xx 响应的统一错误体 |
| `v1/register-request.schema.json` | `POST /v1/auth/register` 请求体 |
| `v1/register-response.schema.json` | `POST /v1/auth/register` 响应体（201，含可选设备） |
| `v1/login-request.schema.json` | `POST /v1/auth/login` 请求体 |
| `v1/login-response.schema.json` | `POST /v1/auth/login` 响应体（200） |
| `v1/device-request.schema.json` | `POST /v1/devices` 请求体 |
| `v1/device-response.schema.json` | 单台设备响应体（`POST /v1/devices` 与导出复用） |
| `v1/device-list-response.schema.json` | `GET /v1/devices` 响应体 |
| `v1/sync-push-request.schema.json` | `POST /v1/sync/push` 请求体（逐条结算） |
| `v1/sync-push-response.schema.json` | `POST /v1/sync/push` 响应体（冲突时含服务端内容） |
| `v1/sync-pull-response.schema.json` | `GET /v1/sync/pull` 响应体 |
| `v1/media-upload-request.schema.json` | `POST /v1/media` 的 multipart 表单字段 |
| `v1/media-response.schema.json` | `POST /v1/media` 响应体（不下发 storage_key） |
| `v1/export-response.schema.json` | `GET /v1/export` 响应体（含墓碑） |
| `v1/account-delete-response.schema.json` | `DELETE /v1/account` 的 204 语义登记（无响应体） |
| `v1/proactive-candidate.schema.json` | **服务端内部模型**（不是客户端 API，无 HTTP 端点） |
| `v1/proactive-delivery.schema.json` | **服务端内部模型**（不是客户端 API，无 HTTP 端点） |
| `fixtures/extract-os-pv.request.json` | 设计文档 5.1 的语音样例请求 |
| `fixtures/extract-os-pv.response.json` | 同一输入期望的候选结果（1 笔记 + 2 任务） |
| `fixtures/error.model_output_invalid.json` | 模型返回非法 JSON 时的错误样例 |

## 服务端内部模型（不是客户端 API）

下面这些 schema **刻意没有 HTTP 端点**，它们只固定服务端内部类型的字段名：

| 文件 | 为什么没有端点 |
| --- | --- |
| `v1/proactive-candidate.schema.json` | 候选由服务端调度器产生并消费，客户端从不请求它。为「只有服务端自己调用」的模型造 REST 端点只会增加攻击面。 |
| `v1/proactive-delivery.schema.json` | 投递状态由服务端在推送后自己记账，客户端不上报。 |

**判定口径**：一个 schema 是否该有端点，取决于**客户端是否真的需要调用它**，
而不是「契约目录里有没有这个文件」。需要客户端调用的（账号、设备、同步 push/pull、
媒体、导出、账号删除）都有真实端点与认证；只有服务端用的明确标为内部模型。

> 关于「已读」：`proactive-delivery` 刻意**没有** `read` 状态。
> 即便将来某条通道回报 `delivered`，那也只能证明消息到达设备，不能证明设备展示了它，
> 更不能证明用户读过。当前实现的 APNs / FCM 发送接口都只回报"已受理"，
> 因此 `delivered` 在现有实现里不可达。没有可信的设备或用户回执时，不得标记 `delivered` 或 `read`。

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
