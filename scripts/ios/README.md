# iOS 验证脚本

这里有两个脚本，职责完全不同，**不要把它们混为一谈**。

| 脚本 | 运行平台 | 能证明什么 |
|---|---|---|
| `static-check.ps1` | Windows / macOS 均可 | 文件结构、括号平衡、target 归属、配置引用是否自洽 |
| `verify-ios.sh` | **仅 macOS** | DayCueCore 测试通过、工程可生成、App 可编译 |

---

## static-check.ps1

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ios/static-check.ps1
```

本机（Windows）实测结果：**通过 17，失败 0，未验证 4**。

它做六件事：

1. 目录结构：`Sources/DayCueCore`、`Sources/DayCueApp`、`Tests/DayCueCoreTests`、
   `Package.swift`、`project.yml` 是否齐全；
2. **括号平衡**：逐字符词法扫描，跳过行注释、块注释、字符串与三引号字符串。
   直接数括号会误报——注释和字符串里都会出现括号，所以这里必须真的扫描；
   文件按 UTF-8 显式读取，否则 PowerShell 默认按本地代码页读，中文注释会变乱码；
3. **target 归属**：DayCueCore 里不得出现 `import UIKit/SwiftUI/EventKit/AVFoundation/...`。
   这是 DayCueCore 能否在 macOS 上 `swift test` 的前提；
4. `project.yml` 引用的源码目录、本地 SPM 包目录、4 项权限文案是否存在；
5. `Package.swift` 是否引用了两个 target 目录；测试文件是否都 `import XCTest`；
6. **如实列出本机无法执行的检查**（swift build/test、xcodegen、xcodebuild、真机行为）。

> **静态检查通过 ≠ 能编译。** 脚本自己会把这句话打印在最后一行。

---

## verify-ios.sh

```bash
bash scripts/ios/verify-ios.sh              # 全流程
bash scripts/ios/verify-ios.sh --skip-core  # 跳过 swift test
bash scripts/ios/verify-ios.sh --build-only # 只生成工程并构建
```

五个步骤：

1. **记录版本**：macOS、`xcodebuild -version`、`swift --version`、`xcodegen --version`、
   `xcrun simctl list runtimes`、`xcodebuild -showsdks` → `apps/ios/build/logs/versions.txt`。
   没有版本信息的「测过了」无法复现，所以这一步必须留下记录；
2. `swift test` —— DayCueCore 不依赖 UIKit/EventKit，**不需要模拟器、不需要签名**，
   是唯一能在命令行直接跑的自动化测试；
3. `xcodegen generate`；
4. `xcodebuild -list -json` 解析出 scheme 与 target 列表。
   **故意不硬编码 scheme 名字**：如果 `project.yml` 改了名字，这里必须跟着报错，
   而不是拿一个不存在的名字去构建然后误判成通过。
   若工程里没有 Xcode 测试 target（当前就是如此），脚本会**如实报告**，不会假装跑了测试；
5. 为 `generic/platform=iOS Simulator` 构建，`CODE_SIGNING_ALLOWED=NO`，日志落在
   `apps/ios/build/logs/xcodebuild-build.log`。

### 依赖

- `xcodebuild`、`swift`：随 Xcode，需要 `sudo xcode-select -s /Applications/Xcode.app`
- `xcodegen`：`brew install xcodegen`
- `python3`：用于解析 `xcodebuild -list -json`，随 Command Line Tools（`xcode-select --install`）

脚本对三者在缺失时都会给出明确报错，不会用难以理解的堆栈收场。

### 这个脚本验证不了什么

- **提醒事项的读写、权限授权与撤销**（EventKit 需要真实系统权限）
- **录音、语音识别、OCR、本地通知**
- **界面在任何状态下的实际表现**

这些只能按 [phase-1-device-acceptance.md](../../docs/phase-1-device-acceptance.md) 在真机上逐条执行。
用 mock 或模拟器「跑通」不等于 EventKit 验收通过。

---

## 注意：本仓库的 iOS 代码从未被编译过

开发环境是 Windows，没有 Swift 工具链与 Xcode，因此：

- `verify-ios.sh` **从未运行过**，它在本机也不具备语法校验条件（无可用的 bash）；
- iOS 的 89 个用例**一个都没跑过**（13 个测试文件）；
- 首次在 Mac 上执行时，最可能需要调整的点见
  [apps/ios/README.md 第 7 节](../ios/README.md) 与
  [phase-1-acceptance.md 第 8 节](../../docs/phase-1-acceptance.md)。

任何把这里的静态检查结果当作「iOS 已可运行」的解读都是错的。
