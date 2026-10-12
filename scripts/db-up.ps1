<#
.SYNOPSIS
    为 DayCue 后端启动一个可丢弃的 PostgreSQL，用于跑 postgres 构建标签下的集成测试。

.DESCRIPTION
    两条路径，按可用性自动选择：
      1) Docker：起一个命名容器（默认 daycue-postgres），端口映射到本机。
      2) 本地 PostgreSQL：用 initdb 在用户目录下建一个独立集群，再用 pg_ctl 启动。
    两者都没有时如实失败，并在错误里写清缺什么。

    脚本只负责把数据库启起来并验证它真的能连，不替测试做任何事：
    迁移与清理由集成测试自己负责。

.PARAMETER Down
    停止并删除容器（Docker 路径）或停止本地集群（本地路径）。

.PARAMETER Force
    容器/集群已存在时先删除再重建，保证拿到一个干净实例。

.EXAMPLE
    pwsh -File scripts/db-up.ps1
    # 按输出设置 DAYCUE_TEST_DATABASE_URL 后运行：
    #   go test -tags postgres ./internal/store/... -count=1

.EXAMPLE
    pwsh -File scripts/db-up.ps1 -Down
#>
[CmdletBinding()]
param(
    [string] $ContainerName = 'daycue-postgres',
    [int]    $Port = 55432,
    [string] $Database = 'daycue_test',
    [string] $User = 'daycue',
    [string] $Password = 'daycue',
    [string] $Image = 'postgres:16-alpine',
    [int]    $TimeoutSeconds = 120,
    [switch] $Down,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 本地集群放在用户目录而不是仓库里：仓库里出现一个几百兆的 pgdata
# 会污染 git status，也容易被误提交。
$LocalDataDir = Join-Path $env:LOCALAPPDATA 'DayCue\pgdata'

function Write-Step([string] $Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string] $Message) {
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Warn2([string] $Message) {
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Get-ConnectionString {
    # 用户名与端口都用 $() 子表达式包住。
    # 不能写 $User: —— PowerShell 把 "变量名 + 冒号" 当成「驱动器限定变量引用」
    # （本机确实存在 User: 驱动器），会在解析阶段直接报 InvalidVariableReferenceWithDrive。
    # 顺带也不写反引号转义：反引号在 PowerShell 里是转义符，混在 URL 里极易读错。
    $userPart = $($User)
    $passPart = $($Password)
    $portPart = $($Port)
    $dbPart = $($Database)
    return "postgres://" + $userPart + ":" + $passPart + "@127.0.0.1:" + $portPart + "/" + $dbPart + "?sslmode=disable"
}

function Test-DockerReady {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { return $false }
    # 只有客户端而没有守护进程时 docker info 会失败，必须验证守护进程真的在跑。
    & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-LocalPostgresBin {
    # 先看 PATH，再看常见安装目录；返回同时具备 initdb 与 pg_ctl 的 bin 目录。
    $fromPath = Get-Command 'pg_ctl' -ErrorAction SilentlyContinue
    if ($fromPath) {
        $dir = Split-Path -Parent $fromPath.Source
        if (Test-Path -LiteralPath (Join-Path $dir 'initdb.exe')) { return $dir }
    }
    $roots = @(
        'C:\Program Files\PostgreSQL',
        'D:\PostgreSQL',
        'C:\PostgreSQL',
        (Join-Path $env:LOCALAPPDATA 'Programs\PostgreSQL')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $versions = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($v in $versions) {
            $bin = Join-Path $v.FullName 'bin'
            if ((Test-Path -LiteralPath (Join-Path $bin 'pg_ctl.exe')) -and (Test-Path -LiteralPath (Join-Path $bin 'initdb.exe'))) {
                return $bin
            }
        }
    }
    return $null
}

function Wait-ForPostgresDocker {
    param([string] $Name, [int] $Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        & docker exec $Name 'pg_isready' '-U' $User '-d' $Database 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Wait-ForPostgresLocal {
    param([string] $Bin, [int] $Seconds)
    $pgIsReady = Join-Path $Bin 'pg_isready.exe'
    if (-not (Test-Path -LiteralPath $pgIsReady)) { return $true }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        & $pgIsReady '-h' '127.0.0.1' '-p' $Port '-U' $User 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# ---------------------------------------------------------------- docker 路径

function Get-ExistingContainerName {
    # 刻意不用 docker inspect 判断存在性：容器不存在时它会往 stderr 写字，
    # 而 $ErrorActionPreference = 'Stop' 会把原生命令的 stderr 当成终止性错误，
    # 于是「容器不存在」这个完全正常的分支反而让脚本崩掉（本机实际踩到过）。
    # docker ps -a 在找不到时安静地输出空字符串、退出码仍为 0。
    $found = (& docker ps -a --filter ("name=^/" + $ContainerName + "$") --format '{{.Names}}' 2>$null | Out-String).Trim()
    return $found
}

function Stop-DockerDatabase {
    if (-not (Get-ExistingContainerName)) {
        Write-Warn2 "容器 $ContainerName 不存在，无需停止"
        return
    }
    Write-Step "停止并删除容器 $ContainerName"
    & docker rm -f $ContainerName 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "删除容器 $ContainerName 失败" }
    Write-Ok "容器已删除"
}

function Start-DockerDatabase {
    $exists = [bool](Get-ExistingContainerName)

    if ($exists -and $Force) {
        Write-Step "-Force 指定：先删除已有容器 $ContainerName"
        & docker rm -f $ContainerName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "删除容器 $ContainerName 失败" }
        $exists = $false
    }

    if (-not $exists) {
        Write-Step "创建容器 $ContainerName（镜像 $Image）"
        # 刻意写成一行：用反引号续行会让脚本在任何非 PowerShell 编辑器里都难以维护。
        & docker run -d --name $ContainerName -e "POSTGRES_USER=$User" -e "POSTGRES_PASSWORD=$Password" -e "POSTGRES_DB=$Database" -p "127.0.0.1:$($Port):5432" $Image 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "启动容器失败。常见原因：端口 $Port 已被占用，或镜像 $Image 尚未拉取。请直接运行 docker run 查看完整输出。"
        }
    } else {
        $running = (& docker inspect -f '{{.State.Running}}' $ContainerName 2>$null | Out-String).Trim()
        if ($running -ne 'true') {
            Write-Step "容器已存在但未运行，启动它"
            & docker start $ContainerName 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "启动已有容器 $ContainerName 失败" }
        } else {
            Write-Ok "复用正在运行的容器 $ContainerName"
        }
    }

    Write-Step "等待 PostgreSQL 就绪（最多 $TimeoutSeconds 秒）"
    if (-not (Wait-ForPostgresDocker -Name $ContainerName -Seconds $TimeoutSeconds)) {
        # 就绪超时属于硬失败：不验证就返回会让集成测试连不上，还会让人以为脚本成功了。
        throw "容器 $ContainerName 在 $TimeoutSeconds 秒内没有就绪。请用 docker logs $ContainerName 查看容器日志。"
    }
    Write-Ok "pg_isready 通过：数据库可连接"
}

# ---------------------------------------------------------------- 本地路径

function Stop-LocalDatabase {
    $bin = Get-LocalPostgresBin
    if (-not $bin) {
        Write-Warn2 "未找到本地 PostgreSQL，无需停止"
        return
    }
    if (-not (Test-Path -LiteralPath $LocalDataDir)) {
        Write-Warn2 "本地集群目录不存在：$LocalDataDir"
        return
    }
    Write-Step "停止本地集群 $LocalDataDir"
    & (Join-Path $bin 'pg_ctl.exe') '-D' $LocalDataDir '-m' 'fast' 'stop' 2>$null | Out-Null
    Write-Ok "本地集群已停止"
}

function Start-LocalDatabase {
    param([string] $Bin)

    $initdb = Join-Path $Bin 'initdb.exe'
    $pgCtl = Join-Path $Bin 'pg_ctl.exe'

    if ((Test-Path -LiteralPath $LocalDataDir) -and $Force) {
        Write-Step "-Force 指定：删除已有本地集群 $LocalDataDir"
        Remove-Item -LiteralPath $LocalDataDir -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath (Join-Path $LocalDataDir 'PG_VERSION'))) {
        Write-Step "初始化本地集群 $LocalDataDir"
        # -A trust 只用于本机回环的开发集群，不是生产配置。
        & $initdb '-D' $LocalDataDir '-U' $User '-A' 'trust' '-E' 'UTF8' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "initdb 失败，目录：$LocalDataDir" }
    } else {
        Write-Ok "复用已有本地集群 $LocalDataDir"
    }

    Write-Step "启动本地集群（端口 $Port）"
    & $pgCtl '-D' $LocalDataDir '-o' "-p $Port -h 127.0.0.1" '-l' (Join-Path $LocalDataDir 'server.log') 'start' 2>$null | Out-Null
    # 已经在运行时 pg_ctl 会返回非零，这里继续走就绪检查即可，不当作失败。

    if (-not (Wait-ForPostgresLocal -Bin $Bin -Seconds $TimeoutSeconds)) {
        throw "本地集群在 $TimeoutSeconds 秒内没有就绪。日志：$(Join-Path $LocalDataDir 'server.log')"
    }

    # 数据库不存在时建库；已存在时 createdb 会失败，这里按存在即可处理。
    $createdb = Join-Path $Bin 'createdb.exe'
    if (Test-Path -LiteralPath $createdb) {
        & $createdb '-h' '127.0.0.1' '-p' $Port '-U' $User $Database 2>$null | Out-Null
    }
    Write-Ok "本地集群可连接"
}

# ---------------------------------------------------------------- 主流程

$dockerReady = Test-DockerReady
$localBin = Get-LocalPostgresBin

if (-not $dockerReady -and -not $localBin) {
    # 如实失败：不降级、不假装成功。缺什么就写什么。
    Write-Host ''
    Write-Host '无法启动 PostgreSQL：本机既没有可用的 Docker，也没有本地 PostgreSQL。' -ForegroundColor Red
    Write-Host ''
    Write-Host '缺少的东西：'
    Write-Host '  * Docker：未找到 docker 命令，或 Docker 守护进程没有运行（docker info 失败）。'
    Write-Host '  * 本地 PostgreSQL：PATH 与常见安装目录里都没有同时具备 initdb 与 pg_ctl 的 bin 目录。'
    Write-Host ''
    Write-Host '请任选其一：'
    Write-Host '  1) 启动 Docker Desktop，然后重新运行本脚本；'
    Write-Host '  2) 安装 PostgreSQL（含命令行工具），然后重新运行本脚本；'
    Write-Host '  3) 自己准备一个可丢弃的数据库，并设置环境变量 DAYCUE_TEST_DATABASE_URL。'
    Write-Host ''
    Write-Host '注意：集成测试在缺少 DAYCUE_TEST_DATABASE_URL 时会跳过，'
    Write-Host '      而不是退回内存存储，回退会掩盖持久化缺陷。'
    exit 1
}

if ($Down) {
    if ($dockerReady) { Stop-DockerDatabase } else { Stop-LocalDatabase }
    exit 0
}

if ($dockerReady) {
    Write-Ok '使用 Docker 路径'
    Start-DockerDatabase
} else {
    Write-Ok "使用本地 PostgreSQL 路径：$localBin"
    Start-LocalDatabase -Bin $localBin
}

$connection = Get-ConnectionString
$hint = '  $env:DAYCUE_TEST_DATABASE_URL=' + [char]39 + $connection + [char]39
Write-Host ''
Write-Ok '数据库已就绪，并经过 pg_isready 验证（不是看起来起来了）'
Write-Host ''
Write-Host '把下面这一行粘到当前 PowerShell 会话里：'
Write-Host $hint -ForegroundColor Yellow
Write-Host ''
Write-Host '然后运行集成测试（先设置 GOTMPDIR 与 GOCACHE，避免写满 C 盘）：'
Write-Host '  go test -tags postgres ./internal/store/... -count=1 -v' -ForegroundColor Yellow
Write-Host ''
Write-Host '停止并删除（本机没有 pwsh，请用 Windows PowerShell）：powershell -File scripts/db-up.ps1 -Down'
