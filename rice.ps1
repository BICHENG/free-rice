# free-rice CLI (Windows)
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($env:ZEN_IP_HOME) { $DataDir = $env:ZEN_IP_HOME } else { $DataDir = Join-Path $env:USERPROFILE '.zen-ip' }
$ConfigPath = Join-Path $DataDir 'config.json'
$Base = 'http://127.0.0.1:7999'
$Gateway = 'http://127.0.0.1:3425'

function Load-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try { return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{}
}

function Test-Port([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(600)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-Status { Invoke-RestMethod -Uri "$Base/status" -NoProxy -TimeoutSec 8 }
function Get-Models { Invoke-RestMethod -Uri "$Gateway/v1/models" -Headers @{ Authorization = 'Bearer magpie' } -NoProxy -TimeoutSec 10 }
function Post-Api([string]$Path) { Invoke-RestMethod -Uri "$Base$Path" -Method Post -NoProxy -TimeoutSec 20 }

function Start-Tray {
    $tray = Join-Path $DataDir 'zen-tray.vbs'
    if (-not (Test-Path -LiteralPath $tray)) { Write-Host '托盘未安装，先运行 install.ps1 -SkipTray:$false'; return }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $tray
}

function Start-Stack {
    $start = Join-Path $DataDir 'zen-start.vbs'
    if (-not (Test-Path -LiteralPath $start)) { Write-Host '缺少 zen-start.vbs，先运行 install.ps1'; return }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $start
    Start-Sleep -Seconds 3
    Start-Tray
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Port 3425) -and (Test-Port 7999) -and (Test-Port 7900)) { Write-Host '服务已启动'; return }
        Start-Sleep -Seconds 2
    }
    Write-Host '服务未完全就绪，运行 rice doctor 检查'
}

function Stop-Stack {
    $h = [regex]::Escape($DataDir)
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and (
            ($_.Name -eq 'node.exe' -and $_.CommandLine -match ($h + '.*(zen-supervisor|zen-router)\.mjs')) -or
            ($_.Name -eq 'mihomo.exe' -and $_.CommandLine -like ('*' + $DataDir + '*')) -or
            ($_.Name -eq 'magpie.exe' -and ($_.CommandLine -like ('*' + $DataDir + '*') -or $_.ExecutablePath -like ($DataDir + '*'))) -or
            ($_.Name -eq 'pwsh.exe' -and $_.CommandLine -like ('*' + $DataDir + '*zen-tray.ps1*'))
        )
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host '已停止'
}

function Show-Status {
    try { $s = Get-Status } catch { Write-Host '转发器离线'; return }
    Write-Host ('可用 IP  ' + $s.totals.usableIpCount + '/' + $s.totals.ipCount + '   请求 ' + $s.totals.requests + '   tokens ' + $s.totals.tokens + '   会话 ' + $s.totals.sessions)
    Write-Host ('当前出口 ' + $s.current.egressIp + '   节点 ' + $s.current.node)
    $ex = @($s.ips | Where-Object { $_.exhausted -or $_.blocked }).Count
    Write-Host ('冷却/拒绝 ' + $ex + ' 个 IP')
    if (Test-Port 3425) {
        try { $m = Get-Models; Write-Host ('网关模型 ' + @($m.data).Count + ' 个') } catch {}
    } else { Write-Host '网关 3425 离线' }
}

function Show-Models {
    $m = Get-Models
    foreach ($x in $m.data) {
        $ctx = $x.max_input_tokens
        if (-not $ctx) { $ctx = $x.context_length }
        Write-Host ($x.id + '  ctx=' + $ctx)
    }
}

function Show-Info {
    $cfg = Load-Config
    $models = @()
    try { $models = @((Get-Models).data | ForEach-Object { $_.id }) } catch {}
    $version = '0.1.0'
    $versionFile = Join-Path $DataDir 'VERSION'
    if (Test-Path -LiteralPath $versionFile) { $version = (Get-Content -LiteralPath $versionFile -Raw).Trim() }
    $info = [pscustomobject]@{
        name = 'free-rice'
        version = $version
        home = $DataDir
        baseUrl = 'http://127.0.0.1:3425/v1'
        anthropicBaseUrl = 'http://127.0.0.1:3425'
        apiKey = 'magpie'
        router = 'http://127.0.0.1:7999'
        ports = [pscustomobject]@{ gateway = 3425; router = 7999; proxy = 7900; probe = 7901; api = 9099 }
        defaultModel = $cfg.defaultModel
        models = $models
        notifications = $cfg.notifications
    }
    $info | ConvertTo-Json -Depth 5
}

function Invoke-Refresh {
    $cfg = Load-Config
    $node = Join-Path $DataDir 'bin\node.exe'
    if (-not (Test-Path -LiteralPath $node)) { $node = 'node' }
    $args = @((Join-Path $DataDir 'build-config.mjs'))
    if ($cfg.subscription) { $args += @('--sub', $cfg.subscription) } elseif ($cfg.clashConfig) { $args += @('--file', $cfg.clashConfig) }
    & $node @args
    if ($LASTEXITCODE -ne 0) { throw 'build-config 失败' }
    Stop-Stack
    Start-Sleep -Seconds 2
    Start-Stack
    $sync = Join-Path $DataDir 'models-sync.mjs'
    if (Test-Path -LiteralPath $sync) { & $node $sync }
}

function Invoke-Doctor {
    Write-Host '== 端口 =='
    foreach ($p in 3425, 7999, 7900, 7901, 9099) {
        $state = if (Test-Port $p) { 'OK' } else { 'MISSING' }
        Write-Host ('  ' + $p + ' ' + $state)
    }
    Write-Host '== 网关 =='
    $magpie = Join-Path $DataDir 'bin\magpie.exe'
    if (Test-Path -LiteralPath $magpie) { & $magpie healthcheck; Write-Host ('  exit=' + $LASTEXITCODE) }
    Write-Host '== 插件 =='
    $plugins = Join-Path $env:USERPROFILE '.config\magpie\plugins.json'
    if (Test-Path -LiteralPath $plugins) {
        $text = Get-Content -LiteralPath $plugins -Raw
        if ($text -match '127\.0\.0\.1:7999') { Write-Host '  baseURL 指向 zen-router OK' } else { Write-Host '  baseURL 丢失，重新执行 magpie plugin options opencode-zen-free-auth' }
    } else { Write-Host '  找不到 plugins.json' }
    Write-Host '== 模型 =='
    try { Write-Host ('  ' + @((Get-Models).data).Count + ' 个') } catch { Write-Host '  模型列表不可用' }
    Write-Host '== 最近日志 =='
    foreach ($f in 'zen-router.log', 'zen-supervisor.log') {
        $p = Join-Path $DataDir $f
        if (Test-Path -LiteralPath $p) { Write-Host ('-- ' + $f); Get-Content -LiteralPath $p -Tail 5 }
    }
}

switch ($Command.ToLower()) {
    'install' { & (Join-Path $RepoRoot 'install.ps1') @Rest }
    'status' { Show-Status }
    'models' {
        if ($Rest -contains '--all') { Show-Models }
        elseif ($Rest.Count -ge 1 -and $Rest[0] -eq 'allow') {
            $cfg = Load-Config
            $allow = @($cfg.models.allow) + $Rest[1]
            $cfg.models.allow = @($allow | Select-Object -Unique)
            $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            $node = Join-Path $DataDir 'bin\node.exe'
            & $node (Join-Path $DataDir 'models-sync.mjs')
        } elseif ($Rest.Count -ge 1 -and $Rest[0] -eq 'deny') {
            $cfg = Load-Config
            $cfg.models.deny = @(@($cfg.models.deny) + $Rest[1] | Select-Object -Unique)
            $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            $node = Join-Path $DataDir 'bin\node.exe'
            & $node (Join-Path $DataDir 'models-sync.mjs')
        } else { Show-Models }
    }
    'info' { Show-Info }
    'start' { Start-Stack }
    'stop' { Stop-Stack }
    'restart' { Stop-Stack; Start-Sleep -Seconds 2; Start-Stack }
    'tray' { Start-Tray }
    'probe' { Post-Api '/probe' | ConvertTo-Json -Compress }
    'rotate' { Post-Api '/rotate' | ConvertTo-Json -Compress }
    'refresh' { Invoke-Refresh }
    'doctor' { Invoke-Doctor }
    'uninstall' { & (Join-Path $RepoRoot 'uninstall.ps1') @Rest }
    default {
        Write-Host 'free-rice 用法:'
        Write-Host '  rice install [-SubscriptionUrl URL] [-ClashConfig file] [-DryRun]'
        Write-Host '  rice status | models [--all | allow <id> | deny <id>] | info'
        Write-Host '  rice start | stop | restart | tray | refresh | doctor | uninstall'
        Write-Host '  rice probe | rotate'
    }
}
