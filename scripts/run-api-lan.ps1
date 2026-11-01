# 局域网联调：把后端暴露给同一网络里的手机
#
# 编码必须是 UTF-8 **带 BOM**。
# Windows PowerShell 5.1 读无 BOM 的 .ps1 会按 GBK 解码，中文注释里的字节
# 会把后面的引号吃掉，报「字符串缺少终止符」——而且 pwsh 7 解析同一文件是正常的，
# 所以只看 pwsh 的语法检查发现不了。
#
# 与 run-api.ps1 的每一条差异都对应一个真会卡住的现象：
#   1. 监听 0.0.0.0 而不是 127.0.0.1 —— 否则手机连不上，表现为连接超时。
#   2. 必须带 -tags postgres —— 不带的话 cloudsync.go 的桩会返回 nil handler，
#      /v1/auth/* 与 /v1/sync/* 根本不存在，手机连令牌都拿不到（直接 404）。
#   3. 必须设 DAYCUE_AUTH_TOKEN —— config 对非环回监听强制要求它，缺了拒绝启动。
#   4. 密钥持久化到 scripts/.lan-secrets.json —— 每次重启换密钥会让手机里已保存的
#      令牌全部失效，表现为「昨天还好好的，今天一直 401」，很难联想到是重启导致的。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-api-lan.ps1

param(
    [int]$Port = 8787,
    [string]$DatabaseUrl = 'postgres://daycue:daycue@127.0.0.1:55432/daycue_test?sslmode=disable',

    # AI 供应商。传一次就会被记住（存在 .lan-secrets.json，该文件已 gitignore），
    # 之后不需要每次重启都重新粘贴 key。
    [string]$LlmBaseUrl = '',
    [string]$LlmApiKey = '',
    [string]$LlmModel = '',

    # 有些 OpenAI-compatible 中转站会丢弃 system 消息：模型只看到原文、看不到格式要求，
    # 于是自己造字段名、自己算日期，表现为「明明有内容却返回 0 条」。
    # 这类端点必须打开这个开关。
    [switch]$LlmMergeSystemPrompt,

    # 模拟模式：不调真模型，返回固定样例，用来在没有 key 时验通整条链路。
    [switch]$Fixture
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$secretFile = Join-Path $PSScriptRoot '.lan-secrets.json'

function New-Secret([int]$bytes) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object 'byte[]' $bytes
    $rng.GetBytes($buf)
    return [Convert]::ToBase64String($buf)
}

if (Test-Path $secretFile) {
    $saved = Get-Content $secretFile -Raw | ConvertFrom-Json
} else {
    $saved = [pscustomobject]@{ auth_token = (New-Secret 32); token_secret = (New-Secret 32) }
    $saved | ConvertTo-Json | Set-Content -Path $secretFile -Encoding utf8
    Write-Host "已生成并保存联调密钥：$secretFile（该文件不入库）" -ForegroundColor Cyan
}

# 环境里显式设过就尊重它，否则用持久化的那份。
if (-not $env:DAYCUE_AUTH_TOKEN)   { $env:DAYCUE_AUTH_TOKEN   = $saved.auth_token }
if (-not $env:DAYCUE_TOKEN_SECRET) { $env:DAYCUE_TOKEN_SECRET = $saved.token_secret }
# 传了 AI 参数就写回密钥文件，避免每次重启都要重新粘贴 key。
# 密钥只存在这个已 gitignore 的文件里，绝不写进仓库跟踪的任何脚本或文档。
$dirty = $false
if ($LlmBaseUrl) { $saved | Add-Member -NotePropertyName llm_base_url -NotePropertyValue $LlmBaseUrl -Force; $dirty = $true }
if ($LlmApiKey)  { $saved | Add-Member -NotePropertyName llm_api_key  -NotePropertyValue $LlmApiKey  -Force; $dirty = $true }
if ($LlmModel)   { $saved | Add-Member -NotePropertyName llm_model    -NotePropertyValue $LlmModel   -Force; $dirty = $true }
if ($LlmMergeSystemPrompt) { $saved | Add-Member -NotePropertyName llm_merge_system_prompt -NotePropertyValue $true -Force; $dirty = $true }
if ($dirty) { $saved | ConvertTo-Json | Set-Content -Path $secretFile -Encoding utf8 }

# 环境里显式设过的优先，其次用持久化的那份。
if (-not $env:DAYCUE_LLM_BASE_URL -and $saved.llm_base_url) { $env:DAYCUE_LLM_BASE_URL = $saved.llm_base_url }
if (-not $env:DAYCUE_LLM_API_KEY  -and $saved.llm_api_key)  { $env:DAYCUE_LLM_API_KEY  = $saved.llm_api_key }
if (-not $env:DAYCUE_LLM_MODEL    -and $saved.llm_model)    { $env:DAYCUE_LLM_MODEL    = $saved.llm_model }
if (-not $env:DAYCUE_LLM_MERGE_SYSTEM_PROMPT -and $saved.llm_merge_system_prompt) {
    $env:DAYCUE_LLM_MERGE_SYSTEM_PROMPT = 'true'
}
if ($Fixture) { $env:DAYCUE_FIXTURE_MODE = '1' }

$env:DAYCUE_ADDR = "0.0.0.0:$Port"
if (-not $env:DAYCUE_DATABASE_URL) { $env:DAYCUE_DATABASE_URL = $DatabaseUrl }
$env:GOTOOLCHAIN = 'local'

Write-Host ""
Write-Host "监听 $env:DAYCUE_ADDR（带 -tags postgres，账号与同步端点已启用）" -ForegroundColor Cyan

# 启动前把关键配置状态打出来：AI 到底连没连上、是不是模拟模式，
# 否则排查「解析为什么失败」时得先猜后端是不是真的配好了。
if ($env:DAYCUE_FIXTURE_MODE -eq '1') {
    Write-Host "AI 解析：模拟模式（返回固定样例，不调真模型）" -ForegroundColor Yellow
} elseif ($env:DAYCUE_LLM_BASE_URL -and $env:DAYCUE_LLM_MODEL) {
    $mergeNote = if ($env:DAYCUE_LLM_MERGE_SYSTEM_PROMPT -eq 'true') { "，已合并 system 提示词" } else { "" }
    Write-Host "AI 解析：$($env:DAYCUE_LLM_BASE_URL) / $($env:DAYCUE_LLM_MODEL)$mergeNote" -ForegroundColor Green
} else {
    Write-Host "AI 解析：未配置（/v1/extractions 会返回 503）" -ForegroundColor Yellow
}

$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress
Write-Host ""
Write-Host "手机端「后端地址」按连接方式二选一：" -ForegroundColor Yellow
foreach ($ip in $ips) { Write-Host "  局域网： http://${ip}:$Port" }
Write-Host "  USB adb reverse（最省事，不用动防火墙）： http://127.0.0.1:$Port"
Write-Host "    用 USB 时先在电脑执行： adb reverse tcp:$Port tcp:$Port"
Write-Host ""
Write-Host "要直连局域网，Windows 防火墙需放行入站端口（管理员执行一次）："
Write-Host "  New-NetFirewallRule -DisplayName `"DayCue dev $Port`" -Direction Inbound -LocalPort $Port -Protocol TCP -Action Allow"
Write-Host ""
Write-Host "签发用户令牌（手机设置页的 Bearer Token 填它）：" -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/issue-token.ps1 -Register"
Write-Host ""

Push-Location (Join-Path $root 'services\api')
try { go run -tags postgres ./cmd/daycued } finally { Pop-Location }
