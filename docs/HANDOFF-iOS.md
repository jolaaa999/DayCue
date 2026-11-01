# DayCue iOS｜在 Mac 上编译与安装（交接文档）

> 更新：2026-11-01。Android 端已在真机跑通（vivo V2361GA），iOS 端**仍未编译过任何一次**。
> 本文给出在 Mac 上从零到装进 iPhone 的完整步骤，以及已经替你做好的前置配置。

## 0. 一句话现状

代码在这台 Windows 上写完，没有 Swift 工具链，因此 **iOS 从未编译、从未在真机运行**。
第一次 `xcodebuild` 大概率还会报几处编译错误（类型/签名/并发注解之类），需要在 Mac 上现场修。
业务逻辑（DayCueCore）由 SwiftPM 管理，可以在 Mac 上单独 `swift test`，不需要手机。

## 1. 需要什么

| 项 | 要求 |
|---|---|
| Mac | Intel 或 Apple Silicon 都行，macOS 14 以上 |
| Xcode | 15.0 及以上（工程部署目标 iOS 17.0 / Swift 5.9） |
| XcodeGen | 仓库里没有 `.xcodeproj`，必须用它生成 |
| Apple ID | 免费个人账号即可；签出来的 App **7 天过期**，到期要重装 |
| iPhone | iOS 17 以上 |

## 2. 已替你改好的三处（2026-11-01）

| 文件 | 改动 | 为什么 |
|---|---|---|
| `apps/ios/project.yml` | Info.plist 增加 `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` | 后端是明文 `http://`，iOS 的 ATS 默认拦掉全部请求，症状是"网络不可用" |
| `apps/ios/project.yml` | 增加 `DAYCUE_DEFAULT_TOKEN` 构建设置 + Info.plist 键 `DayCueDefaultToken: $(DAYCUE_DEFAULT_TOKEN)` | 让令牌在构建期注入，**不进仓库** |
| `DayCueStore.swift` | `defaultAPIBaseURL` 由 `http://127.0.0.1:8787` 改为 `http://114.215.171.135:8787` | 回环地址在真机上指向手机自己，Android 端已因此白排查一小时 |
| `AppSettings.swift` | 启动时：存储值为回环地址则覆盖为默认地址；Keychain 无令牌则写入 `DayCueDefaultToken` | 装完即连，不用在手机上打字 |

## 3. 编译步骤

```bash
# 1) 装 XcodeGen（只第一次需要）
brew install xcodegen

# 2) 生成工程
cd DayCue/apps/ios
xcodegen generate          # 产出 DayCue.xcodeproj

# 3) 打开
open DayCue.xcodeproj
```

在 Xcode 里：

1. **Xcode → Settings → Accounts** 登录自己的 Apple ID
2. 选中 `DayCue` target → **Signing & Capabilities** → Team 选刚登录的账号
3. **Bundle Identifier 改成唯一值**（如 `com.zhangsan.DayCue`），默认的 `com.daycue.DayCue` 可能被占用
4. **注入令牌**：Build Settings 右上角切换 **All + Combined**，搜索 `DAYCUE_DEFAULT_TOKEN`，
   在 User-Defined 里把值设为服务器令牌（见第 5 节）。留空则 App 首次启动没有令牌，请求会 401
5. 手机用数据线连 Mac → 顶部选你的 iPhone → `⌘R`

iPhone 首次还需要：

- 设置 → 通用 → **VPN 与设备管理** → 信任你的开发者证书
- 设置 → 隐私与安全性 → **开发者模式** → 打开（iOS 16+ 要求，会要求重启）

## 4. 只跑逻辑测试（不需要手机）

```bash
cd DayCue/apps/ios
swift test
```

DayCueCore 只依赖 Foundation / CryptoKit / SQLite3，在 macOS 上可直接跑全部单元测试。

## 5. 服务器令牌从哪来

- 服务器上：`ssh root@114.215.171.135 'grep DAYCUE_AUTH_TOKEN /etc/daycue/daycue.env'`
- 或向维护者索取（不要在聊天工具里公开发）

令牌是 44 字符的 base64 字符串。

## 6. 装好之后怎么验证

1. 打开 App → 设置页应显示后端地址 `http://114.215.171.135:8787`
2. 在"记录"页输入：`明天晚上八点提醒我复习操作系统里面的PV操作` → 保存 → **提取待办**
3. 预期：出现候选卡片，截止时间 = 明天 20:00
4. 服务端会留下一条 `POST /v1/extractions 200` 的日志，可作为旁证
5. 语音：iOS 端用系统 `SFSpeechRecognizer`（`TranscriptionService.swift` 的 `CompositeTranscriber`），
   首次会请求麦克风与语音识别权限；系统识别失败会自动兜底到 `POST /v1/transcriptions`
   （该接口当前返回 503，因为服务器没有配 ASR 供应商，属预期）

## 7. 已知风险与限制

1. **从未编译**：第一次构建可能有编译错误，需在 Mac 上迭代修改；这部分维护者无法远程代做。
2. **7 天签名有效期**：免费账号签的包一周失效，重新连 Mac 装一次即可；长期使用需 99 美元/年开发者账号。
3. **明文 HTTP**：当前后端无证书，ATS 已放开；后端上 HTTPS 后应删除 `project.yml` 里的 ATS 段并把地址改成 `https://`。
4. **令牌随包分发**：拿到这个 App 的人就能用这台服务器的模型额度，勿外传。
5. **云同步不可用**：服务器没装数据库，`/v1/auth`、`/v1/sync`、`/v1/devices` 都不存在（返回 404），属于预期。

## 8. 遇到编译错误怎么办

把 `xcodebuild` 的完整报错（文件 + 行号 + 错误信息）发回来，维护者按报错改代码。
不要用"注释掉报错行"或"加 try? 吞掉"的方式绕过——那会把问题留到真机上更难查。
