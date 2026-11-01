# DayCue｜需求 → 实现 → 测试 追踪表

> 维护规则：每一条可观察的需求都必须能指到「哪段代码」和「哪条验证」。
> 没有验证的需求一律写「未验证」，不因为代码存在就标成完成。
> 本表随交付推进更新；正式验收前必须逐行核对。

## 本轮（阶段 1：桌面悬浮球 + 环形多级扇区菜单）

需求来源：2026-10-29 用户需求——「桌面存在一个悬挂球，点击后出现环形多级扇区菜单」。
（同批需求里的语音常听唤醒与 AI 全权限操作属阶段 2–5，见下方「后续阶段」）

| 需求 ID | 需求（可观察） | 实现落点 | 验证 | 状态 |
|---|---|---|---|---|
| R1 | 桌面存在一个常驻的圆形悬浮球，覆盖在其他应用之上 | `platform/overlay/FloatingBallService.kt`（前台服务 + WindowManager）、`ui/overlay/RadialMenuSurface.kt`（FloatingBallContent） | 真机 vivo V2361GA：window 为 `ty=APPLICATION_OVERLAY`、位于 StatusBar 之上、服务 `isForeground=true foregroundId=4310`；**但截图对比无法证明球可见**，且存在点不动的情况（ISSUE-022 修好崩溃、ISSUE-026 未解决） | 已实现 / 真机部分验证（球可见性待人工确认） |
| R2 | 悬浮球可拖动，拖出屏幕会被夹回可见区域 | `FloatingBallService.moveBy`（coerceIn 夹取） | 脚本注入的 `input swipe` 未产生窗口位移证据（可能被识别成滑动手势），**需人工拖动确认** | 已实现 / 真机未验证 |
| R3 | 点击悬浮球展开环形扇区菜单，一级 5 个扇区 | `ui/overlay/RadialMenuCatalog.kt`（root）、`ui/overlay/RadialMenuSurface.kt`（RadialMenuContent） | `RadialMenuCatalogTest`；真机 logcat `16:01:25 已展开：全屏菜单窗口` + `扇区菜单已组合：要做什么，5 个扇区` | 已实现 / JVM 测试通过 / 真机已验证 |
| R4 | 扇区命中判定正确（点到的扇区就是高亮/执行的扇区） | `domain/radial/RadialGeometry.kt` | `RadialGeometryTest` 11 条：4/5/2/3/6/8 扇区下「中心角回落自身」、边界归属、内外半径、异常入参 | 已实现 / JVM 测试通过（11 条全绿） |
| R5 | 多级：有子级的扇区进入下一级，圆心变「返回」，根层是「关闭」 | `domain/radial/RadialMenuModel.kt`、`RadialMenuSurface.kt` | `RadialMenuModelTest` 9 条；真机 logcat 二级组合证据 `扇区菜单已组合：记录，3 个扇区，path=[0]`、`待办，2 个扇区，path=[1]`，点环心回到根层 | 已实现 / JVM 测试通过 / 真机已验证 |
| R6 | 选中叶子扇区后打开 App 对应页面（记录/待办/课表/记忆/今天） | `FloatingBallService.perform` → `OverlayController.openApp` → `MainActivity.onNewIntent` → `DayCueApp` 路由请求消费 | `RadialMenuCatalogTest`；真机 logcat `悬浮球动作 -> tasks` / `-> records` / `-> memory`，App 被拉起并落在对应页面 | 已实现 / 真机已验证（跳转链路） |
| R7 | 悬浮球开关 + 悬浮窗权限 + 运行状态三者分开如实显示 | `ui/settings/SettingsAssistantScreen.kt`、`platform/overlay/OverlayPermission.kt` | 仅静态检查；**未真机验证** | 已实现 / 真机未验证 |
| R8 | 没有悬浮窗权限时不写「已开启」，而是引导授权 | `SettingsAssistantScreen.setBallEnabled`、`OverlayController.start` 返回 false | 代码路径有明确分支；**未真机验证** | 已实现 / 真机未验证 |
| R9 | 前台服务必须显示不可取消的常驻通知，并可从通知里关闭 | `FloatingBallService.buildNotification`、`NotificationChannels.ASSISTANT`（IMPORTANCE_LOW）、strings.xml | 真机 `dumpsys activity services`：`foregroundNoti=Notification(channel=assistant ... flags=ONGOING_EVENT)`；通知栏点击关闭未人工验证 | 已实现 / 真机部分验证 |
| R10 | 回前台时若开关开着但服务没在跑，自动补启一次（不能从后台启动前台服务） | `MainActivity.onResume` | 真机：系统清理杀进程（ISSUE-025）后重新打开 App，logcat 出现新的 `悬浮窗 added` 并恢复原位 | 已实现 / 真机已验证 |
| R11 | 菜单里不出现尚未实现的入口（不放假入口） | `RadialMenuCatalog` 注释约束 + `RadialMenuCatalogTest` 路由白名单 | 测试通过 | 已实现 / JVM 测试通过 |

| R12 | 拖动松手后悬浮球吸附到最近的左右屏幕边缘，不留在屏幕中间 | `FloatingBallService.snapToEdge/animateTo`（ValueAnimator 220ms 减速插值）、`FloatingBallContent(onDragEnd)` | AVD `phone` 实测：拖到 (300,1150) → 窗口 x=15（=左边缘+6dp），拖到 (800,1800) → x=866（=右边缘−6dp），纵向按手指保留（y 由 1007→989 / →1530，未被吸到上下边） | 已实现 / 模拟器已验证 / 真机未验证 |
| R13 | 悬浮球与扇环菜单有基础视觉层次（渐变、投影、高亮）与入场/退场动画 | `ui/overlay/RadialMenuSurface.kt`（径向渐变 + 高光 + 环外投影 + `Animatable` 缩放淡入 + 退场后再执行动作） | AVD `phone`：菜单每层都能正常组合并渲染（截图为渐变扇环 + 环外投影 + 圆心描边），未出现掉帧崩溃；**动画流畅度需肉眼确认**（截图为静态帧，不能证明帧率） | 已实现 / 模拟器部分验证 |
| R14 | 圆心「关闭/返回」与所有扇区标签都居中，不偏格 | `RadialMenuContent`（圆心容器 `size(RingInnerRadius * 2)`、标签 `offset - box/2 + wrapContentSize(Center)`、`maxLines=1`） | AVD `phone` 截图像素测量：圆心文字偏移 (+0.0,+2.5)px；5 个扇区标签偏移 ≤(0.5,2.5)px（见 ISSUE-20261029-027） | 已修复 / 模拟器已验证 / 真机未验证 |

## 后续阶段（尚未实现，仅登记需求，避免被误读为已完成）

| 需求 ID | 需求 | 状态 |
|---|---|---|
| R20 | 语音唤醒（Android 常听：前台服务 + 常驻通知 + 离线唤醒词） | **未实现** |
| R21 | 语音唤醒降级（iOS：仅前台常听 + Siri / App Intents + 快捷指令） | **未实现**（iOS 编译环境不具备） |
| R22 | AI 对新增/更新直接执行，带操作日志与版本回溯 | **未实现** |
| R23 | 删除必须弹窗 + 语音二次确认，超时=取消 | **未实现** |
| R24 | 说「我今天学了量子物理」→ 记录页立刻出现这一条 | **部分**：当前走「悬浮球 → 记录 → 文字/语音」入口，语音转写与指令解析依赖阶段 3–4 |

## 验证环境

| 项 | 值 |
|---|---|
| 编译/测试 | `gradlew.bat :app:assembleDebug` + `:app:testDebugUnitTest`（离线） |
| JDK | 17（`C:\Program Files\Java\jdk-17`） |
| Android SDK | `D:\android-sdk`（platform 35 / build-tools 35.0.0） |
| Gradle | 8.9，`GRADLE_USER_HOME=D:\dev-cache\gradle` |
| 模拟器 | AVD `phone`（Android 15 / SDK 35 / 1080×2400 / 420dpi），`D:\Android\Sdk\emulator\emulator.exe -avd phone -no-window -gpu swiftshader_indirect`；`appops set com.daycue.android SYSTEM_ALERT_WINDOW allow` |
| 真机 | 2026-10-29 16:18 起 adb 掉线，真机项仍为「未验证」；模拟器结论不能替代真机（vivo 悬浮窗输入策略无法在模拟器上复核） |
