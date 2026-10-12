# DayCue 第一阶段验收报告

生成时间：2026-10-11（Asia/Shanghai）
对应代码：工作区版本（基线提交 `d0a2d16`，本次交付内容尚未 commit）

---

## 0. 一句话结论

**Go 后端：可复现验证通过。** 29 个单元用例 + 23 项端到端断言全部通过，
请求 fixture 经真实服务后与响应 fixture 逐字段一致。

**iOS 端：源码完成、静态检查通过，但从未编译、从未在模拟器或真机运行。**
本机是 Windows，没有 Swift 工具链与 Xcode，因此 iOS 的全部运行期结论都是**未验证**。

**累计六个真实修复**（见第 3 节）：

1. 并发写入互斥闸门（同一任务不会因连点创建两条提醒）；
2. 进程中断后的启动恢复（不再有任务永远停在中间态）；
3. 查重结论三分化——**"查不了"不再被当成"没找到"继续创建**，并纳入已完成项查重；
4. 迟到解析结果绑定输入版本，过期候选不能被确认成任务；
5. 撤销入口纳入同一把互斥闸门，outbox 真正进入 `running`；
6. 仅 Debug 的故障注入点，把几十毫秒的中断窗口变成可重复测试。

---

## 1. 验收环境

| 项 | 值 |
|---|---|
| 操作系统 | Windows（中文），Windows PowerShell 5.1 |
| Go | go1.24.4 windows/amd64 |
| macOS / Xcode / swift / xcodegen | **均不存在** |
| bash | 不可用（WSL 未安装发行版，无 Git bash） |
| 后端依赖 | 仅 Go 标准库，可完全离线构建 |
| 磁盘 | C: 盘可用空间为 0；Go 默认把临时编译产物放 C:，`go test` 链接阶段会报 `not enough space on the disk` |

> 上述 Go 测试与 E2E 结果是把 `GOTMPDIR` 与 `GOCACHE` 指到 D: 盘后取得的；
> 磁盘写满会表现为「测试失败」，但那是环境问题而非代码回归，重新执行即可复现通过。

**因此本机能提供的 iOS 证据只有两类：静态检查 + 源码事实。**
编译、测试运行、模拟器与真机行为，一律必须在 macOS 上补做。

---

## 2. 四类证据的边界

验收不再笼统地说"已验证"，而是分四类分别记录，且**不允许互相冒充**：

| 证据类型 | 在本机能否获得 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| **A. 后端单元测试** | ✅ 可以 | Go 逻辑、契约一致性、时间解析 | 任何 iOS 行为 |
| **B. iOS 核心逻辑测试** | ❌ 需要 macOS 的 `swift test` | DayCueCore 的状态机、SQLite、幂等键、编辑保护 | EventKit 真实写入、UI 表现 |
| **C. App 构建证据** | ❌ 需要 macOS 的 `xcodegen` + `xcodebuild` | 能否编译通过、工程配置正确 | 运行时行为 |
| **D. 模拟器/真机行为证据** | ❌ 需要设备 | 权限、写入、录音、OCR、通知的真实表现 | 不适用于逻辑正确性 |

> 本机所有 iOS 条目最多只能拿到 **C 的前置**（静态检查）与 **B 的源码事实**。
> 因此 B、C、D 三类一律记「未验证」，**不因为代码存在就推断通过**。

---

## 3. 实际修复（六个真实缺陷）

这六个问题都是**读源码发现的**，不是重跑静态检查发现的，且都会直接造成用户可见的错误。
3.1–3.2 来自上一轮，3.3–3.6 来自本轮。

> 阅读提示：3.1 与 3.3 里出现的 `findReminder` 是**修复前**的函数名，
> 它现在叫 `lookupReminder`，返回类型也从 `EKReminder?` 换成了带结论的 `ReminderLookup`。
> 保留旧名是为了让"问题是什么"读得清楚。

### 3.1 并发写入没有互斥，可能创建重复提醒

**问题**：`TaskWriteService.applyExternalWrite` 会 `await reminders.findReminder(forTaskId:)`。
await 会让出主 actor，于是用户**连点两次**「确认」或「重试写入」时，
两次调用可能都在查询阶段看到"系统里还没有这条提醒"，然后**各自创建一条**。

数据库层的幂等键只能保证「同一个 key 在 outbox 里只有一行」，
它拦不住「两个执行者同时决定去写」。

**修复**：新增 `DayCueCore/InFlightWriteGuard.swift`（actor），
把「写」变成以 taskId 为键的临界区。抢不到闸门时返回
「这条任务正在写入苹果提醒事项，请稍候」，而**不是**发起第二次系统写入。
写入流程拆成 `applyExternalWrite`（抢闸门/释放）与 `performExternalWrite`（干活），
保证所有出口都会释放闸门。

### 3.2 进程中断后没有恢复，且恢复代码是死代码

**问题**：`runnableOutboxOperations` 与 `requeueStaleOutboxOperations`
在仓库里**没有任何调用方**。也就是说：

- App 被杀在「苹果侧已写入、本地回执未落库」的中途时，任务永远停在 `pending`，
  除非用户自己想到去点「重试写入」；
- 状态是 `unknown`（连写没写都不知道）的任务**永远不会**进入对账，
  用户也不会在界面上看到它。

**修复**：

- 新增 `recoverInterruptedWrites()`，在启动与回到前台时调用；
- 待重试任务取**两个来源的并集**：outbox 里可执行的操作（持久化调度依据）
  + 任务自身停在 `pending`（覆盖"入队前就崩了"的情况）；
- `unknown` 的**不自动重写**，只降级为 `needsReconciliation`，
  让今天页的「同步异常」分区能把它显示出来——这正是不显示假成功的要求；
- 新增 `pendingExternalWriteTasks()` / `unknownExternalWriteTasks()` /
  `markUnknownWritesForReconciliation()` 三个仓储方法（Core，可在 macOS 测试）。

**安全性论证**：自动重试之所以安全，是因为 `ReminderService.createReminder`
在真正创建**之前**会先按备注里的稳定任务 ID 调 `lookupReminder(forTaskId:)` 查重，
查到就复用；并且**只有"查询成功、范围完整、确实没有"这一种结论才允许创建**
（见 3.3 的三分化修复）。这条路径本身**没有**被自动化测试覆盖
（它在 App target，依赖 EventKit），必须由真机清单第 6.2 条验证。

### 3.3（本轮）查重把"查不到"和"查不了"混为一谈

**问题**：`ReminderService.findReminder(forTaskId:)` 返回 `EKReminder?`，
把五种情况折叠成了一个 nil：

| 真实情况 | 旧返回值 | 旧代码的后续动作 |
|---|---|---|
| 找到了 | 对象 | 复用，正确 |
| 查询成功且确实没有 | nil | 创建，正确 |
| 没有权限 | nil | **创建**（应为等待授权） |
| 查询失败 | nil | **创建**（应停止） |
| 只查了一部分 | nil | **创建**（应停止） |

而且它只用了 `predicateForReminders(in: nil)`，**不含已完成项**。
用户在苹果侧勾掉一条再点重试，就会被当成"不存在"，于是重建一条。

**修复**：新增 `ReminderLookupPolicy`（Core，可测），把结论拆成
`found / notFound / notAuthorized / queryFailed / incompleteScope`，
**只有 `notFound` 允许继续创建**。`ReminderService` 改为查两段
（未完成 + 已完成）并分别回传"是否成功"，`performExternalWrite` 的失败回查
同样按这个三分法处理：查不了就转 `needsReconciliation`，绝不自动重写。
权限在写入途中被撤销时改为进 `waitingForPermission`，而不是记成失败。

### 3.4（本轮）迟到的解析结果可以被确认成任务

**问题**：`parse()` 里没有请求标识。同一个 capture 被重复解析、
或用户重试解析时，**慢的旧响应会覆盖快的新响应**写入 `reviewContext`；
预览被关掉之后晚到的响应还会把预览重新弹出来。候选与输入之间没有绑定关系，
用户可能对着一份过期结果点确认。

（补充事实：`updateCaptureUserText` 在生产代码里**零调用**，
所以"编辑正文后迟到覆盖"这条路径目前不可达；可达的是上面的重放与并发。）

**修复**：新增 `CaptureInputVersion` + `ExtractionFreshnessPolicy`（Core，可测）。
解析请求带上序号与输入指纹（正文 + 录入时间 + 用户编辑标记）。
结果到达时先判定新鲜度：`superseded` 直接丢弃且不碰界面状态，
`inputChanged` 丢弃并提示重新解析，只有 `current` 才落库与展示。
`ReviewContext` 携带输入版本，**确认时再校验一次**；
关闭预览 / 完成 / 重置都会作废在途响应。

### 3.5（本轮）互斥闸门没有覆盖撤销入口、outbox 从未进入 running

**问题**：`undo` 直接调用 `reminders.deleteReminder`，**不经过写入闸门**，
用户可能在写入进行中删掉外部对象。同时 outbox 从未被置为 `running`，
`requeueStaleOutboxOperations` 永远没有东西可恢复。

**修复**：`undo` 拆成"抢闸门 + `performUndo`"，与创建共用同一把闸门；
写入前把 outbox 置为 `running`，中断后由启动恢复重新排队。

### 3.6（本轮）中断窗口无法复现

**问题**："外部已写入、本地回执未落库"的窗口只有几十毫秒，
靠人工强杀几乎不可能命中，所以这个状态**从来没有被验证过**。

**修复**：新增仅 Debug 编译的 `DebugWriteFaultInjection`，
在 `createReminder` 返回之后、`upsertExternalBinding` 之前插入中断点，
并在设置页提供开关。真机验收清单第 6.2 节据此变成可重复步骤。

### 3.7（本轮）故障注入会反复触发，导致 App 装上就打不开

**问题**：`DebugWriteFaultInjection.haltIfEnabled()` 只**读**开关就 `exit(0)`，
从不消费它。于是：注入点触发 → 退出 → 重启 → 启动恢复重试 → **再次命中同一注入点** → 退出……
App 会陷入"每次启动都退出"的死循环。

**修复**：把"一次性"这条不变量提到 Core（`OneShotSwitch`，可在 macOS 上测），
注入点改成**先消费、落盘、再退出**（`UserDefaults.synchronize()` 显式写回），
顺序固定为「消费 → 落盘 → 写日志 → 退出」。真机清单 §6.2 增加了
"重启后不应再次退出，且开关已自动关闭"的确认项。

**Release 隔离**（已核对，三处都在 `#if DEBUG` 内，Release 里没有可触发入口）：

| 位置 | 隔离方式 |
|---|---|
| `DebugWriteFaultInjection.swift` | 整个文件被 `#if DEBUG` 包住，首行 `#if DEBUG`、末行 `#endif` |
| `TaskWriteService.swift:348-351` | 调用点单独用 `#if DEBUG` 包住 |
| `SettingsView.swift` | `@State` 声明、`debugSection` 与 body 里的引用共 3 处 `#if DEBUG` |

### 3.8（本轮）文档统计与实际不符

根 README 写着"50 个文件、含 7 个单元测试文件"和"22 项断言"，
实际是 21 + 24 个源文件、13 个测试文件，以及 **23** 项断言。

**修复**：删掉会持续漂移的**文件数与行数**，只保留**测试数量**，
并把「写了多少」与「跑了多少」分开写（13 个文件 / 89 个用例 → 已运行 **0** 个）。

---

## 4. 结论总表

每项按四类证据分别标注：**A** 后端单元测试 / **B** iOS 核心逻辑测试 /
**C** App 构建 / **D** 模拟器或真机行为。

| # | 验收项 | A 后端 | B iOS 逻辑 | C App 构建 | D 真机行为 | 综合 |
|---|---|---|---|---|---|---|
| 1 | 文字形成 1 笔记 + 多任务 | 已通过 | 未验证 | 未验证 | 未验证 | **部分通过** |
| 2 | 日期 / 相对日期 / 缺提醒时间 / 跨午夜 | 已通过 | 未验证 | 未验证 | 未验证 | **部分通过** |
| 3 | 离线保存与恢复 | 不适用 | 未验证 | 未验证 | 未验证 | **未验证** |
| 4 | AI 超时 / 非法 JSON / 坏日期不触发系统写 | 已通过 | 未验证 | 未验证 | 未验证 | **部分通过** |
| 5 | 拒绝权限时任务仍在 App | 不适用 | 未验证 | 未验证 | 未验证 | **未验证** |
| 6 | 重复提交不创建重复提醒 | 不适用 | 未验证 | 未验证 | 未验证 | **未验证** |
| 7 | 苹果侧写入失败不显示成功 | 不适用 | 未验证 | 未验证 | 未验证 | **未验证** |
| 8 | 用户编辑不被迟到结果覆盖 | 不适用 | 未验证 | 未验证 | 未验证 | **未验证** |
| 9 | 无真实 API Key 泄漏 | 已通过 | 未验证 | 不适用 | 不适用 | **已通过** |

**统计：已通过 1 项，部分通过 3 项，未验证 5 项，未通过 0 项。**

「B iOS 逻辑」全部是未验证，即使本轮新增了测试：**写了测试但没有 macOS 环境运行它们**。
测试数量写在纸上不构成证据——这正是本报告要避免的推断。

---

## 5. 逐项证据

### 验收项 1：一段文字形成 1 条笔记 + 多条任务候选

**后端：已通过。** 输入设计文档中的样例原句，实测返回 3 条候选（1 笔记 + 2 任务）。

证据一：`scripts/verify-api.ps1` 实测输出片段

```
  [通过] 拆出 3 条候选（1 笔记 + 2 任务）
  [通过] 第 1 条是笔记
  [通过] 第 2 条是任务
  [通过] 响应标记 mode=fixture
```

证据二：契约 fixture 被测试逐字段比对。`services/api/internal/extract/extract_test.go` 中的
`TestNormalizeMatchesContractFixture` 读取 `contracts/fixtures/extract-os-pv.response.json`，
与实现输出做 `reflect.DeepEqual`；任何字段漂移都会让测试变红。

证据三：`contracts/fixtures/extract-os-pv.response.json` 的实际内容（节选）

```json
{
  "schema_version": "1.0",
  "capture_id": "cap_fixture_os_pv",
  "mode": "fixture",
  "items": [
    {
      "item_id": "itm_1",
      "kind": "note",
      "title": "操作系统讲到 PV 操作",
      "source_evidence": "今天操作系统讲了 PV 操作，我还是没理解",
      "due": { "kind": "none", "local": null, "utc": null, "timezone": null },
      "remind": null,
      "course_hint": "操作系统",
      "ambiguities": [],
      "confidence": 0.92
    },
    {
      "item_id": "itm_2",
      "kind": "task",
      "title": "复习操作系统 PV 操作",
      "source_evidence": "明晚八点提醒我复习",
      "date_expression": "明晚八点",
      "due": { "kind": "datetime", "local": "2026-10-12T20:00:00", "utc": "2026-10-12T12:00:00Z", "timezone": "Asia/Shanghai" },
      "remind": { "kind": "absolute", "local": "2026-10-12T20:00:00", "utc": "2026-10-12T12:00:00Z", "timezone": "Asia/Shanghai" },
      "ambiguities": [],
      "confidence": 0.88
    },
    {
      "item_id": "itm_3",
      "kind": "task",
      "title": "交实验报告",
      "source_evidence": "周五之前交实验报告",
      "date_expression": "周五之前",
      "due": { "kind": "date", "local": "2026-10-16", "utc": null, "timezone": "Asia/Shanghai" },
      "remind": null,
      "ambiguities": [
        { "code": "deadline_only", "field": "remind", "message": "「周五之前」表示的是截止日，尚未设置提醒时间。" }
      ],
      "confidence": 0.8
    }
  ],
  "warnings": []
}
```

注意第 1 条：**课堂内容被整理成笔记，而不是任务**。第 3 条：**没有编造提醒时刻**。

**iOS 端：未验证。** `ReviewView.swift` / `ReviewDraft.swift` 已实现多候选预览与逐条确认，
但从未编译运行。见第 6 节的 Mac 补验步骤。

---

### 验收项 2：明确日期、相对日期、缺少提醒时间、跨午夜

**后端：已通过。** `services/api/internal/temporal/temporal_test.go` 为表驱动测试，
基准时刻为 `2026-10-11（周日）` 的多个时点。

覆盖到的用例（节选自测试文件）：

| 类别 | 表达式 | 基准时刻 | 期望 |
|---|---|---|---|
| 相对日 | `明天` | 周日 19:30 | 日期型 2026-10-12 |
| 相对日 | `后天`、`3天后` | 周日 19:30 | 日期型 |
| 相对周 | `下周一`、`周三`、`下周三下午3点` | 周日 19:30 | 日期型 / 日期时刻型 |
| 相对小时 | `2小时后` | 周日 19:30 | 时刻型 |
| 明确时刻 | `明晚八点`、`明早七点半`、`晚上8点` | 周日 19:30 | 时刻型 |
| 明确月日 | `10月20日` | 周日 19:30 | 日期型 |
| 缺年份 | `1月5日` | 周日 19:30 | 2027-01-05 + `missing_year` |
| **缺提醒时间** | `周五之前` | 周日 19:30 | **日期型 2026-10-16，remind 为 null，`deadline_only`** |
| **跨午夜** | `凌晨1点` | 周日 **22:00** | **次日 01:00** |
| **跨午夜顺延** | `今晚11点` | 周日 **23:30** | 顺延次日 + `assumed_next_day` |
| 已过时刻 | `今天下午三点` | 周日 19:30 | 走顺延规则并标记 |
| 歧义 | `8点`（未写上午下午） | 周日 09:00 | `ambiguous_ampm` |
| 无法解析 | `老师讲得很快` | 周日 19:30 | `kind = none` + `unresolved_date` |
| 夏令时不存在 | `3月8日凌晨2点30分` | `America/New_York` | `dst_nonexistent` |
| 夏令时重复 | `11月1日凌晨1点30分` | `America/New_York` | `dst_ambiguous` |

另有一条专门断言：**日期型截止日绝不允许携带 UTC**（`due.kind = "date"` 时 `utc` 必须为 `null`），
因为「10-16 这一天」在不同时区对应不同的绝对时刻，写死 UTC 就是错的。

端到端复核（`scripts/verify-api.ps1`）：

```
  [通过] 明晚八点 -> 2026-10-12 20:00 本地
  [通过] 明晚八点 -> 2026-10-12T12:00:00Z
  [通过] 周五之前 -> 2026-10-16（日期型）
  [通过] 日期型截止日不带 UTC
  [通过] 周五之前不编造提醒时刻
  [通过] 周五之前标记 deadline_only
```

**iOS 端：未验证。** `TimeDisplay.swift` 规定「日期型绝不显示时刻」，但未运行。

---

### 验收项 3：离线时记录仍然保存

**未验证（iOS 专属）。**

设计上由三个部分保证，代码均已写好但未编译运行：

1. `DayCueStore+Capture.swift`：捕获先写本地 SQLite 的 `capture_item`，再触发网络解析。
2. `CaptureViewModel.swift`：状态机把「已落库」与「解析成功」作为两个独立状态。
3. `HTTPClient.swift`：网络失败分类为 `.networkUnreachable`，其用户文案已经是
   「网络不可达，记录已保存在本机。」——即失败路径不改变「已保存」这一事实。

复现步骤见 `apps/ios/README.md` 第 4 节。

---

### 验收项 4：AI 超时 / 非法 JSON / 错误日期不触发任何系统写入

**后端：已通过。**

| 场景 | 测试 | 断言 |
|---|---|---|
| 上游超时 | `TestExtractionsTimeoutReturns504` | 返回 **504** `upstream_timeout`，不返回候选 |
| 模型返回非 JSON | `TestExtractionsModelOutputInvalidReturns502` | 返回 **502** `model_output_invalid`，且响应体**不含** `items` |
| 全部候选非法 | `TestNormalizeAllInvalidIsError` | 返回错误，不返回半成品 |
| 模型编造原文依据 | `TestNormalizeDropsFabricatedEvidence` | 依据被清空 + `model_uncertain` |
| 时间无法解析 | `TestNormalizeUnresolvedTimeIsNotInvented` | `due.kind = none`、`remind = null` |
| 未配置供应商 | `TestExtractionsWithoutProviderReturns503` | 返回 **503**，绝不返回编造结果 |
| 非音频类型 | `TestTranscriptionsRequiresAudioContentType` | 返回 **415** |
| 模拟模式要转写 | `TestTranscriptionsWithoutProviderReturns503` | 返回 **503**，响应体不含 `text` |

关键设计：**写入系统的唯一入口是用户在预览页点「确认」**。后端失败时客户端拿不到任何候选对象，
因此不存在「错误日期被写进提醒事项」的代码路径。

端到端复核：

```
  [通过] 模拟模式不编造转写，返回 503
  [通过] 非法时区被拒绝 422
  [通过] 非法 JSON 被拒绝 400
  [通过] 契约外字段 user_id 被拒绝 400
```

**iOS 端：未验证。** 但需要说明：iOS 侧并未从零实现这套判断，它只是消费后端契约；
后端返回非 200 时 `DayCueAPI.swift` 会抛出错误，`ReviewDraft` 根本不会被创建。

---

### 验收项 5：拒绝提醒事项权限，任务仍留在 App

**未验证。** 代码路径：`TaskWriteService.swift` 的 `validate → authorize → enqueue → execute → reconcile → receipt`，
权限被拒时进入 `waitingForPermission` 而不是 `failed`，任务行照常存在于本地库与今天页。

已写但未运行的测试：
`Tests/DayCueCoreTests/ExternalWriteStateMachineTests.swift` 中的
`testPermissionDeniedGoesToWaitingForPermissionNotFailed`。

---

### 验收项 6：重复提交不创建重复任务

**未验证。** 代码层面现在有**五**道保险，但全部未编译运行：

0. **并发互斥闸门（本轮新增）**：`InFlightWriteGuard`（actor）保证同一个 taskId
   同时只有一个执行者。这是本轮修复的真实缺陷——此前连点两次「确认」时，
   两次调用可能都在 `await findReminder` 处看到"系统里没有"而各建一条。

1. **确定性幂等键**：`Hashing.swift` 的 `IdempotencyKey.createReminder(taskId:listId:)`
   对 `"create_reminder:<taskId>:<listId>"` 取 SHA-256 前 32 位十六进制。
   同样的输入必然得到同样的键，重试命中同一条记录。
2. **数据库唯一索引**：`outbox_operation.idempotency_key` 上建 UNIQUE，
   崩溃后重放也不会产生第二条。
3. **写入前查重（本轮加固）**：`ReminderService.createReminder` 先按备注里的 DayCue 任务 ID
   调用 `lookupReminder(forTaskId:)`，找到就复用，**绝不按标题模糊匹配**。
   加固点是结论三分化：只有 `notFound`（查询成功且两段范围都完整、确实没有）
   才允许继续创建；`notAuthorized` / `queryFailed` / `incompleteScope` 一律停下来，
   分别进入待授权或待对账。**查重同时覆盖未完成与已完成两种提醒**——
   旧实现只查未完成项，用户勾掉一条再重试就会重建一条。
4. **状态机禁区**：`written` 状态不允许回到 `pending`，避免「以为没写成功」而重写。

已写但未运行的测试：`IdempotencyKeyTests.swift`（5 个用例，含按规格复算校验）、
`InFlightWriteGuardTests.swift`（6 个用例，含 64 次并发抢占必须只有一个赢家）、
`ReminderLookupPolicyTests.swift`（8 个用例，本轮新增：只有 `notFound` 允许创建、
已完成项必须命中、一段查询失败即视为范围不完整）。

设备验证入口：[phase-1-device-acceptance.md](phase-1-device-acceptance.md) 第 6.2 节
（故障注入中断后重启，外部仍只有一条）与第 4.4 节（查重无结论时不新建）。

后端不涉及此项：`POST /v1/extractions` 是无状态的，既不落库也不写系统。

---

### 验收项 7：苹果侧写入失败不显示成功

**未验证。** 设计上是「没有系统回执就不许显示已写入」。本轮补上了**启动恢复**：
`unknown`（连写没写都不知道）的任务会在启动/回前台时被降级为
`needsReconciliation`，从而出现在今天页的「同步异常」分区里，
而不是默默停在中间态、也**不会**被自动重写。

- `ExternalWriteState` 共 7 态：`notRequested / waitingForPermission / pending / written / failed / unknown / needsReconciliation`。
- 界面对应四种文案：**已保存到 App / 等待写入苹果提醒事项 / 已写入苹果提醒事项 / 写入失败**。
- `written → pending` 被状态机判为非法；`unknown` 必须经对账才能被信任。
- `EKEventStoreChanged` 通知只登记待对账，不猜测具体字段变化。

已写但未运行的测试：`ExternalWriteStateMachineTests.swift`（10 个用例）、
`StartupRecoveryTests.swift`（8 个用例，本轮新增：pending 可被找回、unknown 只能转对账、
已写入绝不被恢复流程改动、已删除不被复活、running 排除在可执行之外）。

---

### 验收项 8：用户修改识别文本后，迟到结果不覆盖

**未验证（iOS 专属）。** 两层保护，均未编译运行：

**第一层：正文不被覆盖（已有）**。`updateCaptureUserText` 会把 `user_edited` 置 1 且
永不复位；`applyExtractedText` 遇到 `userEdited` 直接返回 false，
SQL 也带 `WHERE user_edited = 0`，晚到的转写/OCR 结果写不进去。
测试：`UserEditPriorityTests.swift`（5 个用例）。

**第二层：候选绑定输入版本（本轮新增）**。原文受保护还不够——
候选本身也可能来自旧文本。所以每次解析都带上序号与输入指纹
（正文 + 录入时间 + 用户编辑标记），结果到达时先判定：

| 判定 | 处理 |
|---|---|
| `current` | 落库并进入预览 |
| `superseded` | 直接丢弃，**且不碰界面状态**（避免覆盖更新的那次解析） |
| `inputChanged` | 丢弃并提示「记录内容在解析期间发生了变化」 |

`ReviewContext` 同时携带输入版本，**确认时再校验一次**；
关闭预览、完成、重置都会作废在途响应，防止预览被迟到结果重新弹出来。

需要说明的事实：`updateCaptureUserText` 目前在**生产代码里没有调用方**
（只有测试调用），所以"解析中途改正文"这条路径今天还不可达；
真正可达的风险是重复解析与重放导致的迟到覆盖，第二层正是针对它。

测试：`ExtractionFreshnessTests.swift`（7 个用例，本轮新增）。
设备验证入口：清单第 3 节（OCR 后修改再解析）。

---

### 验收项 9：日志与仓库中没有真实 API Key

**已通过。**

| 检查 | 方法 | 结果 |
|---|---|---|
| 仓库密钥扫描 | 对 89 个文件扫描 6 类模式：`sk-…`、`gh[pousr]_…`、`AKIA…`、`AIza…`、硬编码 `Bearer`、赋值式 key/secret/token | **0 命中** |
| 密钥来源 | `internal/config/config.go` 中 `DAYCUE_LLM_API_KEY` 等只从环境变量读取，无默认值、无兜底 | 通过 |
| 样例文件 | `services/api/.env.example` 只含占位符，无真实值 | 通过 |
| 访问日志 | `internal/httpx/middleware.go` 只记录方法/路径/状态/耗时/请求 ID，**不记录请求体** | 通过 |
| 上游错误 | `internal/llm/openai.go`、`internal/asr/openai.go` 不回传、不落盘上游错误体（可能含用户原文） | 通过 |
| iOS Token | `KeychainTokenStore.swift`，非敏感偏好走 SQLite，Token 走系统 Keychain | 代码已写，未运行 |
| 仓库状态 | `git status` 只有新增文件，**未执行任何 commit / push** | 通过 |

---

## 6. AI 与日期验证的分层

三种验证目标完全不同，混在一起谈就会把"样例跑通了"说成"模型能用了"。

| 层 | 输入从哪来 | 时基 | 本轮状态 | 能证明什么 |
|---|---|---|---|---|
| **L1 fixture 链路** | 仓库里的 `contracts/fixtures/*.json` | 请求里写死的 `recorded_at = 2026-10-11T11:30:00Z` | **已通过** | 契约字段、规范化逻辑、时间解析正确 |
| **L2 模拟上游** | `DAYCUE_FIXTURE_MODE=1` 的本地服务 | 同上 | **已通过**（23 项断言） | 真实 HTTP 链路、错误码、鉴权、限流边界 |
| **L3 真实模型** | 真实 LLM / ASR 供应商 | 未测 | **未验证** | 模型能否稳定输出契约要求的 JSON |

### 6.1 L1：fixture 用固定时基，不看执行日期

固定请求：

```json
"recorded_at": "2026-10-11T11:30:00Z",
"timezone": "Asia/Shanghai"
```

于是「明晚八点」恒等于 `2026-10-12T20:00:00`（Asia/Shanghai），
「周五之前」恒等于 `2026-10-16`。**所有 Go 测试都不调用 `time.Now()`**
（已 grep 确认），因此测试结果与运行日期无关，任何一天跑都一样。

> 这正是"当前时间测试按执行日期计算预期"的落点：
> 凡是需要"现在"的地方，都把基准时间**显式传进去**，而不是在实现里偷偷取系统时间。
> 生产代码里唯一的"现在"来自 `recorded_at`（用户录入时刻），
> 这样用户跨时区旅行时"明晚八点"仍然按录入当时的时区解释。

### 6.2 L2：模拟上游明确可识别

`/v1/health` 报 `providers.llm = "fixture"`，响应体带 `mode = "fixture"`，
iOS 端据此在界面上打「模拟结果」标记。**模拟模式永远不会伪造 ASR 结果**——
未配置转写供应商时返回 `503 service_unavailable`，而不是编一段文字。

### 6.3 L3：真实模型完全未验证

本轮**没有调用任何真实 LLM 或 ASR**。因此以下结论一律不成立：

- 「模型能稳定输出契约 JSON」——未验证；
- 「真实语音的转写准确率可接受」——未验证；
- 「相对日期在真实模型输出里都能落到 `date_expression`」——未验证。

接入真实供应商后需要重跑 `contracts/fixtures` 里的样例并记录实际准确率，
在那之前只能说"提示词与容错代码按契约写好了"。

---

## 7. 测试与构建实测结果

```
# 工作目录 services/api
go build ./...        -> 通过（无输出）
go vet ./...          -> 通过（无输出）
gofmt -l .            -> 无输出（全部已格式化）
go test ./... -count=1 -> ok（5 个包有测试，共 29 个用例全部 PASS）

--- PASS 计数 ---
29
```

各包测试分布：

| 包 | 内容 |
|---|---|
| `internal/temporal` | 时间解析表驱动测试、DST 测试、日期型不带 UTC |
| `internal/extract` | 契约 fixture 比对、围栏 JSON、编造依据、无法解析、全非法、空候选、超时透传 |
| `internal/api` | 端到端路由、错误码映射、认证、限流体积、Content-Type |
| `internal/config` | 配置装载与启动前安全校验 |

端到端验收脚本：**23 项断言全部通过**。

### iOS 侧本轮实际执行的检查（只有这两项）

**B/C 的前置：静态检查**——`scripts/ios/static-check.ps1` 在 Windows 上可重复运行：

```
静态检查：通过 17，失败 0，未验证 4
  [通过] 全部 57 个 Swift 文件的括号平衡（词法扫描，跳过注释与字符串）
  [通过] DayCueCore 21 个源文件只依赖 Foundation/CryptoKit/SQLite3 —— 可在 macOS 上 swift test
  [通过] project.yml 的 target 目录、本地 SPM 包引用、4 项权限文案均已声明
  [通过] Package.swift 引用了两个 target 目录；所有测试文件都 import XCTest
  [未验证] swift build / swift test —— 本机没有 Swift 工具链
  [未验证] xcodegen generate —— 本机没有 XcodeGen
  [未验证] xcodebuild build —— 本机没有 Xcode
  [未验证] 模拟器 / 真机行为 —— 需要设备
```

**这只是静态检查。它证明不了代码能编译**，脚本自己也会把这句话打印出来。

**B 的前置：iOS 测试数量**——iOS 现有 13 个测试文件、89 个用例，**一个都没有运行过**：

| 文件 | 用例数 | 本机是否运行过 |
|---|---|---|
| ContractDecodingTests | 6 | 否 |
| IdempotencyKeyTests | 5 | 否 |
| SQLiteStoreTests | 8 | 否 |
| ExternalWriteStateMachineTests | 10 | 否 |
| UserEditPriorityTests | 5 | 否 |
| TimeDisplayTests | 10 | 否 |
| APIClientTests | 6 | 否 |
| InFlightWriteGuardTests | 6 | 否 |
| StartupRecoveryTests | 8 | 否 |
| **ExtractionFreshnessTests（本轮新增）** | **7** | 否 |
| **ReminderLookupPolicyTests（本轮新增）** | **8** | 否 |
| **ReviewSelectionTests（本轮新增）** | **6** | 否 |
| **OneShotSwitchTests（本轮新增）** | **4** | 否 |
| 合计 | **89** | **0 个运行过** |

**测试写了但一个都没跑过**——所以 B 类证据仍然是「未验证」，不能算通过。

### 契约一致性实测（最强的一条证据）

除了单元测试里的 fixture 比对，另做了一次「真实链路」的契约校验：把仓库里的
`contracts/fixtures/extract-os-pv.request.json` **原样**作为请求体发给正在运行的真实服务，
再把响应与 `contracts/fixtures/extract-os-pv.response.json` 做递归逐字段比较。

```
HTTP 200
契约比对: 完全一致（请求 fixture -> 真实服务 -> 响应 fixture 逐字段相同）
```

这一条同时证明了四件事：请求 fixture 与 Go 的请求结构体一致、Go 实现与响应 fixture 一致、
时间换算结果与手写预期一致、`mode=fixture` 标记生效。

---

## 8. Mac 上必须执行的验证（按优先级）

以下步骤**尚未执行**。本机是 Windows，没有 Swift 与 Xcode，所以一行都跑不了。

### 7.1 一条命令拿到 A/B/C 三类证据

```bash
git clone https://github.com/jolaaa999/DayCue.git
cd DayCue
bash scripts/ios/verify-ios.sh
```

该脚本依次做五件事，并且**不猜任何名字**：

1. 记录版本：macOS、`xcodebuild -version`、`swift --version`、`xcodegen --version`、
   `xcrun simctl list runtimes`、`xcodebuild -showsdks`——写进 `apps/ios/build/logs/versions.txt`；
2. `swift test` 跑 DayCueCore（不需要模拟器、不需要签名）；
3. `xcodegen generate` 生成工程；
4. `xcodebuild -list -json` **从生成后的真实工程里读出 scheme 与 target**，
   读不到就直接失败，不会回退到硬编码的名字；
5. 用读出来的 scheme 为 `generic/platform=iOS Simulator` 构建，日志落在
   `apps/ios/build/logs/xcodebuild-build.log`。

脚本会明确打印它**能**验证什么、**不能**验证什么。
目前工程里没有 Xcode 测试 target，脚本会如实报告这一点，而不是假装跑了测试。

### 7.2 D 类证据：真机清单

真机行为无法自动化，必须人工执行：[phase-1-device-acceptance.md](phase-1-device-acceptance.md)。

### 7.3 执行顺序

| 优先级 | 验证内容 | 对应验收项 |
|---|---|---|
| P0 | `swift test` 全绿（7 个测试文件） | 6、7、8 |
| P0 | 首次编译通过（预期需要少量修正，见第 7 节） | 全部 |
| P0 | 文字闭环：输入「周五之前交实验报告」→ 预览 → 确认 → 今天页出现 | 1、2 |
| P0 | 重复点按「重试写入」→ 系统提醒事项中始终只有一条 | 6 |
| P1 | 授权后写入苹果提醒事项，核对清单、到期时间、备注中的任务 ID | 7 |
| P1 | 关闭网络后记录，确认仍显示「已保存到 App」并可稍后重试 | 3 |
| P1 | 在系统设置里关闭提醒事项权限，确认任务仍在今天页并显示「等待写入」 | 5 |
| P1 | 在预览页修改识别文本，然后触发一次晚到的解析，确认文本不被覆盖 | 8 |
| P2 | 录音闭环、拍照 OCR 闭环 | — |
| P2 | 修改系统提醒事项后点撤销，确认走「只解绑不删除」 | 7 |

---

## 9. 已知风险与不确定性（诚实清单）

0. **最可能需要在 Mac 上调整的三处**（由 iOS 实现的静态复查给出，按风险排序）：
   (a) **iOS 17 新权限 API 的确切签名**——`AVAudioApplication.requestRecordPermission`、
   `EKEventStore.requestFullAccessToReminders()`、`authorizationStatus(for: .reminder) == .fullAccess`
   均按官方形态书写但未编译；若有出入可退回已废弃但仍可用的
   `AVAudioSession.requestRecordPermission(_:)` 与 `requestAccess(to: .reminder)`。
   (b) **XcodeGen 引用本地 SPM 的方式**——`packages: DayCueCore: path: .`；
   若报找不到包或同名模块冲突，退路是直接引用源码目录并删掉 `packages` 段。
   (c) **EventKit 字段映射**——`dueDateComponents` 与独立的 `EKAlarm(absoluteDate:)` 必须分开，
   否则会破坏「日期型截止日不得变成假时刻」这条硬约束。
1. **iOS 代码从未编译。** 这是最大的不确定性。所有 Apple 框架 API 均按 iOS 17 官方形态书写
   （例如 `store.requestFullAccessToReminders()`、`EKAuthorizationStatus.fullAccess`、
   `AVAudioApplication.requestRecordPermission`），但首次 `xcodebuild` 仍可能需要修正签名、
   `Sendable` 警告或个别 API 名称。
2. **`project.yml` 未经 XcodeGen 实际执行验证。** 尤其是 `packages: path: .` 这种
   「用同目录 Package.swift 作为本地包」的写法，属于预期可行的用法但未实测。
3. **真机 HTTP 明文访问需要额外配置。** `project.yml` 目前未加 `NSAppTransportSecurity` 例外；
   若后端只有 HTTP，真机将无法连接，需按 `apps/ios/README.md` 第 3 节补上。
4. **新增的互斥闸门与启动恢复同样未经编译。** 它们是普通 Swift actor 与 SQLite 语句，
   API 均已按仓库内既有定义核对（`OutboxOperationRecord` 的 `createdAt`/`updatedAt` 无默认值，
   测试里已显式传参），但**没有编译器验证过**。首次 `swift test` 仍可能报错。
5. **启动恢复会自动重试 `pending` 任务，其安全性依赖未被自动化测试覆盖的查重路径。**
   自动重试之所以不会产生重复提醒，靠的是 `ReminderService.createReminder` 里
   "先按稳定任务 ID 查重、查到就复用"这一步。该步骤在 App target、依赖 EventKit，
   **无法在 macOS 上单元测试**，只能由真机清单第 6.2 条验证。
   如果那一步有缺陷，自动重试就会变成"自动制造重复提醒"，风险高于手动重试。
   **在真机验证第 6.2 条之前，不应把这一版视为可用于真实数据。**

6. **模拟模式的结果是预设样例，不是真实 AI 调用。** 响应 `mode=fixture`、
   `/v1/health` 的 `providers` 报 `fixture`，界面上必须显示「模拟结果」。
   任何把 fixture 结果当作模型能力结论的解读都是错的。
7. **真实模型的质量未验证。** 本轮没有调用任何真实 LLM，因此「模型能否稳定输出契约要求的 JSON」
   只有提示词设计与容错代码作保证（`model_output_invalid` + 围栏 JSON 容错），没有实测数据。
   接入真实供应商后应重跑 `contracts/fixtures` 里的样例并记录准确率。
8. **EventKit 的真实行为未验证。** 例如已删除清单、iCloud 未同步、系统提醒事项被用户改名等情况，
   代码里有分支（`listNotFound`、`listNotWritable`、`needsReconciliation`），但没有真机数据。
9. **语音识别与 OCR 未验证。** 系统 Speech 框架的中文识别质量、Vision 对白板照片的识别率都未实测；
   代码保证的是「识别失败就显示失败，绝不返回假文本」。

---

## 10. 与设计文档的偏离记录

| 设计文档 | 本轮实现 | 原因 |
|---|---|---|
| 建议用 GRDB | 直接用系统 sqlite3 C API | 减少依赖，第一阶段验证目标是闭环而非 ORM |
| 第三阶段才有记忆页 | 已建 `memory_item` 表但界面为空状态 | 保留数据结构位置，不提前实现推断 |
| 课表 / 课程实例 | 未实现 | 第二阶段范围，仅保留契约字段 |
| 位置 / 双向同步 | 未实现 | 第四阶段范围 |

除此之外，设计文档中的三条硬约束均已实现并测试：
**模型不算日期**、**不编造提醒时间**、**外部写入状态必须真实可见**。
