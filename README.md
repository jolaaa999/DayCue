# DayCue

主动式个人 AI 助手：把走路时的一句话、一张白板照片，变成**真实写进苹果提醒事项**的任务，并在合适的时候追问你。

> 本仓库同时是产品的技术设计与第一阶段的实现。

## 当前状态（请先读这一段）

| 部分 | 状态 |
|---|---|
| Go 后端 `services/api` | **已实现、已编译、已测试、已端到端验证**（23/23 项断言通过） |
| 契约 `contracts/` | 已落地，并由后端测试强制执行 |
| iOS 端 `apps/ios` | **源码已完成**；跨平台单元测试 **12 个文件 / 85 个用例，已运行 0 个**；**尚未编译、尚未真机验证** |
| 课表 / 课后追问 / 长期记忆 / 位置 / Android | 未实现（第二至第四阶段） |

iOS 端之所以未验证：开发环境是 Windows，没有 Xcode 与 Swift 工具链。按 Xcode 版本拼凑的"已验证"结论是不诚实的，因此这里明确标注为**未验证**，并在 [apps/ios/README.md](apps/ios/README.md) 给出了 Mac 上的完整构建与真机验证步骤。

## 它现在能做什么

1. 用文字、录音、拍照/选图记录一件事，**先落本地**，任何网络或识别失败都不丢内容。
2. 把一段话拆成「课堂笔记」和「行动任务」——只有行动意图才生成任务。
   > 「今天操作系统讲了 PV，我还是没理解，明晚八点提醒我复习，周五之前交实验报告。」
   拆成：1 条笔记 + 「复习 PV」任务（明晚 20:00）+ 「交实验报告」任务（截止 10-16，**不编造提醒时刻**）。
3. 每条候选都带**原文依据**和**完整解析日期**，用户先预览再确认。
4. 确认后写入 App 内任务，并在已授权时写入苹果提醒事项。
5. 界面如实区分「已保存到 App」/「等待写入苹果提醒事项」/「已写入苹果提醒事项」/「写入失败」——**没有系统回执就不显示已写入**。

## 仓库结构

```
contracts/                客户端与后端的接口事实来源（JSON Schema + fixture）
docs/
  product-scope.md              第一阶段范围与默认假设
  architecture.md               架构与关键取舍
  phase-1-acceptance.md         逐项验收结论（已通过 / 未通过 / 未验证）
  phase-1-device-acceptance.md  真机验收清单（需设备，未执行）
scripts/
  run-api.ps1                   本地启动后端
  verify-api.ps1                一键验收：构建 + 测试 + 真实 HTTP 端到端断言
  ios/verify-ios.sh             Mac 上一键验证：swift test + 生成工程 + 构建
  ios/static-check.ps1          Windows 上可跑的静态检查（只能证明结构自洽）
services/api/             Go 最小后端（无状态）
apps/ios/                 SwiftUI 应用（DayCueCore 跨平台逻辑 + DayCueApp 界面）
proactive-assistant-design.md   产品与技术设计原文
```

## 5 分钟跑起来（后端）

需要 Go 1.23+。**不需要任何 API Key**：

```powershell
git clone https://github.com/jolaaa999/DayCue.git
cd DayCue

# 一键验收：构建 + vet + 单元测试 + 启动真实服务 + 打真实请求 + 23 项断言
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-api.ps1

# 只想手动试一下：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-api.ps1 -Fixture
```

接真实模型（任意 OpenAI-compatible 端点）：

```powershell
$env:DAYCUE_LLM_BASE_URL = 'https://api.openai.com/v1'
$env:DAYCUE_LLM_API_KEY  = '<你的 key>'      # 只放环境变量，不要写进仓库
$env:DAYCUE_FIXTURE_MODE = '0'
go run ./services/api/cmd/daycued
```

接口详情见 [services/api/README.md](services/api/README.md)。

## iOS 端

需要 macOS + Xcode 15+ + XcodeGen：

```bash
cd apps/ios
swift test              # DayCueCore 的跨平台单元测试（不需要模拟器）
xcodegen generate       # 由 project.yml 生成 DayCue.xcodeproj
open DayCue.xcodeproj
```

> **本仓库的 iOS 端从未编译、从未在模拟器或真机运行。** 上面三条命令**都没有在本仓库执行过**。
> 开发环境是 Windows，没有 Xcode 与 Swift 工具链。

真机验收清单（EventKit 写入、权限、故障注入中断、查重分类、撤销、离线、录音、OCR）
见 [docs/phase-1-device-acceptance.md](docs/phase-1-device-acceptance.md)；
构建细节与已知风险见 [apps/ios/README.md](apps/ios/README.md)。

## 几条被代码强制执行的规则

这些不是文档里的承诺，而是写在代码和测试里的：

| 规则 | 位置 |
|---|---|
| 模型只输出「时间表达」，绝对时刻一律由确定性代码重算 | `services/api/internal/temporal`、`extract/normalize.go` |
| 「周五之前」只产生截止日，不编造提醒时刻 | `normalize.go` + `deadline_only` 歧义标记 |
| 模型编造的原文依据会被清除并标记 `model_uncertain` | `normalize.go` |
| 全部候选非法 → 报错，不返回半成品，客户端无从据此写系统 | `normalize.go`、`api/api.go` |
| 幂等键确定性生成 + 唯一索引，重复提交不产生第二条提醒 | `apps/ios/Sources/DayCueCore/Hashing.swift`、`DayCueStore+Outbox.swift` |
| 写入成功后又收到失败回执 → 只转「对账」，不回退重写 | `ExternalWriteStateMachine` |
| 非环回监听必须带令牌，生产环境禁止模拟模式 | `internal/config/Validate` |
| 日志与错误响应绝不包含用户原文和密钥 | `internal/httpx/middleware.go`、`internal/llm/openai.go` |

## 阶段路线

- **第一阶段（本仓库已完成的后端 + 已编写待验证的 iOS）**：捕获 → 整理 → 确认 → 本地任务 + 苹果提醒事项。
- 第二阶段：手动课表、课程实例、预计结束后的本地追问、回复归档。
- 第三阶段：可追溯长期记忆，查看 / 修改 / 删除，失效机制。
- 第四阶段：位置提醒、双向同步、Android 客户端。

课表结束不等于实际下课；后台任务不保证准点；位置只是区域级线索；AI 推断不会自动升级为「用户事实」。这些限制写在 [docs/product-scope.md](docs/product-scope.md)。

## 许可

见 [LICENSE](LICENSE)。
