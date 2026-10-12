# services/api —— DayCue 最小后端

一个**无状态**的 Go 服务，只做两件事：

1. `POST /v1/extractions`：把一段文字整理成结构化候选（笔记 / 任务）。
2. `POST /v1/transcriptions`：把音频转写成文字（可选，未配置时明确返回 503）。

它**不**保存用户数据、**不**访问任何系统提醒或日历。所有用户数据在 iOS 本地库。

## 快速开始（不需要任何 API Key）

```powershell
cd services/api
go test ./...
go run ./cmd/daycued          # 需要先设置 DAYCUE_FIXTURE_MODE=1 才有可用结果
```

或者用仓库脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-api.ps1 -Fixture
```

一键验收（构建 + 静态检查 + 单元测试 + 真实 HTTP 端到端断言）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-api.ps1
```

## 接真实模型

```powershell
$env:DAYCUE_LLM_BASE_URL = 'https://api.openai.com/v1'   # 任意 OpenAI-compatible 端点
$env:DAYCUE_LLM_API_KEY  = '<key>'
$env:DAYCUE_LLM_MODEL    = 'gpt-4o-mini'
$env:DAYCUE_FIXTURE_MODE = '0'
go run ./cmd/daycued
```

key 只从环境变量读取，不落盘、不进日志、不回显。全部配置见 [.env.example](.env.example)。

## 安全边界（代码里强制，不是口头约定）

| 规则 | 实现位置 |
|---|---|
| 非环回地址监听且未设 `DAYCUE_AUTH_TOKEN` → 拒绝启动 | `internal/config/Validate` |
| `DAYCUE_ENV=production` 时开启模拟模式 → 拒绝启动 | `internal/config/Validate` |
| 模型只能返回"时间表达"，绝对时刻由服务端重算 | `internal/extract/normalize.go` + `internal/temporal` |
| 原文依据必须能在输入里找到，否则清除并标记 `model_uncertain` | `internal/extract/normalize.go` |
| 全部候选都不合法 → 返回 `model_output_invalid`，不返回半成品 | `internal/extract
ormalize.go` |
| 上游错误体不回传、不落日志（可能含用户原文） | `internal/llm/openai.go`、`internal/asr/openai.go` |
| 访问日志只记方法/路径/状态/耗时，不记请求体 | `internal/httpx/middleware.go` |
| 未知 JSON 字段一律拒绝（例如伪造 `user_id`） | `internal/httpx/DecodeJSON` |

## 目录

```
cmd/daycued/          进程入口、优雅关闭
internal/config/      环境变量装载与启动前安全校验
internal/httpx/       统一错误体、请求 ID、限流中间件、访问日志
internal/temporal/    确定性中文时间解析（本项目的核心资产，含最完整的测试）
internal/extract/     提示词、契约类型、模型输出的校验与归一化
internal/llm/         OpenAI-compatible 文本供应商 + 显式模拟供应商
internal/asr/         OpenAI-compatible 转写供应商 + 拒绝编造的模拟供应商
internal/api/         路由与处理函数
```

## 错误码

与 [contracts/v1/error.schema.json](../../contracts/v1/error.schema.json) 一致：

| code | HTTP | 场景 |
|---|---|---|
| invalid_request | 400 | JSON 非法、含契约外字段 |
| unauthorized | 401 | 缺少或错误的 Bearer 令牌 |
| not_found | 404 | 路径不存在 |
| payload_too_large | 413 | 超过 `DAYCUE_MAX_*_BYTES` |
| unsupported_media_type | 415 | Content-Type 不匹配 |
| unprocessable | 422 | 语义校验失败（时区非法、文本为空等）|
| rate_limited | 429 | 预留 |
| upstream_timeout | 504 | 上游超时；**记录应保留并允许重试** |
| upstream_error | 502 | 上游返回错误 |
| model_output_invalid | 502 | 模型输出无法结构化；**不得触发任何系统写操作** |
| service_unavailable | 503 | 未配置 AI 供应商 |
| internal | 500 | 兜底 |

## 关于模拟模式

`DAYCUE_FIXTURE_MODE=1` 时：

- 只对命中设计文档样例（含 "PV"）的输入返回预设拆分，其余返回空候选 + 警告；
- 响应 `mode` 字段为 `fixture`，`/v1/health` 的 `providers` 报 `fixture`；
- 转写接口**拒绝**返回任何文本，避免伪造识别结果；
- 生产环境禁止开启，服务会直接拒绝启动。

**模拟结果不是真实 AI 调用**，界面上必须显示「模拟结果」。
