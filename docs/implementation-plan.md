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
| C | App 构建（Xcode / Gradle） | ⚠️ 一半能：Android（Gradle）✅ 能，Xcode ❌ 无 macOS、无 Xcode |
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
| 后端 API 与端到端校验脚本 | ✅ | ✅ Go 已构建 | ✅ Go 已执行（176 用例） | ⚠️ 仅本机 HTTP |

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

**上一轮修掉的关键断链**：系统位置事件此前没有入口。新增了
`LocationEventSource` → 新鲜度检查 → `GeoRuleEvaluator` → 候选 → 预算/静默/冷却/去重
→ 通知安排 → 交互回执整条链的领域 / 平台 / 数据层类。

**本轮修掉的关键断链（"写了类但没有调用方"）**：上面那些类此前**没有任何生产调用方**——
`AppContainer` 没有构造 `GeoProactiveCoordinator`，`PlatformDependencies` 里没有它，
Manifest 里没有注册 `GeoProximityReceiver` / `GeoDwellRecheckReceiver` / `ProactiveReceiptReceiver`，
`Application`、`MainActivity`、`BootCompletedReceiver`、设置页也没有任何入口。
本轮把这些全部接上：应用启动与开机重启后重建注册、回前台补偿复查、
定位总开关变化触发对账、通知点击 / 划掉写回账本。**判定依据是调用链，不是"文件是否被改过"。**

**本轮同时修掉一个真实缺陷（能力恢复后规则回不来）**：
`refreshRegistration` 在"定位能力可用"分支里执行 `switchMemory.write(当前 enabled 集合)`，
而权限被撤销→恢复的那一次，规则此刻仍全部处于暂停状态，于是写进记忆的是**空集合**：
记忆被抹掉后，用户在权限恢复后永远拿不回自己的地点规则，且没有任何报错。
修法是先按记忆恢复、再写记忆，并且只在"有记忆且当前一条都没开"（确实是被我们暂停过的签名）时才恢复。

**通知身份与预算语义**：`ProactiveInteraction.DISMISSED` 此前映射成 `CANCELLED`，
后果是 `deliveredAt` 留空 → 当日额度被**退还** → 用户越划掉越被同类提醒打扰。
现在映射成 `DELIVERED`（用户划掉的前提就是已经收到），`deliveredAt` 记的是
"交互时确认已到达"而非系统展示时刻（Android / iOS 都不提供展示回执），
"用户关闭"与"投递前应用取消"的区别由 `stateReason` 保留。iOS 侧同一处已同步修正。

**本轮补齐的编排测试**：新增 `GeoProactiveCoordinatorTest`（14 条），用替身断言的是
**调用链真的接通了**而不是纯函数算出了什么——被预算抑制时通知安排器一次都没被调用、
撤销权限时真的去注销了围栏、规则删除后那条已排上的通知真的被取消、
陈旧观测在规则求值之前就被丢弃。

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| 用户确认地点 / 半径 / 进入离开条件 | ✅ | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行（部分） | ❌ 未验证 |
| 地点提醒、日程 + 地点组合规则 | ✅ 管理界面入口已存在：地点列表 / 新建 / 编辑 / 删除 + 规则增删改与开关 | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行 | ❌ 未验证 |
| 保存坐标时记录坐标系 | ✅ Android `place.coordinate_system`（v3 迁移）/ ✅ iOS Schema v3 | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行 | ❌ 未验证 |
| 规则关联任务 | ✅ Android `geo_rule.linked_task_id`（v3 迁移）/ ❌ iOS 无此入口（**已知不对称**，见 5.2） | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行 | ❌ 未验证 |
| 界面操作后重挂围栏 / 取消已排通知 | ✅ 保存走 `onRuleChanged`，删规则与删地点走 `onRulesRemoved` | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行 | ❌ 未验证 |
| 新鲜度 / 去重 / 冷却 / 每日预算 / 静默时段 | ✅ 两侧都有判定 | ✅ Go 已构建 / ✅ Android 已构建 | ✅ Go 已执行 / ✅ Android 191 用例已执行（含 14 条编排用例） | ⚠️ 仅逻辑层 |
| 权限被拒或位置不可用时的降级 | ✅ 不显示为正常运行 | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行（含撤销权限即注销围栏） | ❌ 未验证 |
| 通知撤销 / 延后 / 过期 | ✅ | ✅ Android 已构建 / ❌ iOS 未编译 | ✅ Android 已执行（删除规则即取消已排通知） | ❌ 未验证 |
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

**Android 不再是"只写不跑"。**
本机用 JDK 17 + Gradle 8.9（Wrapper 已入库）+ Android SDK（platform 35 / build-tools 35.0.0）
真实执行了 `:app:assembleDebug`、`:app:testDebugUnitTest` 与 `:app:assembleDebugAndroidTest`，
三项全部 BUILD SUCCESSFUL。**产出 app-debug.apk（11.65 MiB）与 app-debug-androidTest.apk（721 KiB），
191 个 JVM 单元测试全部通过、0 失败、0 跳过**（17 个测试类）。Room schema 由 KSP 在 `app/schemas/` 真实生成。
`:app:assembleDebugAndroidTest` 只证明**仪器测试源码可以编译**，不代表在设备上跑过。

| 功能 | 源码 | 构建 | 自动测试 | 系统/设备验证 |
| --- | --- | --- | --- | --- |
| Kotlin + Compose + Room 工程骨架 | ✅ | ✅ **已构建**（assembleDebug） | ✅ 191 用例已执行 | ❌ 未验证 |
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
| 主动候选调度 / 推送适配器 / 设备能力 | ⚠️ 部分实现：已接生产装配与 Runner，但**没有生产者调用 EnqueueProactive** | ✅ Go 已构建 | ✅ Go 已执行（176 用例 + 真库集成） | ❌ 未接真实推送通道 |
| 数据导出与删除 | ✅ | ✅ Go 已构建 | ✅ Go 已执行 | ❌ 未验证 |

> 推送适配器**没有真实凭据**：`NewAPNs`/`NewFCM` 在缺少凭据时返回
> `ErrNotConfigured`，绝不假装成功。「供应商接受请求 ≠ 设备展示 ≠ 用户已读」
> 这条语义由 `Status` 承载：APNs / FCM 的 HTTP 2xx 一律映射成 `accepted`；
> **没有任何通道**能产生 `delivered`（二者的发送接口都不回报设备展示），
> `read` 则根本没有定义。
>
> 上一轮审查确认**尚未实现**、因此不得标成已实现的点（本轮逐条处理，结果见下）：
> 1. **本地/远程单路由去重**（设计文档 8.3 要求"同一候选只选择一个主要投递路径"）——
>    Go 调度层没有路径概念，本地通知由 iOS 侧排期，二者靠调用方约定而不是代码保证。
> 2. **安排时预算预留**——`Decide` 只读入参 `History`，预算在发送成功后由
>    `accumulateHistory` 累加，且只覆盖单批内存；多设备/并发调度会超发。
> 3. **令牌失效后取消/清理该设备的投递计划**——`Router` 只能上报
>    `MarkDeviceInvalid`，没有取消已排定投递的入口。
> 另外 `Guard` 与 `WithRetry` 在仓库里没有任何生产组装点，其行为只由单元测试覆盖。

#### 本轮对上述三点的处理（逐条说明，不合并成一句"已修复"）

**本轮结论：生产装配点已补齐，但仍缺"生产者"。**

**已接上（源码 + 真实启动入口）**：`cmd/daycued/proactive.go` 新增 `newProactiveRunner`，
按 `Router → Guard → WithRetry → Scheduler → Runner` 组装；`main.go` 用
`runCtx, cancelRun := context.WithCancel(...)` 建出与 HTTP 优雅关闭共用的生命周期，
`go pushRunner.Start(runCtx, pushInterval)` 真的启动了调度循环，退出信号时先 `cancelRun()`。
`cloudStore == nil` 时返回 `nil` runner 与说明「无数据库，主动推送调度未启动」，明确不启动而不是假装在跑。

**凭据缺失不再静默**：APNs / FCM 缺凭据（或私钥文件读不到）时注册 `push.Unconfigured`，
并 `slog.Warn` 带 `cause` 与 `missing_env` 变量名清单。环境变量：
`DAYCUE_APNS_KEY_ID` / `DAYCUE_APNS_TEAM_ID` / `DAYCUE_APNS_BUNDLE_ID` /
`DAYCUE_APNS_KEY_FILE`（或 `DAYCUE_APNS_KEY_PEM`）/ `DAYCUE_APNS_ENDPOINT`；
`DAYCUE_FCM_PROJECT_ID` / `DAYCUE_FCM_SERVICE_ACCOUNT_FILE`（或 `_JSON`）/ `DAYCUE_FCM_ENDPOINT`；
调度用 `DAYCUE_PROACTIVE_INTERVAL`（默认 1m）与 `DAYCUE_PROACTIVE_CLAIM_LIMIT`（默认 50）。

**三点逐条回应**（对应上方 1/2/3）：
1. **单路由去重**：每用户每轮只挑**一台**设备（令牌非空且 `DeviceID` 最小，确定性、不群发）。
   平台未配置的设备在适配器层被剔除——否则会挑中未配置平台、拿到 not_configured 而被判永久失败。
   边界：这解决的是「服务端多设备群发」。设计文档 8.3 说的「本地通知与远程推送二选一」
   已由候选生产者的执行方判定承担（见下方「本轮补齐」第 2 条）：
   客户端声称能本地投递时服务端让路，同一追问不会两边同时安排。
2. **预算预留与租约**：见下方「本轮补齐」第 3 条——`0003` 把 `claimed_at` 升级为完整租约，
   并新增按用户时间窗口的预留表 `proactive_budget_window`，正面修掉了「`SKIP LOCKED` 不等于
   按用户限额的原子预留」这个洞。
   **边界**：预留与租约只对共享同一 PostgreSQL 的调度进程有效；**不承诺**跨数据库或跨推送供应商的
   精确一次投递，只承诺稳定 `delivery_id` + 客户端去重 + 明确的「结果不明」态。
3. **失效设备取消**：`DeliveryResult.DeviceInvalid()` 触发 `MarkDeviceInvalid` +
   `CancelPendingForDevice`（把该设备上尚未发出的 pending 行落成 cancelled）+ 当前条 cancelled。

**本轮补齐（生产方已接入、租约与预算已重做、时区已打通）**：

1. **生产方已接入**（`internal/proactive/producer.go` + `internal/store/proactive_events.go`）：
   `Producer` 从客户端同步上来的业务事件里取到期项，按去重键幂等写入账本，
   已由 `cmd/daycued` 在 `main.go` 里用 `go pushProducer.Start(runCtx, pushInterval)` 启动。
   真实来源只有两类，且都有实测证据：
   - `task` 且载荷里的 `remind_utc` 到点、`status = 'open'`（两端客户端都同步 task）；
   - `memory` 且 `review_at` 到点、`status = 'candidate'`（**只有 iOS 端同步 memory**，
     所以纯 Android 账号查不到这类事件——这是同步范围的现状，不是缺陷）。
   **刻意不生产 `geo` 与 `follow_up`**：位置证据只在设备本地产生，服务端收不到坐标与围栏事件，
   凭「用户有地点规则」推不出「他现在到了」；课后追问根本不在同步范围内
   （两端都不推 `follow_up` / `course_instance`），为它生成候选会与客户端已排好的本地通知打架。
2. **执行方判定**（`cmd/daycued/proactive_producer.go` 的 `deviceRouteOwner`）：
   只要该用户**有任何一台**设备上报了 `notifications = true`，就认定客户端会自己本地投递，
   服务端让路；只有当所有设备都没上报该能力时服务端才接管。
   这条规则有真实依据：iOS 在能力未知时**如实省略**（`DeviceCapabilities.unknown.wire` 为空），
   所以「没有任何设备声称能投递」是会真实出现的状态，此时服务端不接管等于这条提醒没人发。
   边界：它**看不到客户端排上了但没响**（权限中途被关、进程被杀），这一类只能靠客户端下次启动自愈；
   宁可漏发也不重发——漏发是少打扰一次，重发是用户明确禁止的重复打扰。
3. **领取租约与预算预留已重做**（`0003_proactive_claim_protocol.sql`）：
   `claimed_at` 升级为完整租约（`claimed_by` / `claim_token` / `lease_expires_at` / `attempt_count` /
   `delivery_id` / `delivery_status` / `delivery_unknown_at`）。
   预算不再靠「数 `claimed_at`」：新增 `proactive_budget_window(user_id, win_start, win_end, reserved, delivered)`，
   领取时在同一事务里**先锁该用户的窗口行**（`FOR UPDATE`）再跳过别人正在领的消息行
   （`FOR UPDATE SKIP LOCKED`），于是同一用户的限额判定被串行化。
   这正面回答了「`FOR UPDATE SKIP LOCKED` + `claimed_at` 是否保证不超预算」：**不保证**——
   它只保证同一条消息不被两个 runner 领走；两个 runner 各自领走**同一用户的不同消息**时，
   各自看到的「今日已发」都还没超，用户就会被超发。窗口行上的串行化才是缺的那一环。
   释放/结算按行上存的 `budget_win_start` 精确回退预留，**绝不按当前时刻现算窗口**，
   否则用户改一次时区就能让「今天」重开、当日额度被重置。
4. **用户时区已打通**（`app_user.timezone` + `X-DayCue-Timezone`）：两个客户端本来就在每个请求上
   带这个头，而服务端此前完全忽略它。现在由 `account.go` 的鉴权中间件顺手对齐——
   用户行**已经**被读出来了，不需要为它多查一次库；只在值**不同**时写库，空值忽略
   （空串在存储层有确定语义，不能因为一个漏发头的客户端就把用户时区抹成「未知」），
   非法值只记 WARN、不失败请求。预算窗口、静默时段、每日重置都经 `UserLocation` → `localDayBounds`
   按用户时区计算，且 `localDayBounds` 用 `AddDate` 而非加 24 小时，跨夏令时才不会错一小时；
   账本里的绝对时刻一律 UTC。

**仍然没有做到的（不得当成已完成）**：
- **推送通道未用真实凭据做过端到端投递验证**：FCM 服务账号 JWT 与 APNs 通道只有单元/编译级验证。
- 单设备路由意味着多设备用户只有一台设备会收到主动推送（设计取舍，非遗漏）。
- 默认行为下**账本接近于空**：因为客户端本来就该自己本地投递，执行方判定会让路。
  这是「不要为了填满账本制造无意义消息」的直接结果，不是链路没通——
  链路已由真实 PostgreSQL 集成测试与单元测试覆盖。


## 五、未验证清单（交付时必须如实声明）

### 5.1 完全未验证

1. **iOS 从未编译**。无 macOS、无 Xcode、无 Swift 工具链。所有 Swift 源码只做过
   括号/字符串平衡扫描与人工审阅，**那不等于编译**。
2. **iOS 单元测试从未运行**。测试文件已编写，但 `swift test` 一次都没跑过。
3. **EventKit 相关行为全部未验证**：提醒的读写、清单归属、完成状态、
   `requestFullAccessToReminders()` 的真实签名与授权流程。
4. **本地通知、定位、相机、麦克风的实际行为全部未验证**。
5. ~~**Android 从未编译**~~ —— **已解除**。本机已配好 JDK 17 与 Android SDK
   （platform 35 / build-tools 35.0.0），`:app:assembleDebug`、`:app:testDebugUnitTest`、
   `:app:assembleDebugAndroidTest` 三项真实执行成功。
   **仍未验证的是"在真机/模拟器上运行"**，那一项属于第 D 级证据，本机依然做不了。
   具体地：`androidTest` 源集（含 `MigrationTest`）现在**已确认可以编译**
   （`:app:compileDebugAndroidTestKotlin` 实际执行、`MigrationTest.class` 已产出、
   `app-debug-androidTest.apk` 已打包），但**一条仪器测试都没有运行过**——
   本机没有连接任何设备或模拟器。因此 `MIGRATION_1_2` 的 DDL **从未在真实 SQLite 上执行过**。
6. ~~**真实 PostgreSQL 读写未验证**~~ —— **本轮已解除**。已引入 pgx/v5 并固定版本，
   用 Docker 起了 `postgres:16-alpine`（`scripts/db-up.ps1`，经 `pg_isready` 验证），
   6 条集成测试**真连库执行并通过**。仍未验证的是并发冲突语义与"迁移能应用于未来版本"。
7. **供应商模型 / ASR 的真实调用未验证**。fixture 模式只对包含 "PV" 的输入返回
   预设结果，其余输入返回空结果 —— 它**永远不能**用来证明识别质量。

### 5.2 部分实现，需在 Mac 上补齐

- **iOS 的地点规则与 Android 不对称**：两端都有地点与规则的管理界面
  （iOS `PlaceListView` / `PlaceEditorView`，Android `ui/place/*`），
  但两处仍未对齐：
  1. **规则关联任务**：Android v3 迁移给 `geo_rule` 加了 `linked_task_id` 并有界面入口；
     iOS 的 `geo_rule` 没有这一列，也没有选择器。
  2. **位置选择方式**：iOS 只能手工输入经纬度（初始为空，不填就拒绝保存，
     所以不会伪造坐标）；Android 有 `LocationPicker` 走设备定位。
  3. **坐标系**：两端都已在保存时记录（Android v3 迁移、iOS Schema v3），
     但 iOS 目前恒为 WGS-84，因为它的两个入口给的都是 WGS-84；
     将来接入地图选点（返回 GCJ-02）时必须在赋值处按来源改。
  这些差异不影响「不会用固定坐标或模拟成功替代用户选择」这条约束——
  两端都不会在用户没给坐标时替它编一个。
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

- **后端**：源码完整，本机已构建、已测试（`go test ./...` **176 个顶层用例全绿**）。
  **真实 PostgreSQL 已跑通**（14 条集成测试连库 PASS，含并发冲突、并发删除、旧库升级、迁移幂等、主动账本幂等入队与并发认领互斥）。
  仍未验证：真实模型 / ASR 调用、真实推送通道（无凭据）。
- **iOS**：功能源码已按规划写完，**从未编译、从未运行、从未上真机**。
  本轮只跑过静态检查（通过 17 / 失败 0 / 未验证 4），那**不等于能编译**。
- **Android**：源码已写完，**本机已真实构建并通过 197 个 JVM 单元测试**，
  产出 APK 与 androidTest APK，**197 个 JVM 用例通过**。**未在任何真机或模拟器上运行过**。
- **设备行为**：EventKit、本地通知、定位、相机、麦克风、Room 迁移在真机上的行为
  **全部未验证** —— 这是本机（Windows，无 macOS、无 Android 设备）根本无法覆盖的部分。

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

结果：Go 侧 **204 个顶层用例（含子测试 258）全部通过**（`-tags postgres` 下为 222 / 281），覆盖
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
--- PASS: TestIntegrationMigrateIsIdempotent (0.02s)
--- PASS: TestIntegrationUserIsolation (0.09s)
--- PASS: TestIntegrationPushConflictCarriesServerContent (0.05s)
--- PASS: TestIntegrationTombstonePropagates (0.05s)
--- PASS: TestIntegrationPullCursorAdvances (0.05s)
--- PASS: TestIntegrationDeleteMediaForUserOnly (0.06s)
--- PASS: TestIntegrationConcurrentSameVersionPushLosesNoData (0.20s)
--- PASS: TestIntegrationConcurrentServicePushReportsServerContent (0.14s)
--- PASS: TestIntegrationConcurrentDeleteAndStaleUpdateNoResurrect (0.22s)
--- PASS: TestIntegrationMigrationUpgradesOldDatabase (0.66s)
    --- PASS: TestIntegrationMigrationUpgradesOldDatabase/已应用0个迁移共1个 (0.22s)
    --- PASS: TestIntegrationMigrationUpgradesOldDatabase/已应用1个迁移共1个 (0.23s)
--- PASS: TestIntegrationMigrateIsIdempotentInIsolatedSchema (0.19s)
ok  github.com/jolaaa999/DayCue/services/api/internal/store  1.992s
```

**这 11 条是真连上数据库执行的，不是 skip。** 同一条命令先后跑两次都 PASS。
另已单独验证：移除 `DAYCUE_TEST_DATABASE_URL` 后 11 条全部输出**明确的跳过原因**，
不会静默退回内存存储再宣称持久化成功。

本次新增的 5 条（均已在真实库跑通）：

- `TestIntegrationConcurrentSameVersionPushLosesNoData`：4 个 goroutine 用同一 Version 并发推送共 8 轮，每轮恰好 1 方成功、其余 `ErrConflict`；服务端版本与内容等于胜者，冲突方不得覆盖。
- `TestIntegrationConcurrentServicePushReportsServerContent`：同一竞态在 syncsvc 层复现，恰好 1 条 accepted，其余 conflict 且每条都带回服务端当前版本与内容。
- `TestIntegrationConcurrentDeleteAndStaleUpdateNoResurrect`：删除与旧版本更新并发，恰好一方成功；删除成功则最终必须是墓碑，不得被旧更新复活；另有确定性补测覆盖「墓碑已提交后再来旧版本更新」。
- `TestIntegrationMigrationUpgradesOldDatabase`：在隔离 schema 里构造「只应用了前 N 个迁移」的旧库再跑完整迁移（N=0..迁移总数），断言只应用剩余脚本、版本记录齐全、已有哨兵数据不丢、最终结构与全新建库逐列一致。
- `TestIntegrationMigrateIsIdempotentInIsolatedSchema`：空 schema 连跑两遍，第二遍不应用任何脚本，版本号与 applied_at 均不被改写，表结构不变。

迁移升级用独立 schema + `search_path` 隔离，跑完 `DROP SCHEMA ... CASCADE`；已核对 `pg_namespace` 中 `it_mig_%` 残留数为 0。

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
gradlew.bat --no-daemon --console=plain :app:assembleDebug :app:testDebugUnitTest :app:assembleDebugAndroidTest
# → BUILD SUCCESSFUL
```

- 产物：`app/build/outputs/apk/debug/app-debug.apk`，**12,219,339 字节**；另有
  `app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk`，**748,899 字节**
- 单元测试：**217 个 JVM 用例全部通过，0 失败 0 错误 0 跳过**（20 个测试类）
- **APK 内容已逐条核对**：解压 dex 后确认 `ui/place/{PlaceListScreen,PlaceEditScreen,RuleEditScreen,PlaceViewModel}`
  与 `CoordinateSystem` 都在包里。只看字节数不足以证明产物是最新的代码，所以这里查的是包里的类。
- 仪器测试源码：`:app:compileDebugAndroidTestKotlin` 实际执行成功，但**一条都没运行过**（无设备）
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

### 10.5 本轮（地点界面 / 候选生产者 / 领取租约 / 时区）的真实执行结果

全部在本机执行过，命令与结果如下。

```
# Go：静态检查全绿
gofmt -l .                      # 无输出
go build ./...                  # 退出码 0
go vet ./...                    # 退出码 0
go build -tags postgres ./...   # 退出码 0
go vet  -tags postgres ./...    # 退出码 0
go test ./... -count=1          # 204 顶层 / 258 含子测试 / 0 失败 / 0 跳过

# 真实 PostgreSQL（容器 daycue-postgres 未重建、数据未清理）
$env:DAYCUE_TEST_DATABASE_URL='postgres://daycue:daycue@127.0.0.1:55432/daycue_test?sslmode=disable'
go test -tags postgres ./internal/... -count=1
# → 全部 ok；222 顶层 / 281 含子测试 / 0 失败 / 0 跳过

# Android
gradlew.bat --no-daemon --console=plain :app:assembleDebug :app:testDebugUnitTest :app:assembleDebugAndroidTest
# → BUILD SUCCESSFUL；20 个测试类 / 217 用例 / 0 失败 / 0 错误 / 0 跳过
```

**独立于 Go 编译验证的一条**：候选生产者的 SQL 与安全转换函数直接在真实 PostgreSQL 上跑过——
6 种畸形时间文本（「昨天下午」「2026-13-45T99:99:99Z」、空串、纯空格、非日期、只有日期）
全部返回 NULL 且**不抛错**，合法输入正常解析，生产者查询本体可执行。
这条必须单独验，因为它的失败模式是「一条坏数据打垮全量提醒」，
而不是某条用例红掉。

**送达前被实测抓到、随后修掉的两个真缺陷**（记录在此，避免以后重犯）：

1. **「已发起投递但结果不明」被当成「从未发起」而重新入队**：
   `BeginProactiveDelivery` 写的是 `delivery_status = 'sending'`，而回收逻辑的
   `unknown` 判定只认 `'attempted_unknown'`，于是崩溃在供应商调用中间的行会落进
   「放回待领取」分支，被重新领取并**再次发送**——正是「可能已被供应商接受时不得盲目重发」
   明令禁止的情形，也是「宁可不发也不重复打扰」那条。
   真实库上的原始现象：`TestIntegrationProactiveUnknownDeliveryIsNotResent` 报
   `结果不明的行只能延长租约，实际 {Requeued:1 Expired:0 Extended:0}`。
   修法：`unknown` 改为按一个明确的不确定集合判定，并把状态**升级**为 `attempted_unknown`、
   同时记 `delivery_unknown_at`，让「哪些行需要对账」可查询。
2. **并发领取用例的凭证断言与设计不符**：断言「每条 claim 的 `ClaimToken` 互不相同」，
   而 `claimOnce` 是**每轮领取一个 token、批内所有行共用**。
   于是任何领取者只要拿到 ≥2 条消息，该断言就恒失败（不是并发偶发）。
   修法是让断言对齐真正的不变量：同一条消息不得被两个领取者同时拿到、
   两个领取者若都有行则 token 必须不同、token 非空。

这两条都不是「测试写得不好」，第一条是真的会重复打扰用户。
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

