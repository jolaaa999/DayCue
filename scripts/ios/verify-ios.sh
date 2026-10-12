#!/usr/bin/env bash
#
# DayCue iOS 验证入口（必须在 macOS 上运行）。
#
# 设计原则：**不猜任何名字**。
# scheme、target、模拟器型号全部从生成后的真实工程里读出来，读不到就明确失败，
# 而不是回退到一个硬编码的名字、让人误以为验证过了。
#
# 用法：
#   bash scripts/ios/verify-ios.sh            # 版本 + Core 测试 + 生成工程 + 构建 App
#   bash scripts/ios/verify-ios.sh --build-only
#   bash scripts/ios/verify-ios.sh --skip-core
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/apps/ios"
BUILD_DIR="$IOS_DIR/build"
LOG_DIR="$IOS_DIR/build/logs"

SKIP_CORE=0
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-core) SKIP_CORE=1 ;;
    --build-only) BUILD_ONLY=1; SKIP_CORE=1 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"

fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }
step() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------- 1. 版本记录
# 这些版本号要写进验收报告：没有版本信息的"测过了"无法复现。
step "1/5 环境与版本"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "macos: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  echo "xcodebuild: $(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo '未安装')"
  echo "swift: $(swift --version 2>&1 | head -1 || echo '未安装')"
  echo "xcodegen: $(xcodegen --version 2>&1 | head -1 || echo '未安装')"
} | tee "$LOG_DIR/versions.txt"

command -v xcodebuild >/dev/null 2>&1 || fail "找不到 xcodebuild。请先安装 Xcode 并执行 sudo xcode-select -s /Applications/Xcode.app"
command -v swift >/dev/null 2>&1 || fail "找不到 swift。"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "! 找不到 xcodegen。brew install xcodegen 后才能生成 .xcodeproj。"
fi

xcrun simctl list runtimes 2>/dev/null | tee "$LOG_DIR/simulator-runtimes.txt" || true
xcodebuild -showsdks 2>/dev/null | tee "$LOG_DIR/sdks.txt" || true

# ------------------------------------------------- 2. DayCueCore 的跨平台测试
# 这一层不依赖模拟器、不依赖签名，是唯一能在 macOS 上直接跑的自动化测试。
if [ "$SKIP_CORE" -eq 0 ]; then
  step "2/5 DayCueCore 单元测试（swift test，不需要模拟器）"
  cd "$IOS_DIR" || fail "进不去 $IOS_DIR"
  if swift test 2>&1 | tee "$LOG_DIR/swift-test.log"; then
    PASSED=$(grep -c "Test Case .* passed" "$LOG_DIR/swift-test.log" 2>/dev/null || echo 0)
    ok "swift test 通过（检测到 $PASSED 条 Test Case 通过记录）"
  else
    fail "swift test 失败，详见 $LOG_DIR/swift-test.log"
  fi
else
  step "2/5 跳过 DayCueCore 测试"
fi

# ---------------------------------------------------------- 3. 生成 Xcode 工程
step "3/5 生成 Xcode 工程"
cd "$IOS_DIR" || fail "进不去 $IOS_DIR"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 未安装，无法生成工程"
xcodegen generate 2>&1 | tee "$LOG_DIR/xcodegen.log" || fail "xcodegen generate 失败"
[ -d "$IOS_DIR/DayCue.xcodeproj" ] || fail "生成后仍然找不到 DayCue.xcodeproj"
ok "已生成 $IOS_DIR/DayCue.xcodeproj"

# ------------------------------------------------------ 4. 从真实工程读 scheme
# 故意不硬编码 "DayCue"：如果 project.yml 改了名字，这里必须跟着报错，
# 而不是用一个不存在的 scheme 去构建然后误判。
step "4/5 读取 scheme 与测试 target（不猜名字）"
command -v python3 >/dev/null 2>&1 || fail "找不到 python3。它随 Xcode Command Line Tools 一起安装：xcode-select --install"

xcodebuild -project DayCue.xcodeproj -list -json > "$LOG_DIR/xcodebuild-list.json" 2>"$LOG_DIR/xcodebuild-list.err" \
  || fail "xcodebuild -list 失败，详见 $LOG_DIR/xcodebuild-list.err"

SCHEMES=$(python3 -c "
import json,sys
d=json.load(open('$LOG_DIR/xcodebuild-list.json'))
p=d.get('project',{})
print(' '.join(p.get('schemes',[])))
print('TARGETS='+' '.join(p.get('targets',[])))
")
SCHEME_LIST=$(echo "$SCHEMES" | head -1)
TARGET_LIST=$(echo "$SCHEMES" | grep '^TARGETS=' | cut -d= -f2-)

echo "schemes : $SCHEME_LIST"
echo "targets : $TARGET_LIST"
[ -n "${SCHEME_LIST// /}" ] || fail "工程里没有任何 scheme，无法构建"

APP_SCHEME=$(echo "$SCHEME_LIST" | tr ' ' '\n' | grep -v -i test | head -1)
[ -n "$APP_SCHEME" ] || fail "找不到用于构建 App 的 scheme"

# 如实报告：本工程目前没有 Xcode 测试 target，自动化测试全在 SPM 里。
if echo "$TARGET_LIST" | grep -qi "Tests"; then
  ok "工程里存在测试 target：$(echo "$TARGET_LIST" | tr ' ' '\n' | grep -i Tests | tr '\n' ' ')"
else
  echo "! 本工程没有 Xcode 测试 target —— 自动化测试只在 swift test（DayCueCore）里。"
  echo "  App 层（EventKit / AVFoundation / Vision）的验证只能靠真机清单：docs/phase-1-device-acceptance.md"
fi

# ---------------------------------------------------- 5. 为模拟器构建 App
step "5/5 为 iOS 模拟器构建 App（scheme=$APP_SCHEME）"
DEST_LIST=$(xcodebuild -project DayCue.xcodeproj -scheme "$APP_SCHEME" -showdestinations 2>/dev/null | tee "$LOG_DIR/destinations.txt")
echo "$DEST_LIST" | grep -E "platform:iOS Simulator" | head -20 || true

if [ "$BUILD_ONLY" -eq 0 ]; then
  echo
  echo "下一步（真机/模拟器行为验收）需要人工执行，见 docs/phase-1-device-acceptance.md"
fi

set -o pipefail
xcodebuild \
  -project DayCue.xcodeproj \
  -scheme "$APP_SCHEME" \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$LOG_DIR/xcodebuild-build.log" | tail -30

BUILD_STATUS=${PIPESTATUS[0]}
if [ "$BUILD_STATUS" -ne 0 ]; then
  echo
  fail "App 构建失败。完整日志：$LOG_DIR/xcodebuild-build.log
常见原因见 docs/phase-1-acceptance.md 第 7 节（iOS 17 权限 API 签名、XcodeGen 本地包引用）。"
fi
ok "App 已为 iOS 模拟器构建成功"

echo
echo "======================================================================"
echo "本脚本能验证的：环境版本、DayCueCore 单元测试、工程生成、App 编译。"
echo "本脚本**不能**验证的：任何需要真实系统权限的行为（提醒事项读写、录音、"
echo "语音识别、OCR、通知）。那些必须在真机上按 docs/phase-1-device-acceptance.md 逐条执行。"
echo "======================================================================"
