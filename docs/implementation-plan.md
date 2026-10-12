# DayCue 功能实现计划与完成矩阵

> 本文件是「先完成全部功能源码、再统一做 iOS 编译与设备验证」这一开发顺序下的主索引。
> 它回答一个问题：**每项功能目前到底走到哪一步了。**
> 最后更新：随本次交付。

## 一、为什么要调整顺序

本轮开始前，项目状态是「第一阶段（文字输入 → 结构化拆分 → 本地确认 → 写入提醒）
源码完整、后端可运行可验证，但 iOS 从未编译过」。

用户当前没有 Mac，若继续按「先编译验证再写下一块」的顺序推进，开发会彻底停住。
因此改为：

1. 先把产品规划里的功能**源码全部写完**；
2. 所有功能写完后，**一次性**在 Mac 上做编译、单测与真机验证。

这不改变交付标准，只改变顺序。**源码写完不等于功能已验收** ——
本文件第四列专门记录「还没有被真正验证过」的部分。

## 二、证据分级（贯穿全文）

| 级别 | 含义 | 本机能做到吗 |
| --- | --- | --- |
| A | 后端单元测试（Go） | ✅ 能 |
| B | iOS 核心逻辑单元测试（Swift） | ❌ 无 Swift 工具链 |
| C | App 构建（Xcode / Gradle） | ❌ 无 macOS、无 Xcode、无 Android SDK |
| D | 模拟器或真机行为（EventKit、通知、定位、相机、麦克风） | ❌ 无设备 |

**任何一列都不能冒充另一列。** 具体到本项目：

- 本机能产出 A 级证据，已实际执行；
- B/C/D 级证据**一律尚未产出**；
- 因此凡涉及 iOS、Android 的行，第四列必然是「未验证」。

## 三、阶段划分与提交点

每个阶段一个聚焦提交，作为可交接的历史节点。

| 阶段 | 内容 | 提交 |
| --- | --- | --- |
| 第一阶段（历史） | 文字输入 → 拆分 → 确认 → 写入提醒；六项真实缺陷修复 | `6ea6fab` |
| 后端基础能力 | 同步存储、认证、媒体、主动规则判定 | `d0b9e35` |
| iOS 共享契约 | 数据模型 + 本地库迁移 v2（26 张表） | `6298f2d` |
| iOS 功能实现 | 笔记、课表与追问、记忆与地点、苹果侧对账 | 见本轮后续提交 |
| 后端接口层 | PostgreSQL 实现、账号/同步/媒体/导出 HTTP 端点 | 见本轮后续提交 |
| Android 客户端 | Kotlin + Compose + Room 全量源码 | 见本轮后续提交 |
| 文档与交付 | 本文件、README、验收清单、Mac 构建步骤 | 见本轮后续提交 |

## 四、功能完成矩阵

**判定口径（本轮修订，取代此前过于宽松的写法）**：

| 状态 | 含义 |
| --- | --- |
| ✅ 源码完成 | 从**用户入口或系统事件**到**用户可见结果**的整条链在源码层面连通，每一环都有调用方 |
| ⚠️ 部分实现 | 类/函数写了，但**没有真实调用方**，或链上有一环是空实现/桩 |
| ❌ 未实现 | 尚无对应源码 |
| ⬜ 已验证 | 该列表示"在当前环境实际执行过"；只有真的跑过才写 |

**写了类但没有调用方，属于"部分实现"，不属于"源码完成"。**
本轮的主要工作就是把这个区别落实到下表：多处此前标 ✅ 的条目，因为没有调用方，本轮改标 ⚠️ 或补上了调用链后重新标 ✅。

四列含义：
**源码** = 源码与调用链是否完整；**构建** = 在当前环境是否真的编译过；
**自动测试** = 是否有自动化测试且**实际执行过**；**系统/设备验证** = 是否在真实系统或设备上验证过。

### 4.1 第一阶段（输入 → 拆分 → 确认 → 写入）

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 文字/语音/图片输入与提交 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| AI 结构化拆分（笔记/任务分离） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 日期解析（真实历法 + IANA 时区） | ✅ | ✅ Go 已构建 | ✅ Go 已执行 | ⚠️ 仅后端逻辑 |
| 确认后再写入提醒（不自动写） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 撤销 / 中断恢复 / 幂等 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 错误分类（查询失败 ≠ 不存在） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 后端 API 与端到端校验脚本 | ✅ | ✅ Go 已构建 | ✅ Go 已执行（159 用例） | ⚠️ 仅本机 HTTP |

### 4.2 笔记（持久化与记录入口）

**本轮修掉的关键断链**：`applyNoteCandidates` 此前**没有任何调用方**——确认候选时只建任务，
笔记仅作为提案 JSON 的一个字段存在，用户在笔记页看不到、改不了、删不掉。
本轮新增 `applySelectedNoteDrafts` 并接进 `ReviewView.confirm()` 与
`CaptureViewModel.autoCreate()` 两条路径，且**只落库用户勾选的笔记**。

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 笔记落库（不再是提案 JSON） | ✅ 本轮接通调用链 | ❌ 未编译 | ❌ 未运行（已编写 4 条） | ❌ 未验证 |
| 记录列表（原始输入/媒体/来源） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 记录详情（原文/转写/OCR/媒体/产出） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 笔记详情可编辑（用户编辑优先） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 重试解析不覆盖已确认笔记 | ✅ | ❌ 未编译 | ❌ 未运行（已编写） | ❌ 未验证 |
| 删除后重试不复活 | ✅ | ❌ 未编译 | ❌ 未运行（已编写） | ❌ 未验证 |
| 手动新建笔记 | ⚠️ 部分实现 | — | — | — |

> `NoteListView` 顶部注释明确写着"不放『新建笔记』入口：笔记的来源必须可追溯"，
> 而 `NoteOriginKind` 里却有 `manual` 这个取值。这是**有意的设计取舍与实现的不一致**，
> 本轮如实标为部分实现，不假装它已经可用。

### 4.3 课表与课后追问

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 手动课程与每周规则（单双周/节次/周次） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 课表图片 OCR → 候选 → 用户确认 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| ICS 导入（UTC/TZID/浮动时间/RRULE/EXDATE） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 课程实例展开（停课/调课不被覆盖） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 每门课追问开关 + 提前本地通知 | ✅ 本轮接通预算与重算 | ❌ 未编译 | ❌ 未运行（已编写 8 条） | ❌ 未验证 |
| 稍后/跳过/文字或语音回复 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 回复归档并关联课程/笔记/任务 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 建议任务需用户接受后才创建 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |

**产品限制（已写进代码注释与界面文案）**：预计结束时间 ≠ 实际下课 ≠ 出席；
追问全部是**提前排好的本地通知**，不依赖到点运行后台 AI。
本轮补上了"安排时就检查预算与静默、设置变化后重算并取消旧请求"这条链。

### 4.4 长期记忆

**本轮修掉的关键断链**：`MemoryCandidatePolicy` 与 `isRecordingEnabled` 此前只被自己引用，
`GeoRuleEvaluator`/`ProactiveBudget` 也没有运行时调用方。
本轮新增 `MemoryIngestCoordinator` 作为唯一写入入口，`MemoryDetailView` 的确认改走它
（**只有这条路才把来源升级为"用户说过"并拦冲突**），`FollowUpView` 归档后抽取。

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 候选 / 确认 / 退役 / 冲突 状态机 | ✅ 本轮接通调用链 | ❌ 未编译 | ❌ 未运行（已编写 20 条） | ❌ 未验证 |
| 来源与更新时间（明确设置 vs 推断） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 查看 / 修改 / 删除 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 按类别停止记录 | ✅ 关闭后迟到响应也不写入 | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 检索过滤（用户/权限/有效期/状态） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 删除同时清理派生索引 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 结构化 + 关键词检索优先，向量走适配器 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 未配置向量时关键词检索仍可用 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 助手回答实际使用记忆并标注来源 | ✅ | ❌ 未编译 | ❌ 未运行（已编写） | ❌ 未验证 |

### 4.5 地点与主动规则

**本轮修掉的关键断链**：系统位置事件此前没有入口。本轮新增
`LocationEventSource` → 新鲜度检查 → `GeoRuleEvaluator` → 候选 → 预算/静默/冷却/去重
→ 通知安排 → 交互回执整条链，并把权限变化、启动恢复、规则增删改后的重新注册都接上。

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 用户确认地点 / 半径 / 进入离开条件 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 地点提醒、日程 + 地点组合规则 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 新鲜度 / 去重 / 冷却 / 每日预算 / 静默时段 | ✅ 两侧都有判定 | ✅ Go 已构建 / ✅ Android 已构建 | ✅ Go 已执行 / ✅ Android 174 用例已执行 | ⚠️ 仅逻辑层 |
| 权限被拒或位置不可用时的降级 | ✅ 不显示为正常运行 | ❌ iOS 未编译 | ❌ iOS 未运行 | ❌ 未验证 |
| 通知撤销 / 延后 / 过期 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 不持续记录轨迹、不承诺室内精度 | ✅（设计约束） | — | — | ❌ 未验证 |

### 4.6 苹果侧对账与同步

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 外部完成 / 修改 / 删除 / 移动清单 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 三方比较（本地 / 外部 / 上次快照） | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 同字段冲突交用户逐项裁决 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 查询失败绝不当作「不存在」 | ✅ 快照适配层失败不折成空数组 | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 稳定标识 / 幂等 / 写入互斥 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |
| 提醒执行方切换时取消旧通知 | ✅ | ❌ 未编译 | ❌ 未运行 | ❌ 未验证 |

### 4.7 Android 客户端

**本轮最大变化：Android 不再是"只写不跑"。**
本机用 JDK 17 + Gradle 8.9（Wrapper 已入库）+ Android SDK（platform 35 / build-tools 35.0.0）
真实执行了 `:app:assembleDebug` 与 `:app:testDebugUnitTest`，**产出 app-debug.apk（11.8 MB），
174 个 JVM 单元测试全部通过、0 失败**。Room schema 由 KSP 在 `app/schemas/` 真实生成。

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| Kotlin + Compose + Room 工程骨架 | ✅ | ✅ **已构建**（assembleDebug） | ✅ 174 用例已执行 | ❌ 未验证 |
| 文字 / 录音 / 图片输入 | ✅ | ✅ 已构建 | ✅ 已执行（部分） | ❌ 未验证 |
| 笔记 / 任务 / 课表 / 追问 / 记忆 | ✅ | ✅ 已构建 | ✅ 已执行（部分） | ❌ 未验证 |
| 本地通知 / 后台任务 / 定位适配 | ✅ | ✅ 已构建 | ✅ 已执行（部分） | ❌ 未验证 |
| 无 GMS 设备能力检测与降级 | ✅ | ✅ 已构建 | ✅ 已执行 | ❌ 未验证（无真机） |
| outbox 执行路径（逐操作类型注册执行者） | ✅ 本轮接通入队点 | ✅ 已构建 | ✅ 已执行（38 用例） | ❌ 未验证 |
| 苹果提醒事项桥接 | ❌ 明确未实现 | — | — | — |

> Android 的 outbox 目标是 **App 内待办**，不存在也不伪造苹果提醒事项桥接。
> 本轮同时修掉一处界面虚报：任何"从未请求过"的状态此前被硬编码画成「已写入」徽章。

### 4.8 后端与云同步

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 账号认证（PBKDF2 + HMAC 令牌） | ✅ | ✅ Go 已构建 | ✅ Go 已执行 | ❌ 未验证 |
| 设备管理与用户数据隔离 | ✅ | ✅ Go 已构建 | ✅ Go 已执行 + 真库集成 | ❌ 未验证 |
| PostgreSQL 持久化与迁移脚本 | ✅ | ✅ Go 已构建（`-tags postgres`） | ✅ **真库集成测试 6 条已执行** | ✅ 本机 Docker PostgreSQL 16 |
| 私有媒体存储接口 | ✅ | ✅ Go 已构建 | ✅ Go 已执行 + 真库按用户清理 | ❌ 未验证 |
| 增量同步 / 版本冲突 / 删除标记 | ✅ | ✅ Go 已构建 | ✅ Go 已执行 + 真库验证冲突带服务端内容 | ❌ 未验证 |
| 客户端变更入队 / 自动重放 | ✅ 本轮接通 8 个写点 | ❌ iOS 未编译 | ❌ 未运行 | ❌ 未验证 |
| AI 对话 / 拆分 / ASR / 记忆检索适配器 | ✅ | ✅ Go 已构建 | ✅ Go 已执行（fixture） | ❌ 未接真实模型 |
| 主动候选调度 / 推送适配器 / 设备能力 | ✅ 本轮新增 internal/push + scheduler | ✅ Go 已构建 | ✅ Go 已执行（未配置时报错） | ❌ 未接真实推送通道 |
| 数据导出与删除 | ✅ | ✅ Go 已构建 | ✅ Go 已执行 | ❌ 未验证 |

> 推送适配器**没有真实凭据**：`NewAPNs`/`NewFCM` 在缺少凭据时返回
> `ErrNotConfigured`，绝不假装成功。「供应商接受请求 ≠ 用户已读」这条语义
> 由 `Status`（accepted / delivered / failed）区分承载。


## 五、未验证清单（交付时必须如实声明）

### 5.1 完全未验证

1. **iOS 从未编译**。无 macOS、无 Xcode、无 Swift 工具链。所有 Swift 源码只做过
   括号/字符串平衡扫描与人工审阅，**那不等于编译**。
2. **iOS 单元测试从未运行**。测试文件已编写，但 `swift test` 一次都没跑过。
3. **EventKit 相关行为全部未验证**：提醒的读写、清单归属、完成状态、
   `requestFullAccessToReminders()` 的真实签名与授权流程。
4. **本地通知、定位、相机、麦克风的实际行为全部未验证**。
5. **Android 从未编译**。本机无 Gradle、无 Android SDK（`ANDROID_HOME` 与
   `ANDROID_SDK_ROOT` 均未设置，默认 SDK 目录也不存在）。
6. **真实 PostgreSQL 读写未验证**：本机无 `psql`、无可用 Docker daemon，
   且 Go 模块坚持零第三方依赖，因此没有可由本机加载的数据库驱动。
   迁移脚本与 SQL 只被**装载和结构检查**过，没有被真正执行。
7. **供应商模型 / ASR 的真实调用未验证**。fixture 模式只对包含 "PV" 的输入返回
   预设结果，其余输入返回空结果 —— 它**永远不能**用来证明识别质量。

### 5.2 部分实现，需在 Mac 上补齐

- **离线队列**：服务端已支持「批量推送 + 逐条结算 + 冲突上报」，
  客户端本地已具备 outbox 表与重放逻辑（第一阶段既有）。
  但「断网时入队、恢复后自动重放」的端到端行为**未在设备上验证**。
- **推送适配器**：主动消息的**判定**（预算/静默/冷却/去重/过期）已实现并有 Go 测试；
  APNs/FCM 的实际投递**未实现也未验证**。
- **设备能力上报**：结构已就位，真实设备上报流程未验证。

### 5.3 已知风险（不是「已通过」）

- iOS 17 权限 API 签名（`AVAudioApplication.requestRecordPermission`、
  `EKEventStore.requestFullAccessToReminders()`）未经编译确认。
- XcodeGen 的 `packages: DayCueCore: path: .` 写法未经 `xcodegen generate` 确认。
- 真机访问明文 HTTP 需要 `NSAppTransportSecurity` / `NSAllowsLocalNetworking`，
  `project.yml` 中**有意未加入**，需在 Mac 上按实际联调方式决定。
- `DebugWriteFaultInjection` 用 `exit(0)` 复现中断，复现的是**状态**，
  不是真实的崩溃清理路径。

## 六、Windows 上可复现的验证步骤

### 后端（这是本机唯一能产出 A 级证据的部分）

```powershell
cd E:\PROJECT\DayCue\services\api
# 本机 C 盘空间紧张，Go 临时目录改到 D 盘
$env:GOTMPDIR='D:\gotmp'; $env:GOCACHE='D:\gocache'

gofmt -l .          # 期望：无输出
go build ./...
go vet ./...
go test ./... -count=1
```

端到端 HTTP 校验（不依赖数据库）：

```powershell
cd E:\PROJECT\DayCue
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-api.ps1
```

### iOS 静态检查（**不是**编译，不能作为可运行证据）

```powershell
cd E:\PROJECT\DayCue
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ios\static-check.ps1
```

## 七、Mac 接手后的统一构建与验证步骤

> 以下命令**在本机一次都没有执行过**。它们是给 Mac 上的执行者的操作清单，
> 不代表任何一项已经通过。

### 7.1 前置

- macOS 14 或更高，Xcode 16 或更高（含 iOS 17+ 模拟器）
- `brew install xcodegen`
- 可选：一台 iOS 17+ 真机（用于 EventKit / 通知 / 定位 / 相机 / 麦克风验证）

### 7.2 生成工程并编译

```bash
cd apps/ios
xcodegen generate                 # 若此步失败，先修 project.yml，不要手改 .xcodeproj
xcodebuild -list                  # 用真实输出确认 scheme 名称，不要猜
xcodebuild -scheme <上一步列出的 scheme> -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### 7.3 跑核心逻辑测试

核心逻辑在 `DayCueCore` 这个 SPM 包里，可以脱离 App 单独测：

```bash
cd apps/ios
swift test --package-path .
```

### 7.4 真机 / 模拟器行为验证

按 `docs/phase-1-device-acceptance.md` 的顺序逐条执行。
该文件区分了三类输入，不要混用：

- **§1.0** fixture 只对包含 "PV" 的输入返回预设结果；
- **§1A** 依赖「当前时间」的用例（相对日期）；
- **§1B** 依赖固定 fixture 绝对日期的用例（`2026-10-12T20:00:00` / `2026-10-16`）。

### 7.5 后端接真实数据库

```bash
# 1. 起一个 PostgreSQL
# 2. 由组装层引入驱动并打开 *sql.DB，交给 store.NewPostgres
# 3. 启动时执行迁移
cd services/api
go run ./cmd/daycued
```

环境变量样例见 `README.md`。**供应商密钥只放服务端环境变量，绝不进客户端。**

## 八、环境变量样例

见 `README.md` 的「环境变量」小节。要点：

- 所有供应商密钥（模型、ASR）**只从环境变量读取**，缺失时服务以
  「未配置」状态启动并如实报错，不伪造成功响应。
- 监听非回环地址时**强制要求**配置鉴权，否则拒启动。
- 云同步是**可选**的：不登录时本地记录、任务、课表、记忆全部照常可用。

## 九、当前结论

- **后端**：源码完整，本机已构建、已测试（`go test ./...` 全绿）。
  真实数据库与真实模型调用未验证。
- **iOS**：功能源码已按规划写完，**从未编译、从未运行、从未上真机**。
- **Android**：源码已写完，**从未编译**。

因此本轮的准确表述是：
**源码实现已完成到可以进入统一编译验证的程度**，
而不是「产品已运行验收通过」。

判定口径（避免后续报告再次虚高）：
- 「源码完成」= 需求里那条链从用户入口或系统事件一路通到用户可见结果，每一段都有调用方。
- 「部分实现」= 类与单元测试存在，但运行时没有调用方，或调用方是占位实现。
- 「源码完成」不等于「功能可用」；功能可用必须经过真机或真库验证。


## 十、本次交付的实际执行结果（可复核）

这一节只写**真正被执行过**的东西。凡是没有在本机跑过的，一律不出现在这里。

### 10.1 Go 后端：构建与测试（真实执行）

```
cd services/api
$env:GOTMPDIR='D:\gotmp'; $env:GOCACHE='D:\gocache'; $env:GOTOOLCHAIN='local'
gofmt -l .                    # 无输出
go build ./...                # 退出码 0
go vet ./...                  # 退出码 0
go build -tags postgres ./... # 退出码 0
go test ./... -count=1
```

结果：**159 个测试用例全部通过**（此前为 124），覆盖
`internal/{api,authn,config,e2e,extract,media,proactive,push,store,syncsvc,temporal}`。

本轮新增的两个包：

| 包 | 验证内容 |
|---|---|
| `internal/push` | 未配置时返回明确错误而非假成功；ES256 JWT 用公钥验签；APNs/FCM 状态码到失败分类的映射；重试只针对可重试失败；设备失效与普通失败区分；Router 按平台分发；失败详情不泄漏设备令牌 |
| `internal/proactive` | 调度器把纯判定接到真实推送：静默/预算/过期抑制、回执映射、批次内预算与去重累积、失败不吞掉后续项、延迟不消耗预算、按用户时区判断静默时段 |

### 10.2 PostgreSQL：**真实数据库上跑通的集成测试**

```
powershell -File scripts/db-up.ps1
# → [ok] 数据库已就绪，并经过 pg_isready 验证（不是看起来起来了）
$env:DAYCUE_TEST_DATABASE_URL='postgres://daycue:daycue@127.0.0.1:55432/daycue_test?sslmode=disable'
go test -tags postgres ./internal/store/... -count=1 -v
```

```
--- PASS: TestIntegrationMigrateIsIdempotent (0.04s)
--- PASS: TestIntegrationUserIsolation (0.08s)
--- PASS: TestIntegrationPushConflictCarriesServerContent (0.05s)
--- PASS: TestIntegrationTombstonePropagates (0.04s)
--- PASS: TestIntegrationPullCursorAdvances (0.05s)
--- PASS: TestIntegrationDeleteMediaForUserOnly (0.06s)
ok  github.com/jolaaa999/DayCue/services/api/internal/store  0.521s
```

**这 6 条是真连上数据库执行的，不是 skip。** 同一条命令先后跑两次都 PASS。
另已单独验证：移除 `DAYCUE_TEST_DATABASE_URL` 后 6 条全部输出**明确的跳过原因**，
不会静默退回内存存储再宣称持久化成功。

数据库由 `scripts/db-up.ps1` 用 Docker 启动（`postgres:16-alpine`，
容器 `daycue-postgres`，127.0.0.1:55432），并以 `pg_isready` 验证就绪。

### 10.3 iOS：静态检查（真实执行，但只能证明结构自洽）

```
powershell -File scripts/ios/static-check.ps1
```

结果：**通过 17，失败 0，未验证 4**；扫描 **142 个 Swift 文件**
（DayCueCore 60 / DayCueApp 50 / 测试 32）。

**这不等于能编译。** 它只做了三件事：目录与工程引用存在、括号在词法上平衡、
DayCueCore 没有引入 iOS 专有框架。

### 10.4 Android：**已真实构建并通过单元测试**

这是本轮最重要的变化 —— Android 从"只写不跑"变成了真实可构建的工程。

```
$env:JAVA_HOME='C:\Program Files\Java\jdk-17'
$env:ANDROID_HOME='D:\android-sdk'
cd apps/android
gradlew.bat --no-daemon --console=plain :app:assembleDebug :app:testDebugUnitTest
# → BUILD SUCCESSFUL in 1m 40s
```

- 产物：`app/build/outputs/apk/debug/app-debug.apk`，**11,793,805 字节**
- 单元测试：**174 个 JVM 用例全部通过，0 失败 0 错误 0 跳过**（15 个测试类）
- 工具链：JDK 17、Gradle 8.9（Wrapper 与 `gradle-wrapper.jar` 已入库）、
  AGP 8.7.2、Kotlin 2.0.21、KSP 2.0.21-1.0.28、Room 2.6.1、compileSdk 35 / minSdk 26
- Room schema 由 KSP 在 `app/schemas/com.daycue.android.data.local.DayCueDatabase/` **真实生成**，
  不是手工伪造的文件；`room.schemaLocation` 已配置，迁移写错会在构建期直接失败

分模块用例数（真实执行）：

| 测试类 | 用例 |
|---|---|
| OutboxProcessorTest | 19 |
| FollowUpSchedulerTest / CourseInstanceExpanderTest | 16 / 16 |
| IcsParserTest | 15 |
| GeoRuleEvaluatorTest | 13 |
| TaskRepositoryOutboxEnqueueTest / ProactiveBudgetTest / SyncReconcilerTest | 12 / 12 / 12 |
| ContractDecodingTest / ReminderOwnershipTest | 11 / 11 |
| DayCueTimeTest | 10 |
| IdempotencyKeyTest / InAppTodoReminderHandlerTest | 8 / 8 |
| OutboxRetryPolicyTest / AppOutboxExecutorTest | 6 / 5 |

**仍未验证**：没有任何一台真机或模拟器跑过这个 APK；通知弹窗、后台作业调度、
定位、录音、Room 迁移在真实设备上的行为全部未验证。

### 10.5 真实执行中暴露并修复的产品缺陷

这些是"跑起来才发现"的问题，不是靠读代码发现的：

| 缺陷 | 影响 | 修复 |
|---|---|---|
| 令牌载荷 `<userID>.<exp>` | userID 含点号时切分错位，**所有这类用户的令牌立即失效** | 改为 `<exp>.<userID>` 并加回归测试 |
| 冲突响应只有版本号 | 客户端拿不到服务端内容，**用户无法比较该保留哪一版** | 冲突时回传 `server_payload` / `server_deleted` |
| 注销账号只清库 | 磁盘上的照片与录音仍在，**隐私泄漏** | 新增按用户清理，并断言文件真的从磁盘消失 |
| `wipeAllData()` 漏表 | 清空数据后残留笔记与 v2 各表 | 按外键顺序补全 |
| 静态检查器转义判断 | 合法文件被误报，**会掩盖真实问题** | 改为按字符码比较，并补回 BOM |
| **Kotlin 注释里的 `audio/*`** | `*/ ` 提前闭合文档注释，**两个文件从第 25/62 行起全被吞掉**，Kotlin 报"Unclosed comment" | 去掉注释里的 `*/` 序列；这是第一次真正编译 Kotlin 才发现的 |
| **outbox 取消闸门拦掉 `delete_reminder`** | 任务取消或软删除后提醒**永远撤不掉** | 让 `delete_reminder` 免于取消闸门 |
| **`TaskViewModel.mutate` 注释与代码不符** | 注释声称"改状态后总是取消本地闹钟"，代码从未调用，**闹钟照响** | 真正调用 `cancelLocalAlarm` |
| **Android 徽章虚报** | 任何"从未请求过"的状态被硬编码画成「已写入」 | 渲染真实状态；标签改为「App 内待办登记」 |
| **Android 墓碑/快照钩子从未装配** | `tombstoneRecorder` 永远是 null，**删除不写墓碑**，"删除后同步不复活"无从谈起 | 在 AppContainer 装配墓碑钩子 |
| **`db-up.ps1` 两处自身缺陷** | `$User:` 被当作驱动器限定变量直接解析失败；`docker inspect` 的 stderr 在 `ErrorActionPreference=Stop` 下变成终止错误 | 改用 `$()` 子表达式与 `docker ps -a` 判断存在性 |

### 10.6 契约

`contracts/v1/` 从 4 个 schema 增至 **20 个**，新增账号注册/登录、设备、同步 push/pull、
媒体、导出、账号删除、主动候选与投递状态。字段依据
`internal/api/account*.go` 的真实结构与 json tag，错误码复用 `internal/httpx` 已有枚举。

**同步接口统一为 `POST /v1/sync/push` + `GET /v1/sync/pull`**，
设计文档中残留的 `POST /v1/sync` 写法已一并修正。

## 十一、调用方缺口与本轮补齐情况

第十一节此前列出的缺口，本轮**逐条处理**如下。判定标准不变：
**写了类但没有调用方，属于"部分实现"，不属于"源码完成"**。

| 原缺口 | 本轮处理 | 结果 |
|---|---|---|
| iOS `MemoryCandidatePolicy` 无产出方 | 新增 `MemoryIngestCoordinator`，作为记忆候选的**唯一写入入口** | ✅ 已接通 |
| iOS `isRecordingEnabled` 无调用者 | 在 ingest 路径中真正查询；**关闭类别后迟到响应也不写入** | ✅ 已接通 |
| iOS `GeoRuleEvaluator` 无位置事件源 | 新增 `LocationEventSource`（CoreLocation 适配）+ 新鲜度检查 + `GeoTriggerRunner` | ✅ 已接通 |
| iOS `ProactiveBudget` 无运行时调用点 | 由 `GeoTriggerRunner` 与 `FollowUpNotificationRunner` 在**安排通知之前**调用 | ✅ 已接通 |
| iOS 无笔记落库路径 | 新增 `applySelectedNoteDrafts` 并接进评审确认与自动创建两条路径 | ✅ 已接通 |
| iOS 无云同步客户端 | 新增 `SyncClient`/`CloudSyncReplayer`/`SyncQueue`/`CloudSyncService` + 设置页入口 | ✅ 已接通 |
| iOS 无 `noteLocalChange` 调用点 | 8 个本地写点接上（`TaskWriteService` 用注入回调，避免仓储互相持有） | ✅ 已接通 |
| Android `OutboxExecutionRegistry` 未注册执行者 | `OutboxExecutors.install` 挂到 Application；后台作业改委托 `OutboxProcessor` | ✅ 已接通 |
| Android outbox 无生产入队方 | 带提醒的任务保存入队 `create_reminder`；完成/取消/软删除/清提醒入队 `delete_reminder` | ✅ 已接通 |
| Android `GeoRuleEvaluator` 只被自己引用 | 仍缺系统位置事件源 | ⚠️ **部分实现** |
| Android `syncSnapshotWriter` 未装配 | 语义不成立（`SyncField` 不含外部 id，`task` 表也无该列），**如实保持为空并注明原因** | ⚠️ **已知缺口** |

### 11.1 仍未闭环的缺口（如实列出）

| 模块 | 现状 | 后果 |
|---|---|---|
| Android 位置事件源 | `GeoRuleEvaluator` 有纯逻辑与测试，但没有 `LocationManager` 事件驱动的调用方 | 地点规则不会被评估，也不会触发提醒 |
| `task.external_id` 未持久化 | 删除载荷里的 external_id 由 taskId 确定性推导 | 接入真实外部提供方前必须先加这一列，否则删不到对象 |
| Android 三方对账快照 | `syncSnapshotWriter` 保持为空 | 接入真实外部提供方前，三方比较缺"上次快照"基准 |
| iOS `ReconciliationCoordinator` 的入队出口 | 用进程级静态出口，因为该协调器由视图 `@StateObject` 创建、容器拿不到实例 | 功能可用，但不符合"逐实例注入"的偏好 |
| iOS 手动新建笔记 | `NoteListView` 有意不放新建入口，而 `NoteOriginKind` 有 `manual` | 设计取舍，非缺陷；但需明示 |
| `proactive-candidate` / `proactive-delivery` 契约 | 有 schema，**没有对应 HTTP 端点** | 字段按 Go 类型推导，未与真实响应比对 |

### 11.2 判定标准（不变）

一个功能只有能完整追溯下面这条链，才算源码完成：

    用户入口或系统事件 -> 业务服务 -> 存储或执行 -> 状态变化 -> 用户可见结果

缺任何一段都算断链。测试方面同理：调用链测试（关闭类别后是否真的没写入、
预算是否真的拦住了通知安排、outbox 是否真的调用了执行者）比"纯函数返回了正确的枚举值"
更有价值，也更接近真实验收。

