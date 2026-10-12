# DayCue Android 客户端

DayCue 的 Android 客户端，Kotlin + Jetpack Compose + Room。
数据模型与 HTTP 契约对齐 iOS 端（apps/ios/Sources/DayCueCore/Schema.swift 的 v2 段、contracts/v1/*.schema.json）。

## 当前状态：这份代码从未编译过

必须说清楚，不要造成误解：

- 本机**没有** Android SDK、没有 ANDROID_HOME、没有 gradle，PATH 上的 java 还是 8（JDK 17 装在别的路径）。
- 因此全部源码是**只写不跑**的产物：它没有经过 kotlinc 编译、没有跑过 lint、没有跑过任何一条单元测试。
- 首次构建时请预期需要修若干编译错误（拼写、导入、API 细节）。**不要**把「这里没有报错」当成「它能编译」。
- Gradle Wrapper 的 gradle-wrapper.jar **没有**提交（二进制文件不在本仓库的交付范围内），
  第一次构建前必须先补齐，见下方「首次构建」。
- Room 的 schema JSON（app/schemas/2.json）同样没有生成，它是构建产物。

## 目录结构

    apps/android/
      settings.gradle.kts           仓库与模块声明（只含 :app）
      build.gradle.kts              根构建脚本，只声明插件不 apply
      gradle.properties             JVM 参数、AndroidX 开关、kotlin 官方代码风格
      gradle/libs.versions.toml     版本目录：所有依赖版本唯一来源
      gradle/wrapper/               gradle-wrapper.properties（jar 缺失，需先生成）
      app/
        build.gradle.kts            android/kotlin/compose/serialization/ksp 插件与依赖
        proguard-rules.pro          kotlinx.serialization / OkHttp / WorkManager 保留规则
        schemas/                    Room 导出的 schema（构建后生成，当前只有说明文件）
        src/main/AndroidManifest.xml 权限与组件声明（每条权限都有降级路径）
        src/main/res/               字符串、主题、图标、备份规则
        src/main/java/com/daycue/android/
          DayCueApplication.kt      应用入口：建容器、建通知渠道、登记周期作业
          AppContainer.kt           手写依赖容器（数据库、仓储、平台能力、网络客户端）
          MainActivity.kt           唯一 Activity，装载 Compose 界面
          core/                     时间、标识符、JSON 三个纯工具
          domain/                   纯逻辑与模型（不依赖 Android SDK）
          data/local/               Room 实体、转换器、DAO、数据库、迁移
          data/repository/          仓储（唯一的数据出入口）
          platform/                 平台适配：通知、作业、定位、媒体、权限、安全
          network/                  HTTP 客户端与传输抽象
          ui/                       Compose 界面与 ViewModel
        src/test/                   JVM 单元测试（不需要设备）
        src/androidTest/            需要设备/模拟器的 DAO 测试（本机未执行）

## 首次构建

前置条件：

1. **JDK 17**。项目用 JVM target 17；用 JDK 8 会在 Kotlin 编译阶段直接失败。
   确认方式：`java -version` 输出的第一行含 `17`。
2. **Android SDK Platform 35 + Build-Tools 35**，并设置 `ANDROID_HOME`（或写 `local.properties` 的 `sdk.dir`）。
3. **补齐 Gradle Wrapper 的 jar**。在能联网的机器上执行（任选其一）：
   - `gradle wrapper --gradle-version 8.9`（需要本机已装 gradle）；
   - 或从任意 gradle 8.9 分发包里拷贝 `gradle/wrapper/gradle-wrapper.jar` 到本目录。
   没有这个 jar，`./gradlew` 无法启动。

然后：

    cd apps/android
    ./gradlew :app:assembleDebug        # 打 debug 包
    ./gradlew :app:testDebugUnitTest    # 跑 JVM 单元测试（不需要设备）
    ./gradlew :app:lintDebug            # lint

Windows 上用 `gradlew.bat` 代替 `./gradlew`。

首次构建后会出现两样构建产物，请一并提交或按团队约定处理：

- `app/schemas/2.json`：Room 导出的 schema，是迁移测试的输入。**没有它就是后续改表没有比对基准。**
- `app/build/`：不要在仓库里提交（已在 .gitignore 中）。

## 分层与依赖方向

    ui  ──▶  data/repository  ──▶  data/local (Room)
     │            │
     │            └──▶  domain（纯逻辑，无 Android 依赖）
     └──▶  platform（通知/作业/定位/媒体/权限）──▶ Android SDK
                 network（HTTP）──▶ domain/contract

规则：**domain 不 import android.***；**ui 不直接碰 DAO**；平台能力只暴露「能力可用/不可用」和降级后的事实，不替业务做决定。

## 数据层

17 张表（任务书列了 16 张，多出的一张见「待确认项」）：

    note  task  capture_item  course  course_schedule_rule  course_instance
    follow_up  follow_up_reply  memory_item  place  geo_rule  proactive_message
    outbox_operation  sync_cursor  sync_tombstone  app_setting
    sync_snapshot   ← 额外的一张：三方对账必须有持久化的基准值

约定（与 iOS 保持一致，改之前先看 iOS 的 SQLite 层）：

- 枚举一律存 iOS 的 rawValue 字符串，**不存 ordinal**（ordinal 会在枚举增减时错位）。
- 绝对时刻存 RFC3339 UTC 文本（`2026-10-12T00:00:00Z`）。
- 纯日期存 `YYYY-MM-DD`，**永远不补 UTC 午夜**：「周五之前」加上午夜就变成「周五 00:00 提醒」。
- 本地时间存 ISO 本地格式（`2026-10-12T20:00:00`），时区单独一列。
- 列表型字段存 JSON 文本（excluded_dates、weekdays 等）。
- 软删除统一用 `deleted_at`；查询默认过滤。

数据库版本是 2，带 `MIGRATION_1_2`，**没有** `fallbackToDestructiveMigration`。
理由：用户的手写笔记与课表不能被一次升级清空。Android 端从未发布过 v1，
所以 1→2 的 DDL 没有在真实设备上验证过，必须用 `MigrationTestHelper` + `app/schemas/2.json` 补一次验证。

## 领域逻辑（纯函数，全部有单元测试）

- `CourseInstanceExpander`：按学期基准展开课表实例（单双周、周次区间、生效日期区间、停课日、跨零点的课）。
- `IcsParser` / `IcsScheduleImporter`：ICS 解析与「导入草稿」。草稿必须由用户确认后才落库，单双周是从第一周的周次推断的。
- `FollowUpScheduler`：课后追问（延迟夹在 5–15 分钟、连堂顺延到最后一节、取消/终态不重发、稍后是改期不是新建、过期不补发）。
- `ProactiveBudget`：主动消息预算（每日 3 条、同类每日 1 条、最小间隔 90 分钟、静默时段顺延而不是丢弃、去重、冷却、跨零点重置；用户自设的提醒不受预算与静默限制）。
- `SyncReconciler`：三方对账（外部单方面改动采纳、本地单方面改动保留、双方都改且不一致→冲突交用户、外部删除只报告不删本地）。
- `ReminderOwnership`：提醒归属（同一条任务同时只有一个执行方；切换时先取消旧的；精确闹钟不可用降级为不精确并告知）。
- `GeoRuleEvaluator`：地点规则判定（进入/离开/停留、冷却、生效时段、定位不可用直接跳过，绝不使用陈旧坐标）。

一条贯穿性的设计约束：**所有「现在」都是显式传入的参数**，没有任何纯逻辑自己调用系统时钟。
这样测试才能用固定时刻断言，而不是「跑的时候刚好是几点」。

## 平台适配与降级

| 能力 | 缺失/被拒时的行为 |
| --- | --- |
| 通知权限 | 不发通知，今天页仍然显示待办与待回复；设置页显示状态与跳转按钮 |
| 精确闹钟 | 降级为 `setWindow` 的不精确提醒（分钟级误差），并在通知与设置页明确告知 |
| 录音权限 | 文字记录照常；录音入口提示需要权限 |
| 相机权限 | 改用系统图片选择器选已有图片 |
| 定位 | 地点规则整体禁用并说明原因，**不伪造位置、不使用陈旧位置** |
| 后端未配置 | 纯本地模式：记录照常落库，界面提示「已保存到本机，未配置后端」 |
| 无 GMS 设备 | 平台 `LocationManager` 可用；GMS Fused 提供方是可选增强，依赖默认注释掉 |

WorkManager 只用于「不要求准点」的两件事：outbox 重试与课表/追问刷新。
到点提醒走 `AlarmManager`——用 WorkManager 冒充精确提醒会违反设计约束。

## 与后端的契约

契约以 `contracts/v1/*.schema.json` 为准，Kotlin 侧镜像在 `domain/contract/Contract.kt`。
客户端只消费，不定义契约。请求头与 iOS 一致（`X-DayCue-Client`、`Accept`、`Authorization: Bearer`）。

离线优先：任何网络调用失败都不阻塞本地写入。outbox 里的操作带确定性幂等键
（`create_reminder:<taskId>:<listId>` 等），重放安全；「结果未知」的操作用 UNKNOWN 状态而不是 FAILED，
因为「可能已经写成功」和「确定没成功」需要不同的后续处理。

## 测试

- `app/src/test/`：**124** 条 JVM 单元测试，覆盖 core 与 domain 的全部纯逻辑，**不需要设备**：
  DayCueTime(10)、IdempotencyKey(8)、CourseInstanceExpander(16)、IcsParser(15)、
  FollowUpScheduler(16)、ProactiveBudget(12)、SyncReconciler(12)、ReminderOwnership(11)、
  GeoRuleEvaluator(13)、ContractDecoding(11)。
- `app/src/androidTest/`：**8** 条仪器测试，验证设备端约束（outbox 幂等键唯一、抢占只有一个赢家、
  未知结果不当作可重试、follow_up 每节课唯一、课程实例重复展开幂等、软删除后行仍在、
  日期型截止不得带 UTC、任务软删除不出现在待办列表），**需要设备或模拟器**。
- 迁移测试（MigrationTestHelper）**尚未编写**：它依赖构建后生成的 `app/schemas/2.json`，本机没有 SDK 无法生成。

本机没有跑过其中任何一条。 `./gradlew :app:testDebugUnitTest` 是它们的第一次真实执行。

## 已知限制

1. 图片只做保存，不做 OCR；图片记录会提示「可在记录详情里补充文字」。
2. 语音转写依赖后端；未配置后端时录音只作为附件保存。
3. Android 端只用 App 内待办，不读写系统日历，不访问任何 Apple 专有服务。
4. 对账只覆盖标题、备注、状态、截止、提醒五个字段；清单与地点没有外部绑定表，因此不参与比较。
5. 界面文案目前多数是内联中文字面量，只有通知相关文案在 `res/values/strings.xml`。
6. **outbox 目前不会真正执行**。外部写入提供方（iPhone 提醒事项桥接）尚未接入，
   且萃取结果在数据层没有对应落库表，所以 `OutboxExecutionRegistry` 没有注册执行者：
   后台作业会把记录如实留在 pending 并反复重试，**不伪造成功、也不标成失败**。
   接入时只要调用 `OutboxExecutionRegistry.install(...)` 即可，无需改任何业务代码。
7. 少量界面读取（按状态取已办、已回复追问）直接走 DAO 的只读查询，因为对应的仓储方法还没暴露；
   所有**写入**仍然只经过仓储。这些读取点在代码注释里都标了位置。
8. 通知小图标复用 `ic_launcher_foreground`；接入设计稿后应换成单色通知图标。
9. 未使用后台定位（不申请 `ACCESS_BACKGROUND_LOCATION`），地点规则只在 App 被打开时评估；
   这是刻意的取舍，避免「后台持续定位」带来的耗电与商店审核问题。
10. 结构化提取的候选条目（proposal item）没有独立落库表，因此「待确认候选」的持久化程度低于 iOS 端。
11. 记忆页没有「按来源类别关闭记忆写入」的开关：设置层没有这个键，而一个不会真正生效的开关
    比没有开关更糟（用户会以为关掉之后系统真的不记了）。页面改为**如实展示**三种来源的处理方式：
    用户表述/用户设置记为事实，系统推断只作为待确认候选。
12. 仪器测试里没有迁移测试：它需要构建后生成的 `app/schemas/2.json`，本机没有 SDK 无法生成。
    这是**接手后第一件该补的测试**，因为 MIGRATION_1_2 的 DDL 从未在真实设备上跑过。
