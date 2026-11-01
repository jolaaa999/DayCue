# DayCue｜工作日志与交接

> 只记可核查的状态：目标、已完成及证据、未完成、阻塞、涉及文件、下一步。
> 新会话接手时先读这里，再核验 `git status` 与真实测试结果，不把旧记录当实时状态。

## 2026-10-29｜阶段 1：Android 桌面悬浮球 + 环形多级扇区菜单

### 目标
按用户需求（2026-10-29）交付「桌面悬挂球 + 点击展开环形多级扇区菜单」的第一阶段实现，
双端最终都要有，但 iOS 无悬浮窗能力、本机也无 macOS，本轮只做 Android。

### 已完成（含证据）
1. 纯逻辑层：`domain/radial/RadialGeometry.kt`（扇区命中）、`domain/radial/RadialMenuModel.kt`（多级导航）。
   - 证据：`RadialGeometryTest` 11 条、`RadialMenuModelTest` 9 条全部通过。
2. 菜单内容：`ui/overlay/RadialMenuCatalog.kt`（一级 5 扇区：记录/待办/课表/记忆/打开）。
   - 证据：`RadialMenuCatalogTest` 5 条通过。
3. 界面：`ui/overlay/RadialMenuSurface.kt`（球体 + 环形扇区绘制 + 点击/拖动手势）。
4. 平台层：`platform/overlay/FloatingBallService.kt`（前台服务 + 窗口）、`OverlayController.kt`、`OverlayPermission.kt`。
5. 接线：`AndroidManifest.xml`（SYSTEM_ALERT_WINDOW / FOREGROUND_SERVICE(_SPECIAL_USE) / service）、
   `NotificationChannels.ASSISTANT`、`strings.xml`、`SettingsRepository`（`overlay.floating_ball`）、
   `MainActivity`（路由 intent + 回前台自愈）、`DayCueApp`（`settings/assistant` 路由 + 外部路由请求消费）、
   `SettingsScreen`（新分组入口）、`SettingsAssistantScreen.kt`（新页）。
6. 构建与测试证据：
   - `:app:assembleDebug` 成功，APK 55.43MB（2026-10-29T07:08Z）。
   - `:app:testDebugUnitTest`：24 个测试类 / 266 用例 / 0 失败 / 0 跳过。
   - 合并清单核对：`SYSTEM_ALERT_WINDOW`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_SPECIAL_USE`、
     `FloatingBallService(foregroundServiceType=specialUse)`、`PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 均在。

### 未完成 / 阻塞
- **未真机验证**：本机无设备，悬浮球显示、拖动、展开、跳转、通知全部「未验证」。
- **独立多 Agent 审核未完成**：本会话没有 subagent 调度能力，按 AGENTS.md §6.2 只能记为未通过。
- 阶段 2–5（操作日志与版本控制、指令端点、常听唤醒、iOS 降级实现）未开始。

### 关键决策（待补 ADR）
- 悬浮球用「前台服务 + specialUse 类型 + 常驻通知」，不用 START_STICKY，不在开机广播里拉起。
- 悬浮球收起时窗口只有 64dp（不拦截其他应用触摸）；展开时窗口变全屏（点空白关闭）。
- 菜单内容只放已存在的页面；语音对话入口等指令链路落地后再加。

### 下一步可执行动作
1. 阶段 2：`assistant_op` 操作日志表 + 实体 `revision` + 撤销/版本回溯 + 删除二次确认（弹窗 + TTS）。
2. 后端 `POST /v1/assistant/command` 与 `contracts/v1/assistant-command-*.schema.json`。
3. 设备可用时按 `docs/phase-1-device-acceptance.md` 同样格式补「悬浮球真机验收」清单。

## 2026-10-29｜全仓库功能可用性检查（后端 / Android / iOS）

> 与上面「阶段 1：Android 悬浮球」是**两条并行任务**，由不同会话执行；两者共享同一个工作区，注意并发写入风险。

### 目标与边界
用户请求「检查下功能是否可以正常使用」。范围：`services/api`（Go）、`apps/android`、`apps/ios`。不改业务代码，只做读取、构建、测试、真实 HTTP 验证。

### 结果（含证据）
- 后端：`go build` / `go vet` / `go test ./... -count=1`（顶层 PASS 214 / FAIL 0 / SKIP 0）/ `scripts/verify-api.ps1`（23 项断言全过）/ 真实二进制 + 自建假模型端点的 14 用例端到端 —— 全部通过。证据：`.dsh-tmp/evidence/{go-test-verbose.log,verify-api.log,backend-e2e-raw.json}`。
- Android：`clean` + `:app:assembleDebug` 通过；`:app:testDebugUnitTest`（`--no-build-cache` 真跑）24 类 / 266 用例 / 0 失败 / 0 跳过。证据：`.dsh-tmp/evidence/android-*.log`。
- iOS：`scripts/ios/static-check.ps1` 通过 17 / 失败 0 / 未验证 4。**编译、`swift test`、真机全部未执行**（无 macOS/Swift/Xcode）。
- 后端 `-tags postgres`：`go vet` 通过；集成测试**未执行**（Docker 守护进程 DNS 不可用，拉不到 postgres 镜像）。
- 独立审核：Reviewer 静态审查完成（2 条 P1、7 条 P2、若干 P3）；Tester 因 `spawn EPERM` **无法独立执行**，仅做基于原始证据的独立判定。

### 环境要点
- 工具进程环境变量为空，跑 go/gradle 必须显式传 `GOCACHE`/`GOPATH`/`PATH`/`JAVA_HOME`/`ANDROID_HOME`/`GRADLE_USER_HOME=D:\dev-cache\gradle`。
- 受限沙箱**禁止创建子进程**（spawn EPERM，属预期限制）；构建与测试需 `danger-full-access`。
- 一次 `run_code` 结束会回收整棵进程树，**不能跨调用常驻服务**。
- 工作区 DACL 已修复（ISSUE-20261029-005），此后受限模式可读写文件。

### 结论
**有条件通过**。条件：① 处理 ISSUE-20261029-008（iOS 状态机 P1）与 ISSUE-20261029-012（明文密钥）；② 在具备子进程权限的独立环境重跑真实验收；③ iOS 到 macOS 上跑 `verify-ios.sh` 并按 `docs/phase-1-device-acceptance.md` 做真机验收。

### 未完成项（交接）
1. Android 需在**无并发写入**的快照上再跑一次构建+单测，固定结论。
2. `go test -tags postgres ./internal/store/...` 需要可用 PostgreSQL。
3. `bash scripts/ios/verify-ios.sh`（需 macOS + Xcode 15 + XcodeGen）。交接说明已写好：`docs/HANDOFF-iOS.md`（给有 Mac 的人照着做）。
4. `.dsh-tmp/` 是共享临时目录，收尾按文件清理，勿整目录删除。

## 2026-10-29 16:10｜悬浮球真机验证（vivo V2361GA）

> 与上面两条任务是同一工作区里的第三条会话，只改 `apps/android` 里 `platform/overlay`、`ui/overlay` 及配套文档，未触碰后端与 iOS。

### 目标
用户要求「先装到 apk 给手机看看再进行阶段二」：把阶段一的悬浮球装进真机并实测，确认可用后再开工阶段二。

### 环境
- 设备：vivo V2361GA（PD2361M，Android 15 / SDK 35，1080×2400，density 480），adb 串口 `10AE5B01M7000AF`。
- 构建：JDK 17 + `D:\android-sdk`（platform 35 / build-tools 35.0.0），`GRADLE_USER_HOME=D:\dev-cache\gradle`，必须 `--offline`。
- 权限：已 `appops set com.daycue.android SYSTEM_ALERT_WINDOW allow`。

### 真机实测结果（全部有 logcat / dumpsys 证据）
- 通过：悬浮球不再闪退（ISSUE-022）；前台服务常驻（`isForeground=true foregroundId=4310 types=0x40000000`，通知渠道 assistant）；窗口为 `ty=APPLICATION_OVERLAY`，位于 StatusBar 之上。
- 通过：点球展开全屏菜单（`16:01:25.788/789 悬浮球收到点击，准备展开 / 已展开：全屏菜单窗口`），一级 5 扇区、二级（记录 3 个、待办 2 个）均正常组合。
- 通过：扇区选中与跳转（`悬浮球动作 -> tasks` / `-> records` / `-> memory`）；点环心返回上一级。
- 通过：系统清理杀进程后，重新打开 App 会自动把球挂回来（ISSUE-025 的自愈部分）。
- **失败/未通过**：悬浮球偶发完全收不到触摸（ISSUE-026，16:04 与 16:07 各一次），点击穿透到桌面；拖动（`input swipe`）未能取得窗口位置变化的证据。

### 本轮代码改动（`apps/android`）
1. `FloatingBallService`：`OverlayLifecycleOwner` 实现 `SavedStateRegistryOwner` 并 `setViewTreeSavedStateRegistryOwner`（修崩溃）。
2. `FloatingBallService`：展开前把球挪到「整圈放得下」的位置、收起还原；`onStartCommand` 幂等重挂；700ms 布局自检；先 `addView` 后 `setContent`；启动前台服务失败即收摊。
3. `RadialMenuSurface`：展开后 250ms 内不接管手势；点在球身上=收起；补组合日志。
4. 新增常量 `RING_OUTER_RADIUS_DP=148`（必须与 `RingOuterRadius` 一致）。
5. 单测未改动，`:app:testDebugUnitTest` 仍 24 类 / 266 用例 / 0 失败。

### 结论
**开发自测 + 真机部分验证**，不算正式验收：本会话没有独立 subagent 能力，按仓库规则整体验收结论仍为**未通过**；且 ISSUE-026（点不动）未解决前不应进入阶段二。

### 下一步
1. 需要用户在手机上确认：① 悬浮球在桌面上是否肉眼可见；② 连续点 10 次是否每次都能展开（ISSUE-026）。
2. 若确认「球可见但点不动」，优先怀疑 vivo 悬浮窗输入策略，评估降级方案（常驻通知 + 手势唤起）。
3. 拖动验收需要人工操作（脚本注入的 swipe 会被识别成滑动手势而非拖动）。
4. 阶段二（`assistant_op` 日志表 + `revision` + 撤销/回滚 + 删除二次确认）在 ISSUE-026 关闭后再开工。

## 2026-10-29 16:25｜吸附边框 + 视觉与动画 + 文字居中修复

### 用户新增要求
1. 悬浮球拖到屏幕中间后不能停在中间，要吸附到手机边框。
2. 美化悬浮球与扇区菜单，操作过程要有流畅动画。
3. 修「文字不在正中心」的 bug。

### 已完成（代码层面）
- `FloatingBallService`：新增 `snapToEdge()` + `animateTo()`（220ms 减速插值），拖动松手后吸附到最近左右边缘，纵向只夹进可见范围；展开/收起/销毁时打断吸边动画；窗口边长改为 76dp（球仍 64dp，多出的 12dp 用来放投影，避免阴影被窗口边界裁掉）。
- `FloatingBallContent`：径向外发光 + 斜向渐变球体 + 内圈留白 + 顶部高光；按下缩到 0.92、拖动放大到 1.06 的弹簧动画。
- `RadialMenuContent`：整圈以环心为原点做 `scale 0.72→1` + 淡入的 `Animatable` 入场（切换层级重播）、选中扇区 6dp 外扩的高亮过渡、扇区渐变底色 + 环外投影 + 圆心描边；选中后先播 120ms 退场再执行动作；手势层放在缩放层之外，命中区域始终 1:1。
- 圆心文字偏格修复：容器尺寸由「半径」改为「直径」（`size(RingInnerRadius * 2)`）。

### 验证状态
- `:app:assembleDebug` 通过；`:app:testDebugUnitTest` 24 类 / 266 用例 / 0 失败 / 0 跳过。
- **真机安装与验证未执行**：adb 于 16:18 起返回 `no devices/emulators found`（USB 断开或调试关闭），设备恢复后才能安装。

### 下一步
1. 设备恢复后：`adb install -r app-debug.apk` → 拖到屏幕中间松手看是否吸边 → 展开看动画与文字居中 → 连点 10 次（ISSUE-20261029-026）。
2. 若吸附后球遮挡内容，可再评估「贴边时半隐藏、只露一半」。

## 2026-10-29 17:10｜模拟器（AVD phone）补验「吸边 / 居中 / 交互」

### 背景
真机 16:18 起从 adb 掉线（`no devices/emulators found`），本轮改用本机 AVD `phone`（Android 15 / SDK 35 / 1080×2400 / 420dpi）做补验，目的只是给「代码改完但装不上去」的部分拿到可核查证据，不代表真机通过。

### 关键环境事实（下次接手必读）
- adb 绝对路径：`D:\Android\Sdk\platform-tools\adb.exe`（PATH 里没有）。
- 模拟器必须用 `Start-Process ... -WindowStyle Hidden` 或单次 run 内前台启动：detached spawn 会被沙箱回收，进程活不过一次 run。
- 悬浮球服务 `exported=false`，**不能**用 `am start-foreground-service` 从 shell 起；必须在 UI 里点开关：设置 tab (953,2232) → 行「悬浮球与语音」(540,1528) → 开关 (916,702)。
- `uiautomator dump` 可用，但 Windows cmd 会把 `>/dev/null`、`tail` 解释坏，必须 `adb shell "…"` 加引号、再用 `exec-out cat` 取文件。
- **拖动必须用手工分步注入**：`adb shell input swipe` 只让窗口动 ~11px（合成事件不足），要 `input motionevent DOWN` → 多次 `MOVE`（间隔 25ms）→ `UP`，14 步即可正常拖动并触发吸边。

### 实测结论（有 dumpsys / logcat / 截图像素证据）
- 球窗口：`199×199`（76dp@420dpi，多出的 12dp 放投影），初始 `x=866 y=1007`（右边−6dp），`ty=APPLICATION_OVERLAY`。
- **吸边（R12）通过**：拖到 (300,1150) → `x=15`（左边缘+6dp）；拖到 (800,1800) → `x=866`（右边缘−6dp）；纵向按手指保留（未被吸到上下边）。
- **居中（R14）通过**：解码 screencap PNG 做像素测量，圆心「关闭」相对环心偏移 (+0.0,+2.5)px；5 个扇区标签偏移 ≤(0.5,2.5)px（修复前按代码应为 −84,−84）。
- **交互通过**：点球展开（`要做什么，5 个扇区`）、点 18° 扇区进二级（`待办，2 个扇区，path=[1]`）、点 0° 扇区执行（`悬浮球动作 -> today`）；11 次点按 0 次丢事件，ISSUE-026 在模拟器上未复现。
- **新发现缺陷（ISSUE-20261029-028，P1）**：二级菜单点环心没有回上一级，而是把菜单整体关闭；根因是「点在球身上=收起」的 84px 热点先于 `RadialHit.Center` 分支执行。**尚未修改代码**，等授权后按「热点只在 path.isEmpty() 时生效」修。

### 状态与下一步
1. 等用户确认是否按建议修 ISSUE-028（一行判断，但要回归 ISSUE-023 贴边场景）。
2. 真机插回后仍需复测：吸边手感、动画流畅度、连点 10 次（ISSUE-026）、vivo 输入策略。
3. 阶段二仍未开工。

## 2026-10-29 20:05｜全功能真机巡检（vivo V2361GA，adb 驱动）

### 目标与范围
- 按用户要求「把软件所有功能试一遍看有没有异常」：在真机上用 adb 驱动逐屏操作，记录异常。
- 设备：vivo V2361GA / Android 15 / SDK 35；逻辑分辨率 1080×2400（density 480）；APK 为 16:24 构建的 `app-debug.apk`（含吸边 + 视觉动画 + 文字居中修复）。
- 方法：`am start` + `uiautomator dump` 取节点坐标 → `input tap/swipe/text` → 每次动作后抓 `logcat`；主题切换用 screencap 解码 PNG 算平均亮度做客观比对；悬浮球用 `dumpsys window windows` 的 `mAttrs` 与 `dumpsys input` 的 `frame` 交叉定位。

### 本轮新发现（已写入 ISSUE_LOG）
- ISSUE-029 P2 表单页底部按钮被输入法遮挡（记一笔「保存」、新建待办「创建」键盘弹着时点不动）。
- ISSUE-030 P2 文字记录详情显示「这条记录没有可预览的内容」，看不到正文。
- ISSUE-031 P3 图片记录卡片显示「这张图读不出来了」（待确认，缺新建图片对照）。
- ISSUE-032 P2 学期基准页首次进入为空，直接保存报「第一周周一要写成 2026-09-01 这样的格式」，学期设不上。
- ISSUE-033 P2 学期基准接受非周一日期（2026-09-01 是周二），课表按「周一起点」解释，星期整体错一天（待确认）。
- ISSUE-034 P3 空 ICS 点「确认导入」无任何反馈。
- ISSUE-035 P3 「测试连接」失败文案复用「内容已保存在本机」。
- ISSUE-028（P1，17:04 在 AVD 发现）本轮在**真机独立复现成功**：二级菜单点环心 = 关闭整个菜单，而不是回上一级。

### 已验证正常（本轮实测通过）
- 文字记录保存链路：保存 → 记录列表出现该条（计数 6 条）→ 删除该条（回到 5 条）。删除无二次确认（阶段 2 才要求，属预期）。
- 待办：新建（`TaskTest1926`，提示「任务已保存到本机。」）→ 完成 → 已完成页出现「重新打开/删除」→ 删除清理成功；空标题提交有「课程名不能为空。」类校验（课程表单）与空名拦截。
- 课表：空态文案、学期基准保存后周区间显示「第 1 周 · 2026-09-01 – 2026-09-07」。
- 课后追问：空态正常。
- 设置：账号与同步 / 通知与主动帮助 / 地点与规则 / 课表与学期 / 悬浮球与语音 / 权限（全部已授予）/ 外观 / 数据管理 / 高级设置 全部可进；悬浮球页显示「已授权」「运行中」。
- 主题：跟随系统 → 浅色 243、深色 32、再回跟随系统 243（系统为浅色），切换即时生效、可逆。
- 悬浮球：拖动松手吸附左右边缘（`x=18` / `x=834`，纵向保持）；点击展开为 `fillxfill`；扇区下钻 `path=[1]`；点叶子执行 `悬浮球动作 -> tasks` 并跳转 App；点环外空白关闭；收起后球回到展开前位置（`834,244`）。
- 冷启动/回前台自愈正常，前台服务与常驻通知存在。

### 未验证 / 限制
- 悬浮球的视觉美化与文字居中：vivo `screencap` **不包含悬浮层**，像素级取证不可行（AVD 上已由 027 的像素测量覆盖），需人工目视。
- 相机拍照、录音：需要真实采集，未执行。
- 语音唤醒：本版本未接入（设置页已明示），不适用。
- AI 解析/转写/追问生成：后端 `127.0.0.1:8787` 在手机上无服务，全部返回「连接失败/解析失败」，属环境限制。
- 独立多 Agent 审核未执行（本会话无 subagent 调度能力），故本轮**只能给开发自检结论，不能算正式验收通过**。

### 下一步（等用户确认）
1. 修 ISSUE-028（P1）：把「点球身=收起」热点收窄为 `path.isEmpty()` 时才触发，非根层走 `RadialHit.Center` 回上一级，并回归 ISSUE-023 贴边场景。
2. 修 ISSUE-029（P2）：表单页加 `imePadding()` + 可滚动 / bottomBar 跟随 IME inset。
3. 修 ISSUE-030（P2）、ISSUE-032（P2）；ISSUE-033 需要一次真实建课对照后再定。
4. 若要 AI 功能可用：把后端地址改成局域网 IP 并启动 `services/api`，再复测解析/转写。
## 2026-10-29 20:10｜问题档案结构修复（仅文档，未动业务代码）

### 背景
巡检报告落盘后核对 `docs/ISSUE_LOG.md`，发现三处文档完整性问题（不影响代码，但会让审核者读错记录）：

### 已修
1. **问题索引表被空行拆成两张表**：029–035 七行被追加到空行之后，Markdown 里丢了表头。已合并回单张表，35 行覆盖 35 个唯一 ID。
2. **回归测试索引同样被拆成 3 张表**（并有一行 `| — |` 单元测试汇总行错位）。已合并为单张表，35 个问题 ID 全覆盖。
3. **编号撞号**：`ISSUE-20261029-015/016/017` 各有两个不同问题的详情（早期编号与后来重编号的 `019/020/021` 重复）。按「保留历史不删除」原则，在三条早期记录上加「编号说明」指向权威记录，并在索引表下加脚注。

### 证据
- 修复前：详情 38 条 / 唯一 ID 35 个 / 重复 ID 3 个（015, 016, 017）；索引表被拆 2 段、回归表被拆 3 段。
- 修复后：详情 35 个唯一 ID 全部在索引与回归索引中出现，缺索引 0、缺回归 0，表内无空行打断。
- 本次只改 `docs/ISSUE_LOG.md` 与本文件，`git status` 中业务代码的修改项均为此前各轮遗留，本轮未新增。

### 下一步
- 仍等用户授权再修 ISSUE-028（P1）与 029/030/032（P2）；未授权前不改代码。

## 2026-10-29 20:20｜修复 028（P1）→ 029 → 030 → 032（用户 20:07 授权，按此顺序）

### 实际改动（7 个业务文件 + 2 个新文件）
- **ISSUE-028（P1）二级菜单点圆心不回上一级**：新增 `domain/radial/RadialTapResolver.kt`（`RadialTapOutcome` + `resolveRadialTap`），把「球身热点 / 圆心 / 扇区 / 环外」的优先级收进纯逻辑；`RadialMenuSurface.tapAt` 只做结果到 UI 动作的翻译。语义变更：球身热点只在最外层生效，非根层点圆心 = 回上一级。
- **ISSUE-029（P2）表单按钮被键盘遮挡**：根因是 `enableEdgeToEdge()` 之后全仓 0 处 `imePadding`，没有页面消费 `WindowInsets.ime`。给 CaptureScreen、NewTaskDialog、CourseEditScreen、IcsImportScreen、SettingsTermScreen 补 `Modifier.imePadding()`（在 `verticalScroll` 之前）。
- **ISSUE-030（P2）文字记录详情无正文**：`NoteListScreen.MediaPreviewDialog` 缺 `TEXT` 分支，补「正文」标签 + 正文文本（可滚动、限高 320dp），兜底文案只在真的没有内容时出现。
- **ISSUE-032（P2）学期基准首次为空且报格式错误**：`ScheduleWeekScreen.TermDialog` 无学期时预填当前查看周的周一；示例日期改为 `2026-09-07`（真周一）并补「请填周一日期」；`ScheduleViewModel` / `SettingsViewModel` 把「空值」与「格式错误」分开提示；设置侧弹窗同样预填。
- 新增测试：`src/test/java/com/daycue/android/domain/radial/RadialTapResolverTest.kt`（7 用例）。

### 验证结果（如实）
- `:app:assembleDebug`：通过（20:10、20:18 两次）。
- `:app:testDebugUnitTest`：**25 类 / 273 用例 / 0 失败**（新增 7 个用例）。
- **变异测试**：把 `path.isEmpty() &&` 去掉后，`RadialTapResolverTest.kt:42`（二级点圆心应为 Back）失败；恢复后通过 → 证明该测试能真正捕获本缺陷，不是空跑。
- **真机验证未执行**：adb 在 20:07 之后再次 `no devices/emulators found`（本机也未安装 emulator 组件，无法用 AVD 替代）。因此 028/029/030/032 的状态只能写「修复完成待真机验证」。

### 未做 / 遗留
- ISSUE-033（学期基准接受非周一日期导致星期错位）未改，等一次真实建课对照后再定；本次只把示例日期和提示改成周一，降低误填概率。
- ISSUE-031（图片记录读不出来）、ISSUE-034（空 ICS 无提示）、ISSUE-035（连接测试文案）未改。
- 独立多 Agent 审核未执行（本会话无 subagent 调度能力）→ 本轮结论只能算开发自检。

### 下一步（设备恢复后按顺序验证）
1. `adb install -r app-debug.apk`。
2. 028：展开 → 进「待办」（`path=[1]`）→ 点环心，应出现 `扇区菜单已组合：要做什么，5 个扇区，path=[]` 且窗口仍是 `fillxfill`；再点环心才关闭。同时回归 ISSUE-023：球贴右边缘点一下只展开、不跳页。
3. 029：记一笔输入文字后**不收起键盘**直接点「保存」，应保存成功；新建待办同样直接点「创建」。
4. 030：记录页点开一条文字记录，应看到「正文」+ 完整文本。
5. 032：清数据/干净安装后首次进「课表 → 学期」，日期框应已预填本周周一，直接保存成功。

## 2026-10-29｜服务器部署与「装完即连」APK（已完成）

### 目标
把 Go 后端部署到用户租的阿里云服务器 `114.215.171.135`，并重新编译一个「预置地址与令牌」的 APK，让手机装上就能直接连服务器（用户要求：不要在手机上手工填写）。

### 服务器现状（可核查）
- 主机：Ubuntu 22.04.5 LTS，x86_64，2 核 / 1.7 GB 内存 / 40 GB 盘（已用 3.9 GB）。无 Go 环境，故采用本机交叉编译 + 上传二进制。
- 服务：`/etc/systemd/system/daycued.service`（`User=daycue`，`ProtectSystem=strict`，`ReadWritePaths=/opt/daycue`），`enabled + active`。
- 配置：`/etc/daycue/daycue.env`（`chmod 600`，root 属主）：`DAYCUE_ADDR=0.0.0.0:8787`、`DAYCUE_AUTH_TOKEN`（44 字符，本轮新生成）、`DAYCUE_LLM_BASE_URL=https://airelay.buzz/v1`、`DAYCUE_LLM_MODEL=deepseek-v4.1-flash`、`DAYCUE_LLM_MERGE_SYSTEM_PROMPT=true`。
- 未配置数据库：`/v1/auth`、`/v1/sync`、`/v1/devices` 不存在，服务端不落任何用户数据（启动日志明确打印"云同步未启用"）。
- 下载服务：`daycue-download.service`（python3 http.server，8788），APK 在 `/opt/daycue/download/daycue.apk`；**8788 未在阿里云安全组放行，外网不可达**（8787 已放行）。

### 验证（全部真实执行）
- 服务内 `curl 127.0.0.1:8787/v1/health` → 200，`llm: configured`，`fixture_mode: false`。
- 公网 `http://114.215.171.135:8787/v1/health` → 200。
- 公网无令牌 POST `/v1/extractions` → 401；带令牌 → 200。
- 真实模型解析：「明晚八点提醒我复习 PV 操作」→ `2026-10-30T20:00:00` / `2026-10-30T12:00:00Z`；「周五之前交实验报告」→ `kind=date`、`remind=null`、`deadline_only`；「后天晚上七点半」→ `2026-10-31T19:30:00` / `11:30Z`。

### 代码改动（3 个文件，均已通过编译）
- `apps/android/app/build.gradle.kts`：开 `buildConfig = true`，新增 `DEFAULT_BACKEND_URL`（默认 `http://114.215.171.135:8787`，可用 `DAYCUE_BACKEND_URL` 覆盖）与 `DEFAULT_BEARER_TOKEN`（**只从构建期环境变量注入，不写源码**）。
- `apps/android/app/src/main/java/com/daycue/android/AppContainer.kt`：`init` 中若数据库里没有后端地址、或 Keystore 里没有令牌，则写入上述默认值（只写一次，用户之后手改不会被覆盖）。
- 产物：`apps/android/app/build/outputs/apk/debug/app-debug.apk`，58,119,181 字节（55 MB），已核对 `BuildConfig` 内地址正确、令牌 44 字符。

### 阻塞与待办
1. **手机直连下载需要放行 TCP 8788**（阿里云控制台安全组）。否则只能从本机把 APK 传到手机（USB / 微信文件传输）。
2. 真机未验证：手机有没有装上、装完能否解析、提醒是否正常，本轮**全部未验证**。
3. 明文 HTTP（ISSUE-20261029-024）与 APK 内嵌令牌（ISSUE-20261029-023）属已知风险，长期应换 HTTPS + 可撤销令牌。
4. 构建环境限制见 ISSUE-20261029-022：每次构建需把 Gradle 缓存复制进工作区 `.dsh-tmp/gradle-home`（1.7 GB）。

### 关键操作备忘
- 构建：`GRADLE_USER_HOME=E:\\PROJECT\\DayCue\\.dsh-tmp\\gradle-home`，并用 `java -classpath <dist>\lib\gradle-launcher-8.9.jar org.gradle.launcher.GradleMain :app:assembleDebug` 直启（wrapper 在本沙箱会因锁文件"拒绝访问"失败）。
- 部署用 SSH 公钥登录（用户已在 `authorized_keys` 加入本机公钥，可随时删除收回）。

## 2026-10-29 20:20–20:36｜复核 028/029/030/032 的改动与验证证据（本会话续做）

### 目标与范围
- 只做复核，不改业务代码；范围限定在 ISSUE-20261029-028 / 029 / 030 / 032 的实现落点与既有验证证据。

### 已核查（可复现的事实）
- `git status`：本轮改动的 19 个已跟踪文件仍在工作区（未提交），另有新增未跟踪目录 `domain/radial/`、`ui/overlay/`、`platform/overlay/` 及对应测试。
- 028：`domain/radial/RadialTapResolver.kt`（优先级注释齐全，`path.isEmpty() &&` 收窄仍在位）+ `RadialTapResolverTest.kt`（7 用例）；`RadialMenuSurface.tapAt` 已改为结果翻译。
- 029：`imePadding()` 共 5 处（CaptureScreen:170、TaskListScreen:220、CourseEditScreen:92、IcsImportScreen:52、SettingsTermScreen:51）；`AndroidManifest` 的 MainActivity 保持 `android:windowSoftInputMode="adjustResize"`，这是 ime insets 生效的前提。
- 030：`NoteListScreen.kt:532` 起为 TEXT 补「正文」分支，兜底文案只在真空时出现。
- 032：`ScheduleWeekScreen` 的 `TermDialog` 预填 `state.monday`、示例改 `2026-09-07`；`SettingsTermScreen` 预填本周周一；两个 ViewModel 都区分「空值」与「格式错误」。
- 单测复跑（主 Agent 独立执行，非开发者自述）：2026-10-29 20:34 `:app:testDebugUnitTest --rerun` → **25 类 / 273 用例 / 0 失败**；`:app:assembleDebug` → BUILD SUCCESSFUL，APK 重打包（`app-debug.apk` 20:34:30）。

### 未完成 / 阻塞
- **真机验证仍未执行**：`D:\android-sdk\platform-tools\adb.exe devices` 在 20:20 与本轮末尾均为空列表；本机无 emulator 组件（AVD 列表为空）。
- 030 的「正文」显示与 029 的键盘遮挡只能靠真机/模拟器肉眼确认，单测覆盖不到。
- 032 的「首次进入为空的干净状态」需要清一次 App 数据（会删除现有记录），**等用户授权**后再验。

### 关键操作备忘（重要，避免下次白等）
- 本会话里程序化执行 `gradlew.bat` 会因为子进程环境为空而重新联网下载 gradle-8.9 发行包（8 分钟超时）。正确姿势：
  `D:\gradle-8.9\gradle-8.9\bin\gradle.bat`（注意套了两层同名目录），cwd=`apps\android`，
  env 至少给 `JAVA_HOME=C:\Program Files\Java\jdk-17`、`GRADLE_USER_HOME=E:\PROJECT\DayCue\.dsh-tmp\gradle-home`、`ANDROID_HOME=D:\android-sdk`、`PATH`/`SystemRoot`/`TEMP`。
- 只重跑单测用 `:app:testDebugUnitTest --rerun`（`--rerun-tasks` 会全量重跑依赖，本会话里触发过 AAPT 打不开 stableIds.txt，见 ISSUE-20261029-037）。

### 下一步
1. 等设备上线：按 028 → 029 → 030 →（授权后清数据）032 的顺序真机验证。
2. 正式验收仍需两个独立 subagent（Tester + Reviewer），本会话不具备，结论只能是「开发自检 / 主 Agent 自查」。

### 2026-11-01 更新：APK 重出并逐字节校验（可下载）
- 发现 10-29 上传的 APK 与本地文件哈希不同：并发会话在未设置 `DAYCUE_DEFAULT_TOKEN` 的情况下重编过，产物令牌为空（见 ISSUE-20261029-025）。
- 处置：`:app:clean :app:assembleDebug` 重出 → 解包 `classes*.dex` 校验地址与令牌各命中 1 处 → 上传覆盖 → 服务器与本地 sha256 一致 → 公网完整下载 57,430,690 字节、4 秒、哈希一致、`Content-Type: application/vnd.android.package-archive`。
- 当前交付物：`http://114.215.171.135:8788/daycue.apk`，sha256 `5b08e66bdb8fe0fcdd73579666f3fea1f967d5ccfdd938a0f3269a9e011d2a17`。
- 8788 已由用户在阿里云安全组放行，`daycued` 与 `daycue-download` 两个服务在 2 天 15 小时后仍为 active。
- 仍未验证：真机安装与实际解析（无设备）。

### 2026-11-01 11:25｜手机端首次跑通（收尾状态）
- **结论**：Android 真机已完整跑通"文字输入 → 保存本地 → 提取待办 → 服务端真实模型解析 → 返回结构化条目"。
- **真机**：vivo V2361GA（PD2361M），通过 adb 安装 debug 包（sha256 `7b797f2d…94ed2`）。
- **本轮修掉的两个阻断**：① 库里残留 `http://127.0.0.1:8787` 导致请求打向手机自身（ISSUE-20261101-001，改 `AppContainer.kt` 覆盖回环地址 + 令牌对齐）；② 上游模型 `deepseek-v4.1-flash` 已下线导致一律 502（ISSUE-20261101-003，改 `DAYCUE_LLM_MODEL=deepseek-flash`）。
- **关键证据**：服务端 `2026-11-01 11:22:16 POST /v1/extractions → 200`（756 字节 / 2243 ms）；PC 侧同一请求 9373 ms，"明天晚上8点…"→`2026-11-02T20:00:00` / `12:00Z`。
- **未完成**：语音转写（服务端无 ASR 供应商，中转站 `/audio/transcriptions` 实测 404，ISSUE-20261101-002）；iOS 全线未验证；真机未验证通知/后台提醒是否按时刻弹出。
- **临时产物**：`.dsh-tmp/gradle-home`（1.7 GB，构建用缓存）保留以便复现构建；从手机导出的数据库副本、APK 解包目录已删除。
- **后续建议**：给中转站模型变化加启动自检或把上游 4xx 与 5xx 分开映射；长期换 HTTPS + 可撤销令牌。

### 2026-11-01 13:10｜iOS 编译前置配置 + Android 系统听写（方案 B）
- **iOS**：按用户要求改好三处，使 Mac 端"生成工程 → 选 Team → 运行"即可连服务器。
  - `project.yml`：加 ATS 例外（`NSAllowsArbitraryLoads`）、加 `DAYCUE_DEFAULT_TOKEN` 构建设置与 Info.plist 键 `DayCueDefaultToken`。
  - `DayCueStore.swift`：`defaultAPIBaseURL` 改为 `http://114.215.171.135:8787`。
  - `AppSettings.swift`：回环地址覆盖 + Keychain 空时写入构建期令牌。
  - 交接文档 `docs/HANDOFF-iOS.md` 已重写为可照抄清单（xcodegen、签名、7 天有效期、令牌来源、验证步骤、风险）。
  - **未编译**：当前环境没有 macOS/Swift 工具链，Swift 改动未经编译器检查。
- **Android 语音**：新增 `platform/speech/SystemSpeechInput.kt`，录音入口改为"系统听写优先、不可用回退后端转写"；`speech_transcription` 能力改为按实际可用性上报。APK `fc029bfc…c7e3` 已安装到真机（11:43:07），**识别效果尚未验证**。
- **安装教训**：vivo 的包安装器覆盖安装时先卸载旧包，中途被拒会变成"旧包已删、新包未装"，本地数据一并丢失（11:38 日志可见 `Package removed`）。改用 `adb install --no-streaming` 后，失败时数据目录可保留；后续安装前应先备份 `/data/data/com.daycue.android/databases`。

### 2026-11-01 15:40｜iOS 模拟器编译通过（b86a676）
- 朋友在其 Mac 上修复剩余 4 处错误并推送 `b86a676`，同时打了标签 `ios-simulator-b86a676`；本地已 `pull --ff-only` 同步，工作区干净。
- 四处改动：AppSettings / DebugWriteFaultInjection 补 `import DayCueCore`；`AudioRecorderService.start()` 的 `guard` 改 `if`（原写法 else 分支会穿透）；`EditableRule.init(rule:timeZone:)` 移入扩展以保留 memberwise init。
- 复核确认此前部署配置未被覆盖：ATS 例外、`DAYCUE_DEFAULT_TOKEN` 注入、默认后端地址 `http://114.215.171.135:8787`、回环覆盖与令牌预置逻辑、Geo 参数顺序修复均仍在。
- 仍未验证：真机安装、ATS 实际放行、令牌写入 Keychain、端到端提取链路。
