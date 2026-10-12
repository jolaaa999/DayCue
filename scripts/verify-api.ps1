# DayCue 后端验收脚本（Windows PowerShell 5.1 / PowerShell 7 均可）
#
# 依次执行：构建 -> 静态检查 -> 单元测试 -> 启动真实服务 -> 发真实 HTTP 请求 -> 断言 -> 关闭。
# 全程使用模拟模式（DAYCUE_FIXTURE_MODE=1），不需要任何真实 API Key。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-api.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$api  = Join-Path $repo 'services\api'
$addr = '127.0.0.1:8799'
$base = "http://$addr"
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) 'daycue-verify'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$exe  = Join-Path $tmp 'daycued.exe'
$log  = Join-Path $tmp 'daycued.err.log'

$passed = 0
$failed = 0

function Check($name, [bool]$ok, $detail) {
    if ($ok) {
        $script:passed++
        Write-Host "  [通过] $name" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "  [失败] $name -- $detail" -ForegroundColor Red
    }
}

function StatusOf($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return -1 }
}

# 必须把请求体转成 UTF-8 字节：Windows PowerShell 5.1 的 -Body 字符串会按本地代码页编码，
# 中文会在服务端变成乱码，导致断言失败。
function PostJson($url, $json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes
}

Write-Host '=== 1/4 构建与静态检查 ===' -ForegroundColor Cyan
Push-Location $api
try {
    go build ./...
    if ($LASTEXITCODE -ne 0) { throw 'go build 失败' }
    Write-Host '  go build 通过'
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet 失败' }
    Write-Host '  go vet 通过'
} finally { Pop-Location }

Write-Host '=== 2/4 单元测试 ===' -ForegroundColor Cyan
Push-Location $api
try {
    go test ./... -count=1
    if ($LASTEXITCODE -ne 0) { throw 'go test 失败' }
} finally { Pop-Location }

Write-Host '=== 3/4 启动服务（模拟模式） ===' -ForegroundColor Cyan
Push-Location $api
try { go build -o $exe ./cmd/daycued } finally { Pop-Location }

$env:DAYCUE_ADDR = $addr
$env:DAYCUE_ENV = 'test'
$env:DAYCUE_FIXTURE_MODE = '1'
$env:DAYCUE_LLM_BASE_URL = ''
$env:DAYCUE_LLM_API_KEY = ''
Remove-Item $log -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $log -RedirectStandardOutput (Join-Path $tmp 'daycued.out.log')

try {
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $h = Invoke-RestMethod -Uri "$base/v1/health" -TimeoutSec 2
            $ready = $true
            break
        } catch { }
    }
    if (-not $ready) {
        Write-Host "服务未在 10 秒内就绪，stderr：" -ForegroundColor Red
        Get-Content $log -ErrorAction SilentlyContinue | Write-Host
        throw '服务启动失败'
    }

    Write-Host '=== 4/4 端到端验收 ===' -ForegroundColor Cyan

    Check '健康检查 status=ok' ($h.status -eq 'ok') $h.status
    Check '健康检查标记模拟模式' ($h.fixture_mode -eq $true) $h.fixture_mode
    Check '健康检查如实报告 LLM 为模拟供应商' ($h.providers.llm -eq 'fixture') $h.providers.llm
    Check '健康检查如实报告 ASR 为模拟供应商' ($h.providers.asr -eq 'fixture') $h.providers.asr

    $demo = '{"schema_version":"1.0","capture_id":"cap_verify_01","source":{"type":"asr","text":"今天操作系统讲了 PV 操作，我还是没理解，明晚八点提醒我复习，周五之前交实验报告。","language":"zh-Hans"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Asia/Shanghai"}'
    $r = PostJson "$base/v1/extractions" $demo
    Check '拆出 3 条候选（1 笔记 + 2 任务）' ($r.items.Count -eq 3) "实得 $($r.items.Count)"
    Check '第 1 条是笔记' ($r.items[0].kind -eq 'note') $r.items[0].kind
    Check '笔记不带提醒时刻' ($null -eq $r.items[0].remind) 'remind 非空'
    Check '笔记截止类型为 none' ($r.items[0].due.kind -eq 'none') $r.items[0].due.kind
    Check '第 2 条是任务' ($r.items[1].kind -eq 'task') $r.items[1].kind
    Check '明晚八点 -> 2026-10-12 20:00 本地' ($r.items[1].due.local -eq '2026-10-12T20:00:00') $r.items[1].due.local
    Check '明晚八点 -> 2026-10-12T12:00:00Z' ($r.items[1].due.utc -eq '2026-10-12T12:00:00Z') $r.items[1].due.utc
    Check '明晚八点带提醒时刻' ($null -ne $r.items[1].remind) 'remind 为空'
    Check '周五之前 -> 2026-10-16（日期型）' ($r.items[2].due.local -eq '2026-10-16') $r.items[2].due.local
    Check '日期型截止日不带 UTC' ($null -eq $r.items[2].due.utc) $r.items[2].due.utc
    Check '周五之前不编造提醒时刻' ($null -eq $r.items[2].remind) 'remind 非空'
    Check '周五之前标记 deadline_only' ($r.items[2].ambiguities[0].code -eq 'deadline_only') $r.items[2].ambiguities[0].code
    Check '响应标记 mode=fixture' ($r.mode -eq 'fixture') $r.mode

    $bad = '{"schema_version":"1.0","capture_id":"c","source":{"type":"text","text":"明天交作业"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Asia/Shanghai","user_id":"someone-else"}'
    $code = 0
    try { PostJson "$base/v1/extractions" $bad | Out-Null } catch { $code = StatusOf $_ }
    Check '契约外字段 user_id 被拒绝 400' ($code -eq 400) "实得 $code"

    $badTz = '{"schema_version":"1.0","capture_id":"c","source":{"type":"text","text":"明天交作业"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Mars/Olympus"}'
    $code = 0
    try { PostJson "$base/v1/extractions" $badTz | Out-Null } catch { $code = StatusOf $_ }
    Check '非法时区被拒绝 422' ($code -eq 422) "实得 $code"

    $big = '{"schema_version":"1.0","capture_id":"c","source":{"type":"text","text":"' + ('x' * 300000) + '"},"recorded_at":"2026-10-11T11:30:00Z","timezone":"Asia/Shanghai"}'
    $code = 0
    try { PostJson "$base/v1/extractions" $big | Out-Null } catch { $code = StatusOf $_ }
    Check '超大请求被拒绝 413' ($code -eq 413) "实得 $code"

    $code = 0
    try {
        $audio = [System.Text.Encoding]::UTF8.GetBytes('fake-audio')
        Invoke-RestMethod -Uri "$base/v1/transcriptions" -Method Post -ContentType 'audio/mp4' -Body $audio | Out-Null
    } catch { $code = StatusOf $_ }
    Check '模拟模式不编造转写，返回 503' ($code -eq 503) "实得 $code"

    $code = 0
    try { Invoke-RestMethod -Uri "$base/v1/nope" -TimeoutSec 2 | Out-Null } catch { $code = StatusOf $_ }
    Check '未知路径返回 404' ($code -eq 404) "实得 $code"

    $code = 0
    $_badJson = 'this is not json'
    try { PostJson "$base/v1/extractions" $_badJson | Out-Null } catch { $code = StatusOf $_ }
    Check '非法 JSON 被拒绝 400' ($code -eq 400) "实得 $code"
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\DAYCUE_ADDR, Env:\DAYCUE_ENV, Env:\DAYCUE_FIXTURE_MODE -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host "验收结果：通过 $passed 项，失败 $failed 项" -ForegroundColor Green
    exit 0
}
Write-Host "验收结果：通过 $passed 项，失败 $failed 项" -ForegroundColor Red
exit 1
