# DayCue

主动式个人 AI 助手：把走路时的一句话、一张白板照片，变成**真实写进苹果提醒事项**的任务，并在合适的时候追问你。

> 本仓库同时是产品的技术设计与第一阶段的实现。

## 当前状态（请先读这一段）

| 部分 | 状态 |
|---|---|
| Go 后端 `services/api` | **已实现、已编译、已测试**：**176 个顶层测试用例（含子测试 230）全部通过**（含 14 条连真实 PostgreSQL 的集成测试，覆盖并发冲突、并发删除、旧库升级、迁移幂等、主动账本幂等入队与并发认领互斥）；另有 `verify-api.ps1` 的真实 HTTP 端到端断言 |
| 契约 `contracts/` | 已落地，并由后端测试强制执行。`contracts/v1/` 共 **20 个 schema**，覆盖账号 / 设备 / 同步 push+pull / 媒体 / 导出 / 账号删除 / 主动候选与投递 |
| iOS 端 `apps/ios` | **源码已完成**：DayCueCore 60 个文件 + DayCueApp 50 个文件；测试 32 个文件；**尚未编译、尚未真机验证**（本机无 macOS / Xcode / Swift 工具链），只跑过静态检查 |
| Android 端 `apps/android` | **源码完成且已构建**：108 个 Kotlin 文件（main 91 / test 16 / androidTest 1）；`:app:assembleDebug` 产出 app-debug.apk（12,219,339 字节），`:app:assembleDebugAndroidTest` 产出 app-debug-androidTest.apk（738,455 字节），**197 个 JVM 用例全部通过、0 失败、0 跳过**（18 个测试类）；仪器测试源码已确认可编译但**一条都没运行过**（无设备）；**未在任何真机或模拟器上运行** |
| 课表 / 课后追问 / 长期记忆 / 位置与主动规则 / 苹果侧对账 | **源码已完成**（iOS 与 Android 双端）；Android 侧已编译并跑过单元测试，**iOS 侧未编译、两端均未上真机** |

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
docs/implementation-plan.md    功能完成矩阵（源码/构建/测试/设备四列）与未验证清单
services/api/             Go 后端（AI 端点 + 可选账号/同步/媒体端点）
apps/ios/                 SwiftUI 应用（DayCueCore 跨平台逻辑 + DayCueApp 界面）
apps/android/             Kotlin + Compose + Room 客户端（未编译）
proactive-assistant-design.md   产品与技术设计原文
```

## 5 分钟跑起来（后端）

需要 Go 1.24+。**不需要任何 API Key，也不需要数据库**（账号与云同步是可选能力）：

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

七个功能域（捕获与确认 / 课表与课后追问 / 长期记忆 / 位置与主动规则 / 苹果侧对账 / Android 客户端 / 后端与云同步）的**源码已在本次交付中全部完成**，逐项状态见 [docs/implementation-plan.md](docs/implementation-plan.md) 的功能完成矩阵。

矩阵分四列：源码实现 / 当前环境构建 / 自动化测试 / 系统集成或设备验证。当前的真实情况是：

- **Go 后端**：源码、构建、自动化测试三列完成；PostgreSQL 真实行为**未验证**（本机无 psql、无 Docker、默认构建不含数据库驱动）。
- **iOS / Android**：只有「源码实现」一列完成，其余三列**全部未验证** —— 本机没有 macOS、Xcode、Android SDK 与 Gradle。

**源码写完不等于功能可用**：iOS 的 EventKit 写入、定位、通知，Android 的权限与后台任务，都必须在真机上验收后才能说「可用」。

课表结束不等于实际下课；后台任务不保证准点；位置只是区域级线索；AI 推断不会自动升级为「用户事实」。这些限制写在 [docs/product-scope.md](docs/product-scope.md)。

## 许可

见 [LICENSE](LICENSE)。
