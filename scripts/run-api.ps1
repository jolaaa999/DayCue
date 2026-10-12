# 本地开发：启动 DayCue 后端
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-api.ps1 -Fixture
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-api.ps1
#
# 接真实模型时先设置（只放环境变量，不要写进仓库）：
#   $env:DAYCUE_LLM_BASE_URL = 'https://api.openai.com/v1'
#   $env:DAYCUE_LLM_API_KEY  = '<你的 key>'
#   $env:DAYCUE_FIXTURE_MODE = '0'

param(
    [string]$Addr = '127.0.0.1:8787',
    [switch]$Fixture
)

$ErrorActionPreference = 'Stop'
$api = Join-Path (Split-Path -Parent $PSScriptRoot) 'services\api'

if ($Fixture) { $env:DAYCUE_FIXTURE_MODE = '1' }
if (-not $env:DAYCUE_ADDR) { $env:DAYCUE_ADDR = $Addr }

if ($env:DAYCUE_FIXTURE_MODE -eq '1') {
    Write-Host '注意：模拟模式开启，整理结果全部是预设样例（响应 mode=fixture）。' -ForegroundColor Yellow
}
Write-Host "监听 $env:DAYCUE_ADDR" -ForegroundColor Cyan

Push-Location $api
try { go run ./cmd/daycued } finally { Pop-Location }
