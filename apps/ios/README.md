# DayCue iOS（第一阶段最小闭环）

> **状态声明：本目录下的全部代码在 Windows 上编写，尚未编译、尚未在真机验证。**
> Windows 上没有 Swift 工具链和 Xcode。所有 API 均按 iOS 17 / Swift 5.9 的官方形态书写，
> 但第一次在 Mac 上编译时仍可能需要少量修正（见文末「已知风险」）。

---

## 1. 目录结构

```
apps/ios/
├── Package.swift                      # SPM：DayCueCore 库 + DayCueCoreTests（可在 macOS 上 swift test）
├── project.yml                        # XcodeGen 工程描述（只定义 DayCue App，Info.plist 由它生成）
├── README.md
├── Sources/
│   ├── DayCueCore/                    # 跨平台纯逻辑，不 import UIKit/SwiftUI/EventKit/AVFoundation
│   │   ├── Identifiers.swift          # UUID 生成与统一的时间出口
│   │   ├── DomainModels.swift         # 领域枚举（含外部写入状态机）与各表对应的结构体
│   │   ├── Contract.swift             # contracts/v1/*.schema.json 的 Swift 镜像
│   │   ├── JsonRFC3339.swift          # 三种时间写法的解析 + JSON 编解码器
│   │   ├── TimeDisplay.swift          # 时间展示的唯一实现（日期型绝不显示时刻）
│   │   ├── Hashing.swift              # SHA256 与确定性幂等键
│   │   ├── ReviewDraft.swift          # 预览页可编辑草稿 -> 任务行的转换
│   │   ├── SQLiteDatabase.swift       # libsqlite3 最小封装（语句 / 绑定 / 事务）
│   │   ├── Schema.swift               # v1 建表脚本与版本迁移
│   │   ├── DayCueStore.swift          # 打开库、迁移、设置、数据大小与清空
│   │   ├── DayCueStore+Capture.swift  # capture_item / attachment / extraction_proposal
│   │   ├── DayCueStore+Task.swift     # task / external_binding / memory_item
│   │   ├── DayCueStore+Outbox.swift   # outbox_operation（唯一索引兜底幂等）
│   │   ├── HTTPClient.swift           # URLSession 传输层与错误分类
│   │   ├── DayCueAPI.swift            # /v1/health、/v1/extractions、/v1/transcriptions
│   │   ├── ExtractionRequestBuilder.swift
│   │   └── StoreBootstrap.swift       # 启动打开库 + 外部稳定标识
│   └── DayCueApp/                     # SwiftUI 界面 + Apple 框架服务
│       ├── DayCueApp.swift            # @main
│       ├── AppContainer.swift         # 依赖容器（单例 store / 单例 EKEventStore）
│       ├── AppSettings.swift          # 非敏感偏好走 SQLite，Token 走 Keychain
│       ├── KeychainTokenStore.swift
│       ├── PermissionCenter.swift     # 四类权限状态的统一读取
│       ├── Components.swift           # 写入状态标签、权限行、空状态
│       ├── RootTabView.swift          # 今天 / 记录 / 记忆 / 设置
│       ├── TodayView.swift
│       ├── TodayViewModel.swift
│       ├── CaptureView.swift
│       ├── CaptureViewModel.swift     # 捕获状态机
│       ├── ReviewView.swift           # 解析结果预览（属于记录流程，不占标签）
│       ├── ManualTaskSheet.swift      # 后端不可用时的手动创建
│       ├── MemoryView.swift
│       ├── SettingsView.swift
│       ├── SettingsViewModel.swift
│       ├── ReminderService.swift      # EventKit 适配器
│       ├── AudioRecorderService.swift # AVAudioRecorder -> m4a
│       ├── TranscriptionService.swift # 协议 + 系统 Speech + 后端兜底
│       ├── OCRService.swift           # Vision VNRecognizeTextRequest
│       ├── NotificationService.swift  # 本地通知（与苹果提醒事项互斥）
│       ├── MediaStore.swift           # 媒体落盘与 sha256
│       └── TaskWriteService.swift     # validate -> authorize -> enqueue -> execute -> reconcile -> receipt
└── Tests/DayCueCoreTests/
    ├── ContractDecodingTests.swift
    ├── IdempotencyKeyTests.swift
    ├── SQLiteStoreTests.swift
    ├── ExternalWriteStateMachineTests.swift
    ├── UserEditPriorityTests.swift
    ├── TimeDisplayTests.swift
    └── APIClientTests.swift
```

---

## 2. Mac 上需要的工具

| 工具 | 版本 | 安装方式 | 用途 |
|---|---|---|---|
| Xcode | 15.0 或更高 | App Store | iOS 17 SDK、模拟器、真机调试 |
| Swift | 随 Xcode 5.9+ | 随 Xcode | `swift test` 跑 DayCueCore 单元测试 |
| XcodeGen | 2.38 或更高 | `brew install xcodegen` | 由 `project.yml` 生成 `.xcodeproj` |

确认环境：

```bash
xcodebuild -version          # 期望 Xcode 15.x
swift --version              # 期望 Swift 5.9 或更高
xcodegen --version           # 期望 2.38 或更高
```

---

## 3. 第一次构建

```bash
cd apps/ios

# 1) 先跑跨平台逻辑的单元测试（不需要模拟器，不需要签名）
swift test

# 2) 生成 Xcode 工程
xcodegen generate

# 3) 打开工程
open DayCue.xcodeproj
```

> **也可以用一条命令替代上面全部三步**，而且会额外记录版本信息与完整日志：
> ```bash
> bash scripts/ios/verify-ios.sh          # 在仓库根目录执行
> ```
> 它会先跑 `swift test`，再生成工程，然后**从生成后的真实工程里读出 scheme**
> （故意不硬编码名字，读不到就直接失败），最后为 iOS 模拟器构建。
> 版本、SDK、模拟器运行时和构建日志都落在 `apps/ios/build/logs/`。
> 它**能**证明：DayCueCore 测试通过、工程可生成、App 可编译。
> 它**不能**证明：任何需要真实系统权限的行为——那必须按第 4 节在真机上做，
> 或按 [phase-1-device-acceptance.md](../../docs/phase-1-device-acceptance.md) 逐条执行。

在 Xcode 里：

1. 选中 **DayCue** target → Signing & Capabilities → 选择你的 Team（真机必需）。
2. 选择一台 **iOS 17.0 或更高** 的设备或模拟器。
3. `Product > Run`（⌘R）。

> 注意：`project.yml` **不**定义 DayCueCore target，它通过 `packages:` 引用同目录的
> `Package.swift`。这样做是为了避免同一个模块名出现两份。因此 **DayCueCore 的单元测试
> 用 `swift test` 跑（在 macOS 上），不在 Xcode 的 Test 计划里**。
> 写入路径有三条必须知道的规则：
> 1. **查重只有「查询成功且范围完整、确实没有」才允许创建**；无权限、查询失败、
>    只查了一部分一律停下来进待授权或待对账，绝不"当成没找到"再建一条；
> 2. 查重同时覆盖**未完成与已完成**两种提醒，用户勾掉的条目也算已存在；
> 3. 创建与**撤销**共用同一把互斥闸门（`InFlightWriteGuard`），
>    连点不会写出两条，也不会出现"创建与删除交错"。
>
> 如果确实想在 Xcode 里对 DayCueCore 跑测试，打开 Package.swift 本身作为工程：
> ```bash
> open Package.swift      # Xcode 会以 Swift Package 形式打开，可直接跑 DayCueCoreTests
> ```

### 后端地址

默认 `http://127.0.0.1:8787`。真机不能访问 Mac 的 127.0.0.1，请二选一：

- 模拟器：直接使用默认地址即可（模拟器与 Mac 共享回环地址）。
- 真机：在「设置 → AI 服务 → 服务地址」里改成 `http://<Mac 的局域网 IP>:8787`，并确保后端监听 `0.0.0.0`。
- 明文 HTTP 需要在 target 的 Info.plist 中允许，`project.yml` 目前**没有**加
  `NSAppTransportSecurity` 例外。若后端只有 HTTP，请在 `project.yml` 的 `info.properties`
  里补上：

  ```yaml
  NSAppTransportSecurity:
    NSAllowsLocalNetworking: true
  ```

---

## 4. 真机验证步骤与预期结果

以下每一步都请**先确认前置状态**再看预期结果。所有涉及"失败"的步骤，重点是确认
**记录没有丢**、且界面**没有把失败显示成成功**。

### 4.1 文字闭环（不需要任何权限）

1. 打开 App，进入「记录」标签。
2. 在文字框输入「周五之前交实验报告」，点「保存这条文字记录」。
3. **预期**：先看到「已保存到本机，正在解析。」，随后自动弹出「解析结果」页。
4. 在预览页找到「交实验报告」：
   - 类型为「任务」，能看到原文依据「周五之前交实验报告」；
   - 显示「截止：2026-10-16」（具体日期取决于当天日期）；
   - 显示「尚未设置提醒时间」，且**不会**自动出现一个提醒时刻；
   - 若后端返回的是模拟结果，卡片上有橙色「模拟结果」标记。
5. 点「确认」。
6. 切到「今天」标签。**预期**：出现「交实验报告」，第二行是完整日期，第三行是状态标签。

### 4.2 提醒事项权限与写入（EventKit）

**前置**：先在系统「提醒事项」App 里建一个清单，例如「DayCue 测试」。

1. 「设置 → 提醒事项」显示「已拒绝 / 尚未询问」，「请求提醒事项权限」按钮可见。
2. 点「请求提醒事项权限」，在系统弹窗里选「允许完全访问」。
3. **预期**：
   - 权限状态变为「已允许」；
   - 出现「默认清单」选择器，能列出你刚建的清单（不可写的清单带「（不可写）」后缀）；
   - 选择「DayCue 测试」。
4. 回到「记录」，输入「明晚八点提醒我复习 PV」，提交并确认。
5. **预期**：
   - 今天页该任务的状态标签是「已写入苹果提醒事项」；
   - 打开系统「提醒事项」App，在「DayCue 测试」清单里能看到「复习 PV」；
   - 该条提醒的**备注末尾**有「DayCue 任务 ID: <uuid>」；
   - 到期时间是你设置的日期与 20:00；
   - 同时**不会**收到 DayCue 的本地通知（因为到点提醒已经交给苹果提醒事项）。
6. **重复写入不重复创建**：在今天页对该任务连点「重试写入」多次，或杀掉 App 重开后再次重试。
   **预期**：提醒事项清单里始终只有一条，不会出现第二条。
7. **撤销（外部未修改）**：在今天页点「撤销」。
   **预期**：本地任务消失，系统提醒事项里的对应条目也被删除。
8. **撤销（外部已修改）**：
   - 重新创建一条任务并确认；
   - 到系统「提醒事项」里把这条提醒的标题改掉（或改时间）；
   - 回到 DayCue，今天页点「撤销」。
   **预期**：弹出确认框，说明外部被改过；选「只解除绑定，保留外部提醒」后，
   本地任务消失，而**系统里那条被你改过的提醒仍然存在**。
9. **外部删除后的对账**：
   - 创建一条任务并确认写入；
   - 到系统「提醒事项」里直接删除该条；
   - 回到 DayCue（App 会收到 `EKEventStoreChanged`）。
   **预期**：该任务在今天页的「同步异常」分区出现，状态为「写入状态待对账」，
   且本地任务**仍然存在**，没有被自动删除。

### 4.3 拒绝提醒事项权限时的行为

1. 「设置 → 提醒事项 → 去设置」，在系统里把提醒事项权限关掉，回到 App。
2. 「记录」一条「周三前交作业」并确认。
3. **预期**：
   - 任务**仍然出现在今天页**；
   - 状态标签为「等待写入苹果提醒事项」；
   - 该任务同时出现在「同步异常」分区（等待授权也算需要处理）；
   - 若任务有提醒时刻，DayCue 会为该任务安排一条本地通知作为兜底
     （需要在「设置 → 权限状态」里允许通知）。

### 4.4 录音与转写

**前置**：「设置 → 权限状态」里麦克风、语音识别均为「已允许」。

1. 「记录」标签，点红色圆形录音按钮。
2. **预期**：按钮变为停止图标，文字显示「正在录音 0:0x」并每秒递增；超过 10 分钟自动停止。
3. 说一句「明晚八点提醒我复习 PV 操作」，点停止。
4. **预期**：显示「已录制 0:0x，可以提交或删除重录。」，并给出「提交录音」「删除重录」。
5. 点「删除重录」，再录一次。
6. **预期**：上一条录音文件被删除，重新开始计时。
7. 点「提交录音」。
8. **预期**：先看到「已保存到本机，正在转写。」；转写完成后进入解析结果页；
   录音文件位于 `Application Support/DayCue/media/audio-<captureId>.m4a`。
9. **语音识别不可用时的降级**：
   - 把系统语言/识别能力设成不支持的情形（或直接拒绝语音识别权限）；
   - 重新录一段并提交。
   **预期**：若系统识别不可用，会自动改用后端 `POST /v1/transcriptions`；
   两条路都失败时，界面显示明确的失败原因（「转写失败：…」）并提示
   「录音已保存在本机」，同时给出「稍后重试」「手动创建任务」。
   **不会**出现任何凭空生成的文字。
10. **离线**：打开飞行模式后重复第 7 步。
    **预期**：显示「网络不可达，记录已保存在本机。」；今天页的「待处理记录」里能看到这条录音。

### 4.5 OCR

1. 「记录」标签，点「拍照 / 选图」，选一张写着「实验三，下周三上课前交」的照片。
2. **预期**：
   - 出现图片缩略图；
   - 下方文本框自动填入识别出的文字，**可以直接编辑**；
   - 提示「识别结果可以直接修改；改动会以你的版本为准。」
3. 手动把文字改成「实验三，下周五上课前交」，再提交。
4. **预期**：后续任何识别结果都不会覆盖你改过的文字（`capture_item.user_edited = 1`）。
5. 选一张没有任何文字的图片。
   **预期**：显示「没有在图片里找到文字。图片已保存，可以手动输入内容。」
   **不会**编造任何文字。

### 4.6 后端不可用 / 模型输出非法

1. 停掉后端进程（或把「设置 → AI 服务 → 服务地址」改成一个不存在的端口）。
2. 「记录」一条文字记录。
3. **预期**：
   - 提示「网络不可达，记录已保存在本机。」（或超时提示）；
   - 下方给出「稍后重试」和「手动创建任务」；
   - 今天页「待处理记录」里能看到这条记录。
4. 点「手动创建任务」，自己选日期和提醒时间，点「创建」。
   **预期**：任务被创建，且时间完全按你选的来，DayCue 没有自动补任何时刻。
5. 若后端返回 `model_output_invalid`（HTTP 502）：
   **预期**：提示「已保留记录，可稍后重试（模型返回无法解析的结果）。」，
   **不触发任何系统写操作**（提醒事项里不会有新条目）。

### 4.7 设置页

1. 「设置 → 数据管理」显示本地数据库路径（`.../Application Support/DayCue/DayCue.sqlite`）与大小。
2. 点「清空本地数据」。
   **预期**：先弹二次确认；确认后今天页变空，提醒事项里的条目**不受影响**。
3. 「设置 → AI 服务」填错地址后点「测试连接」。
   **预期**：显示明确的失败原因，而不是假装成功。
4. Token 框输入任意内容后杀掉 App 重开。
   **预期**：Token 仍然存在（来自 Keychain）。用 Xcode 的 Devices 面板下载 App 容器，
   打开 `Library/Preferences/<bundle-id>.plist`，里面**不应**出现 token 字符串。

---

## 5. 单元测试

```bash
cd apps/ios
swift test
```

覆盖的内容：

| 测试文件 | 覆盖点 |
|---|---|
| `ContractDecodingTests` | 契约解码：1 条 note + 2 条 task；`remind == null` 的那条带 `deadline_only`；未知歧义码按需要澄清处理；错误体解析 |
| `IdempotencyKeyTests` | 幂等键确定性：同 (taskId, listId) 相同；不同 listId 不同；与规格算法逐位一致 |
| `SQLiteStoreTests` | 建库/迁移、capture 与 task 往返字段一致、唯一约束拒绝重复幂等键、附件与绑定往返、清空数据 |
| `ExternalWriteStateMachineTests` | 状态机合法迁移；`written` 收到失败回执只能转 `needs_reconciliation` 不能回 `pending`；库层同样拒绝非法迁移 |
| `UserEditPriorityTests` | 用户修订优先：`user_edited = 1` 后晚到的识别结果被拒绝；请求构造优先用用户文本 |
| `TimeDisplayTests` | 日期型显示 `2026-10-16`、精确时间显示 `2026-10-12 20:00`、日期型不写 UTC、排序与备注标识 |
| `APIClientTests` | 请求头、契约错误解析成 `model_output_invalid`、非契约错误、网络不可达、音频原始字节上传 |
| `InFlightWriteGuardTests` | 并发互斥闸门：同一 taskId 的第二次 `begin` 被拒绝；64 次并发抢占只允许一个赢家；`end` 后可重试；不同 key 互不影响 |
| `StartupRecoveryTests` | 启动恢复：`pending` 任务可被找回；`unknown` 只能转 `needs_reconciliation` 不能转 `failed`；已写入的任务绝不被恢复流程改动；已删除的不被复活；`running` 排除在可执行 outbox 之外 |
| `ExtractionFreshnessTests` | 迟到结果判定：输入指纹覆盖正文/录入时间/编辑标记；更新的解析请求使旧结果作废；中途改输入后结果不可用；记录被删后结果不可用 |
| `ReminderLookupPolicyTests` | 查重结论分类：**只有 notFound 允许继续创建**；已完成项也必须在查重范围内；无权限/查询失败/范围不完整一律不得当成没找到 |
| `ReviewSelectionTests` | 笔记与任务分开：1 笔记 + 2 任务取消一条后剩 1 任务 + 1 笔记；笔记永远不计入任务；改类型双向生效 |
| `OneShotSwitchTests` | 故障注入的一次性语义：装填后只触发一次；未装填永不触发；重新装填可再次触发；重复读取仍只算一次 |

共 **13 个测试文件、89 个用例**。

单测里**没有**引用仓库里的 fixture 文件：契约 JSON 以等价字符串内联在测试代码里，
这样 `swift test` 的工作目录无论在哪里都能跑。

> 这 89 个用例**从未在任何机器上运行过**——本项目没有 macOS 环境。
> 写了测试不等于测试通过，因此验收文档里 iOS 侧一律记为「未验证」。

---

## 6. 第一阶段明确不做的事

- 不做推断式记忆。「记忆」页只有空状态，不会出现任何未经用户确认的内容。
- 不做双向同步。任务的完成状态只改本地，不主动回写苹果提醒事项。
- 不做课表、位置、分享扩展、小组件。
- 不做后台任务。所有网络调用都在前台由用户操作触发。

---

## 7. 已知风险（第一次在 Mac 上编译时最可能需要人工调整的点）

1. **`AVAudioApplication`（iOS 17 的麦克风权限 API）**与 **`EKEventStore.requestFullAccessToReminders()`**
   是 iOS 17 新增接口，本代码按官方签名书写但未经编译验证。若签名有出入，
   替代写法是 `AVAudioSession.sharedInstance().recordPermission`（已废弃但可用）
   与 `requestAccess(to: .reminder)`（已废弃）。
2. **`SFSpeechURLRecognitionRequest` + `requiresOnDeviceRecognition`**：
   部分设备/语言不支持端侧识别，本代码只在 `recognizer.supportsOnDeviceRecognition` 为真时才强制端侧。
   若真机上识别始终失败，请检查系统「设置 → 通用 → 键盘 → 听写」是否开启。
3. **XcodeGen 的 Swift Package 引用方式**（`packages: DayCueCore: path: .`）：
   如果 `xcodegen generate` 报找不到包，退路是在 `project.yml` 里改为直接引用源码目录
   （`sources: [Sources/DayCueCore, Sources/DayCueApp]`）并去掉 `packages` 段，
   代价是 DayCueCore 会同时被 SPM 和 Xcode 工程各编译一份。
4. 明文 HTTP：真机访问 `http://...` 需要 `NSAppTransportSecurity` 例外（见 3. 后端地址）。
5. **并发闸门与启动恢复同样是新代码，未经编译。** `InFlightWriteGuard` 是普通 Swift actor，
   `recoverInterruptedWrites` 只用到既有仓储方法，接口均按仓库内定义核对过，
   但没有任何编译器校验。首次 `swift test` 仍可能报错。
6. **启动恢复会自动重试 `pending` 任务，其安全性依赖一条无法单元测试的查重路径。**
   重试之所以不会产生重复提醒，靠的是 `ReminderService.createReminder` 在创建前
   先按备注里的稳定任务 ID 调 `lookupReminder(forTaskId:)` 查重，
   并且只有"查询成功、范围完整、确实没有"才允许创建。
   该逻辑在 App target、依赖 EventKit，在 macOS 上测不了，
   **必须**由真机清单第 6.2 节（写入后强杀 App 再重开，检查条数不增加）验证。
   在该条通过之前，不应把这版用于真实数据。
7. **查重的"两段式"依赖 EventKit 的语义假设。** 本版认为
   `fetchReminders` 的回调收到 `nil` 表示该批未取到（据此判为"查询失败/范围不完整"），
   并认为 `predicateForCompletedReminders` 能覆盖已完成项。
   这两点在真机上必须实测（清单第 4.4 节）：把一条已写入的任务在苹果侧**勾成已完成**，
   再点「重试写入」，**不应**出现第二条。若出现，说明范围假设有误，属于必须修复的缺陷。
8. **故障注入用 `exit(0)` 而不是真实崩溃。** 它只能复现"外部已写入、本地未落库"这个
   **状态**，不能复现 iOS 的崩溃清理行为（例如系统回收、内存警告）。
   因此清单第 6.2 节通过后，仍建议补一次真实强杀（6.2b）作为交叉验证。
