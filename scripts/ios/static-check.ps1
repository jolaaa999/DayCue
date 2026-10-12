# DayCue iOS 静态检查（Windows 上可运行，不需要 Swift / Xcode）
#
# 本脚本只做**能证明的事情**：文件结构、括号平衡、target 归属、配置引用、
# 以及"哪些检查根本无法在此机器上执行"。
#
# 它**不能**替代编译。任何"通过"都不代表代码能编译。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ios/static-check.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ios  = Join-Path $repo 'apps\ios'

$pass = 0
$fail = 0
$skip = 0

function Ok($m)   { $script:pass++; Write-Host "  [通过] $m" -ForegroundColor Green }
function Bad($m)  { $script:fail++; Write-Host "  [失败] $m" -ForegroundColor Red }
function Skip($m) { $script:skip++; Write-Host "  [未验证] $m" -ForegroundColor Yellow }

Write-Host '=== 1. 目录结构 ===' -ForegroundColor Cyan
foreach ($d in @('Sources\DayCueCore', 'Sources\DayCueApp', 'Tests\DayCueCoreTests')) {
    if (Test-Path (Join-Path $ios $d)) { Ok "存在 $d" } else { Bad "缺少 $d" }
}
foreach ($f in @('Package.swift', 'project.yml', 'README.md')) {
    if (Test-Path (Join-Path $ios $f)) { Ok "存在 $f" } else { Bad "缺少 $f" }
}

$coreFiles = Get-ChildItem (Join-Path $ios 'Sources\DayCueCore') -Filter *.swift
$appFiles  = Get-ChildItem (Join-Path $ios 'Sources\DayCueApp')  -Filter *.swift
$testFiles = Get-ChildItem (Join-Path $ios 'Tests\DayCueCoreTests') -Filter *.swift
Write-Host "  DayCueCore $($coreFiles.Count) 个文件 / DayCueApp $($appFiles.Count) 个 / 测试 $($testFiles.Count) 个"

Write-Host '=== 2. 括号平衡（词法扫描，跳过注释与字符串）===' -ForegroundColor Cyan
# 直接数括号会误报：注释和字符串里都可能出现括号。
# 所以这里做一次真正的逐字符扫描，只在"代码"区域计数。
# 文件必须按 UTF-8 显式读取——PowerShell 默认按本地代码页读，中文注释会变乱码。
function Get-Balance([string]$path) {
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $n = $text.Length
    $b = 0; $p = 0; $k = 0
    $i = 0
    $inLine = $false; $inBlock = $false; $inStr = $false; $inMulti = $false
    while ($i -lt $n) {
        $c = $text[$i]
        $c1 = if ($i + 1 -lt $n) { $text[$i + 1] } else { [char]0 }
        $c2 = if ($i + 2 -lt $n) { $text[$i + 2] } else { [char]0 }

        if ($inLine)  { if ($c -eq [char]10) { $inLine = $false }; $i++; continue }
        if ($inBlock) { if ($c -eq '*' -and $c1 -eq '/') { $inBlock = $false; $i += 2; continue }; $i++; continue }
        if ($inMulti) { if ($c -eq '"' -and $c1 -eq '"' -and $c2 -eq '"') { $inMulti = $false; $i += 3; continue }; $i++; continue }
        if ($inStr) {
            # 必须用 [char]92 比较：PowerShell 单引号不处理转义，写成 '\\'
            # 其实是两个字符，与单个字符比较永远不相等，字符串内的 \" 就跳不过去，
            # 字符串状态被翻转后会把后面的代码当字符串，产生大片误报。
            if ([int][char]$c -eq 92) { $i += 2; continue }
            if ($c -eq '"') { $inStr = $false }
            $i++; continue
        }
        if ($c -eq '/' -and $c1 -eq '/') { $inLine = $true; $i += 2; continue }
        if ($c -eq '/' -and $c1 -eq '*') { $inBlock = $true; $i += 2; continue }
        if ($c -eq '"' -and $c1 -eq '"' -and $c2 -eq '"') { $inMulti = $true; $i += 3; continue }
        if ($c -eq '"') { $inStr = $true; $i++; continue }

        switch ($c) {
            '{' { $b++ }
            '}' { $b-- }
            '(' { $p++ }
            ')' { $p-- }
            '[' { $k++ }
            ']' { $k-- }
        }
        $i++
    }
    $bad = @()
    if ($b -ne 0) { $bad += "花括号差 $b" }
    if ($p -ne 0) { $bad += "圆括号差 $p" }
    if ($k -ne 0) { $bad += "方括号差 $k" }
    if ($bad.Count -gt 0) { return ($bad -join ', ') }
    return $null
}
$unbalanced = @()
foreach ($f in ($coreFiles + $appFiles + $testFiles)) {
    $r = Get-Balance $f.FullName
    if ($r) { $unbalanced += "$($f.Name): $r" }
}
if ($unbalanced.Count -eq 0) {
    Ok "全部 $($coreFiles.Count + $appFiles.Count + $testFiles.Count) 个 Swift 文件的括号平衡"
} else {
    Bad ("括号不平衡: " + ($unbalanced -join '; '))
}

Write-Host '=== 3. target 归属（DayCueCore 不得依赖 iOS 专有框架）===' -ForegroundColor Cyan
$iosOnly = 'UIKit', 'SwiftUI', 'EventKit', 'AVFoundation', 'Vision', 'Speech', 'PhotosUI', 'UserNotifications', 'Security'
$leaks = @()
foreach ($f in $coreFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    foreach ($fw in $iosOnly) {
        if ($text -match "(?m)^\s*import\s+$fw\s*$") { $leaks += "$($f.Name) imports $fw" }
    }
}
if ($leaks.Count -eq 0) {
    Ok "DayCueCore 只依赖 Foundation/CryptoKit/SQLite3，可在 macOS 上 swift test"
} else {
    Bad ("DayCueCore 出现 iOS 专有依赖，macOS 上 swift test 会失败: " + ($leaks -join '; '))
}

Write-Host '=== 4. project.yml 的引用是否存在 ===' -ForegroundColor Cyan
$yml = Get-Content -LiteralPath (Join-Path $ios 'project.yml') -Raw
if ($yml -match 'path:\s*Sources/DayCueApp') {
    if (Test-Path (Join-Path $ios 'Sources\DayCueApp')) { Ok 'target 源码目录存在' } else { Bad 'target 源码目录不存在' }
}
if ($yml -match 'packages:') {
    if ($yml -match 'path:\s*\.') {
        if (Test-Path (Join-Path $ios 'Package.swift')) { Ok '本地 SPM 包引用指向存在 Package.swift 的目录' }
        else { Bad 'packages 指向的目录没有 Package.swift' }
    }
}
foreach ($key in @('NSRemindersFullAccessUsageDescription','NSMicrophoneUsageDescription','NSSpeechRecognitionUsageDescription','NSCameraUsageDescription')) {
    if ($yml -match $key) { Ok "权限文案 $key 已声明" } else { Bad "缺少权限文案 $key" }
}

Write-Host '=== 5. Package.swift 与测试目录一致 ===' -ForegroundColor Cyan
$pkg = Get-Content -LiteralPath (Join-Path $ios 'Package.swift') -Raw
foreach ($d in @('Sources/DayCueCore', 'Tests/DayCueCoreTests')) {
    if ($pkg -match [regex]::Escape($d)) { Ok "Package.swift 引用了 $d" } else { Bad "Package.swift 未引用 $d" }
}
if ($testFiles.Count -gt 0) {
    $missingImport = @()
    foreach ($f in $testFiles) {
        $t = Get-Content -LiteralPath $f.FullName -Raw
        if ($t -notmatch '(?m)^\s*import\s+XCTest') { $missingImport += $f.Name }
    }
    if ($missingImport.Count -eq 0) { Ok '所有测试文件都 import XCTest' } else { Bad ("缺 XCTest: " + ($missingImport -join ', ')) }
}

Write-Host '=== 6. 本机无法执行的检查（如实列出）===' -ForegroundColor Cyan
Skip 'swift build / swift test —— 本机没有 Swift 工具链'
Skip 'xcodegen generate —— 本机没有 XcodeGen'
Skip 'xcodebuild build —— 本机没有 Xcode'
Skip '模拟器 / 真机行为 —— 需要设备'
if (Get-Command xcodebuild -ErrorAction SilentlyContinue) { Ok '检测到 xcodebuild，可改用 scripts/ios/verify-ios.sh' }

Write-Host ''
Write-Host "静态检查：通过 $pass，失败 $fail，未验证 $skip" -ForegroundColor ($(if ($fail -eq 0) { 'Green' } else { 'Red' }))
Write-Host '提醒：静态检查通过 ≠ 可以编译。编译结果只能在 macOS 上得到。' -ForegroundColor Yellow
if ($fail -gt 0) { exit 1 }
exit 0
