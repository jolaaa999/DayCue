# 编码必须是 UTF-8 带 BOM，否则 Windows PowerShell 5.1 会按 GBK 误读中文注释。
# 为联调签发一个用户令牌：手机 App 设置页的「Bearer Token」要填它。
#
# 为什么需要单独一个脚本：Android 端没有登录界面（设置页只能粘贴令牌），
# 所以第一次联调必须先在电脑上注册或登录拿到令牌，否则 App 全程 401。
#
# /v1/auth/* 走的是用户令牌体系，不校验服务令牌，所以这里不需要 Authorization 头。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/issue-token.ps1 -Register
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/issue-token.ps1

param(
    [string]$BaseUrl = 'http://127.0.0.1:8787',
    [string]$Email = 'test@daycue.local',
    [string]$Password = 'daycue-test-2026',
    [string]$DisplayName = '联调测试',
    [switch]$Register
)

$ErrorActionPreference = 'Stop'
$path = if ($Register) { '/v1/auth/register' } else { '/v1/auth/login' }
$body = @{ email = $Email; password = $Password }
if ($Register) { $body.display_name = $DisplayName }
$json = $body | ConvertTo-Json -Compress

try {
    $resp = Invoke-RestMethod -Uri ($BaseUrl + $path) -Method Post -ContentType "application/json; charset=utf-8" -Body $json -TimeoutSec 20
} catch {
    Write-Host "请求失败：$BaseUrl$path" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    Write-Host "常见原因："
    Write-Host "  - 后端没带 -tags postgres：/v1/auth 不存在，返回 404"
    Write-Host "  - 邮箱已注册：去掉 -Register 走登录"
    Write-Host "  - 口令不足 8 个字符"
    exit 1
}

Write-Host ""
Write-Host "把它填进手机 App 的「Bearer Token」：" -ForegroundColor Cyan
Write-Host $resp.token
Write-Host ""
Write-Host "user_id = $($resp.user_id)    过期时间 = $($resp.expires_at)"
