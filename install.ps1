# free-rice installer (Windows only, no admin required)
[CmdletBinding()]
param(
    [string]$SubscriptionUrl = '',
    [string]$ClashConfig = '',
    [string]$DataDir = '',
    [switch]$DryRun,
    [switch]$NoStart,
    [switch]$SkipTray,
    [string]$GatewayPath = '',
    [string]$MihomoPath = '',
    [int]$MinContextTokens = 200000,
    [string[]]$AllowModel = @('opencode-zen-free/deepseek-v4.1-flash-free'),
    [switch]$Probe,
    [switch]$NoAutostart,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ($env:FREE_RICE_DRYRUN -eq '1') { $DryRun = $true }
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) { $scriptPath = Join-Path (Get-Location) 'install.ps1' }
$RepoRoot = Split-Path -Parent $scriptPath
if (-not $DataDir) { if ($env:ZEN_IP_HOME) { $DataDir = $env:ZEN_IP_HOME } else { $DataDir = Join-Path $env:USERPROFILE '.zen-ip' } }
$env:ZEN_IP_HOME = $DataDir
$Bin = Join-Path $DataDir 'bin'
$Log = Join-Path $DataDir 'install.log'

function Say([string]$Text) { Write-Host $Text }
function Fail([string]$Text) { Write-Host ('错误: ' + $Text) -ForegroundColor Red; exit 1 }
function Note([string]$Text) { try { Add-Content -LiteralPath $Log -Value ('[' + (Get-Date -Format s) + '] ' + $Text) } catch {} }

function Test-Port([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Download([string]$Url, [string]$Destination) {
    Say ('下载 ' + $Url)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Destination + '.part'
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

function Get-LatestAsset([string]$Repo, [string]$Pattern) {
    $api = 'https://api.github.com/repos/' + $Repo + '/releases/latest'
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'free-rice' } -UseBasicParsing
    return $release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
}

function Ensure-Node {
    $node = Join-Path $Bin 'node.exe'
    if (Test-Path -LiteralPath $node) { return $node }
    Download 'https://nodejs.org/dist/latest/win-x64/node.exe' $node
    return $node
}

function Ensure-Mihomo {
    $mihomo = Join-Path $Bin 'mihomo.exe'
    if ($MihomoPath) {
        if (-not (Test-Path -LiteralPath $MihomoPath)) { Fail ('MihomoPath 不存在: ' + $MihomoPath) }
        Copy-Item -LiteralPath $MihomoPath -Destination $mihomo -Force
        return $mihomo
    }
    if (Test-Path -LiteralPath $mihomo) { return $mihomo }
    $asset = Get-LatestAsset 'MetaCubeX/mihomo' '*windows-amd64*.zip'
    if (-not $asset) { Fail '没有找到 mihomo windows-amd64 发布包' }
    $zip = Join-Path $env:TEMP ('mihomo-' + [guid]::NewGuid().ToString('N') + '.zip')
    Download $asset.browser_download_url $zip
    $dir = Join-Path $env:TEMP ('mihomo-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    $exe = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'mihomo.exe' | Select-Object -First 1
    if (-not $exe) { Fail 'mihomo 压缩包里没有 mihomo.exe' }
    Copy-Item -LiteralPath $exe.FullName -Destination $mihomo -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $mihomo
}

function Ensure-Magpie {
    $magpie = Join-Path $Bin 'magpie.exe'
    if ($GatewayPath) {
        if (-not (Test-Path -LiteralPath $GatewayPath)) { Fail ('GatewayPath 不存在: ' + $GatewayPath) }
        Copy-Item -LiteralPath $GatewayPath -Destination $magpie -Force
        return $magpie
    }
    if (Test-Path -LiteralPath $magpie) { return $magpie }
    $legacy = Join-Path $env:USERPROFILE '.bin\magpie.exe'
    if (Test-Path -LiteralPath $legacy) { Copy-Item -LiteralPath $legacy -Destination $magpie -Force; return $magpie }
    $asset = Get-LatestAsset 'yetone/magpie-releases' 'magpie-windows-amd64.exe'
    if (-not $asset) { Fail '没有找到 magpie windows 发布包' }
    $sums = Get-LatestAsset 'yetone/magpie-releases' 'SHA256SUMS'
    Download $asset.browser_download_url $magpie
    if ($sums) {
        $sumsPath = Join-Path $env:TEMP ('SHA256SUMS-' + [guid]::NewGuid().ToString('N'))
        Download $sums.browser_download_url $sumsPath
        $line = Select-String -LiteralPath $sumsPath -Pattern 'magpie-windows-amd64.exe' | Select-Object -First 1
        if ($line) {
            $want = ($line.Line -split '\s+')[0]
            $got = (Get-FileHash -LiteralPath $magpie -Algorithm SHA256).Hash.ToLower()
            if ($got -ne $want.ToLower()) { Fail 'magpie 校验失败' }
        }
        Remove-Item -LiteralPath $sumsPath -Force -ErrorAction SilentlyContinue
    }
    return $magpie
}

function Ensure-Pwsh {
    if ($SkipTray) { return '' }
    $local = Join-Path $Bin 'pwsh\pwsh.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $nested = Join-Path $Bin 'pwsh\bin\pwsh.exe'
    if (Test-Path -LiteralPath $nested) { return $nested }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $dsh = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules\@dsh-ops\pwsh-win32-x64\bin\pwsh.exe'
    if (Test-Path -LiteralPath $dsh) { return $dsh }
    try {
        $asset = Get-LatestAsset 'PowerShell/PowerShell' 'PowerShell-*-win-x64.zip'
        if ($asset) {
            $zip = Join-Path $env:TEMP ('pwsh-' + [guid]::NewGuid().ToString('N') + '.zip')
            Download $asset.browser_download_url $zip
            $target = Join-Path $Bin 'pwsh'
            Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            $exe = Join-Path $target 'pwsh.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    } catch { Note ('PowerShell 7 下载失败: ' + $_.Exception.Message) }
    Say '没有找到 PowerShell 7，托盘默认跳过；装好 PowerShell 7 后可用 rice tray 再试。'
    return ''
}

function Write-Config {
    $configPath = Join-Path $DataDir 'config.json'
    $config = @{}
    if (Test-Path -LiteralPath $configPath) {
        try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch {}
    }
    if ($SubscriptionUrl) { $config | Add-Member -NotePropertyName subscription -NotePropertyValue $SubscriptionUrl -Force }
    if ($ClashConfig) { $config | Add-Member -NotePropertyName clashConfig -NotePropertyValue $ClashConfig -Force }
    $config | Add-Member -NotePropertyName gatewayPort -NotePropertyValue 3425 -Force
    $config | Add-Member -NotePropertyName routerPort -NotePropertyValue 7999 -Force
    $config | Add-Member -NotePropertyName defaultModel -NotePropertyValue 'opencode-zen-free/minimax-m3.1-flash-free' -Force
    $models = [pscustomobject]@{ minContextTokens = $MinContextTokens; allow = @($AllowModel); deny = @() }
    $config | Add-Member -NotePropertyName models -NotePropertyValue $models -Force
    $config | Add-Member -NotePropertyName notifications -NotePropertyValue 'off' -Force
    $config | Add-Member -NotePropertyName refreshHours -NotePropertyValue 0 -Force
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    return $configPath
}

function Write-Launchers([string]$Node, [string]$Pwsh) {
    $nl = [Environment]::NewLine
    $start = Join-Path $DataDir 'zen-start.vbs'
    $startBody = 'Set sh = CreateObject("WScript.Shell")' + $nl + 'sh.Run """' + $Node + '"" ""' + (Join-Path $DataDir 'zen-supervisor.mjs') + '""", 0, False' + $nl
    Set-Content -LiteralPath $start -Value $startBody -Encoding ASCII
    $tray = Join-Path $DataDir 'zen-tray.vbs'
    if ($Pwsh) {
        $trayBody = 'Set sh = CreateObject("WScript.Shell")' + $nl + 'sh.Run """' + $Pwsh + '"" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' + (Join-Path $DataDir 'zen-tray.ps1') + '""", 0, False' + $nl
        Set-Content -LiteralPath $tray -Value $trayBody -Encoding ASCII
    }
    if ($NoAutostart) { return }
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $written = $false
    try {
        if (Test-Path -LiteralPath $startup) {
            Copy-Item -LiteralPath $start -Destination (Join-Path $startup 'free-rice-start.vbs') -Force
            if (Test-Path -LiteralPath $tray) { Copy-Item -LiteralPath $tray -Destination (Join-Path $startup 'free-rice-tray.vbs') -Force }
            $written = Test-Path -LiteralPath (Join-Path $startup 'free-rice-start.vbs')
        }
    } catch { $written = $false }
    if ($written) { Say '登录自启: Startup 文件夹'; return }
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'free-rice' -Value ('"' + $wscript + '" "' + $start + '"') -PropertyType String -Force | Out-Null
        if (Test-Path -LiteralPath $tray) {
            New-ItemProperty -Path $key -Name 'free-rice-tray' -Value ('"' + $wscript + '" "' + $tray + '"') -PropertyType String -Force | Out-Null
        }
        Say '登录自启: HKCU Run 注册表（Startup 目录不可写时的兜底）'
    } catch {
        Say '登录自启写入失败，登录后手动运行 rice start 即可。'
    }
}


function Write-Shortcuts {
    $menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\free-rice'
    New-Item -ItemType Directory -Path $menu -Force | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    foreach ($pair in @(@('free-rice start.lnk', 'zen-start.vbs'), @('free-rice tray.lnk', 'zen-tray.vbs'))) {
        $target = Join-Path $DataDir $pair[1]
        if (Test-Path -LiteralPath $target) {
            $lnk = $sh.CreateShortcut((Join-Path $menu $pair[0]))
            $lnk.TargetPath = $wscript
            $lnk.Arguments = '"' + $target + '"'
            $lnk.WorkingDirectory = $DataDir
            $lnk.Description = 'free-rice'
            $lnk.Save()
        }
    }
}

function Start-Supervisor {
    $start = Join-Path $DataDir 'zen-start.vbs'
    if (-not (Test-Path -LiteralPath $start)) { return $false }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $start
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Port 7900) -and (Test-Port 7999)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Stop-LocalStack {
    $h = [regex]::Escape($DataDir)
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and (
            ($_.Name -eq 'node.exe' -and $_.CommandLine -match ($h + '.*(zen-supervisor|zen-router)\.mjs')) -or
            ($_.Name -eq 'mihomo.exe' -and $_.CommandLine -like ('*' + $DataDir + '*'))
        )
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Stack {
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Join-Path $DataDir 'zen-start.vbs')
    $tray = Join-Path $DataDir 'zen-tray.vbs'
    if (Test-Path -LiteralPath $tray) { Start-Process -FilePath 'explorer.exe' -ArgumentList $tray }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Port 3425) -and (Test-Port 7999) -and (Test-Port 7900)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Sync-Models([string]$Node) {
    $script = Join-Path $DataDir 'models-sync.mjs'
    if (Test-Path -LiteralPath $script) {
        & $Node $script
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep -Seconds 3
            & $Node $script
        }
        if ($LASTEXITCODE -ne 0) { Say '模型过滤同步失败，稍后可运行 rice refresh 重试。' }
    }
}

$RemoteArchive = 'https://github.com/BICHENG/free-rice/archive/refs/heads/main.zip'
$ExtractedRoot = ''
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'src\zen-router.mjs'))) {
    if ($DryRun) {
        Say '当前目录没有源码，正式安装时会从 GitHub 下载 free-rice 压缩包。'
    } else {
        Say '从 GitHub 下载 free-rice 源码...'
        $stamp = [guid]::NewGuid().ToString('N')
        $zip = Join-Path $env:TEMP ('free-rice-' + $stamp + '.zip')
        $ExtractedRoot = Join-Path $env:TEMP ('free-rice-' + $stamp)
        Invoke-WebRequest -Uri $RemoteArchive -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $ExtractedRoot -Force
        $candidate = Get-ChildItem -LiteralPath $ExtractedRoot -Directory -Filter 'free-rice-*' | Select-Object -First 1
        if ($candidate) { $RepoRoot = $candidate.FullName }
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'src\zen-router.mjs'))) { Fail '下载的压缩包里没有源码' }
    }
}

if ($DryRun) {
    Say '=== free-rice 安装计划 ==='
    Say ('数据目录: ' + $DataDir)
    if ($SubscriptionUrl) { Say ('订阅: ' + $SubscriptionUrl) } elseif ($ClashConfig) { Say ('本地配置: ' + $ClashConfig) } else { Say '订阅: 未提供（稍后写入 config.json）' }
    Say ('模型过滤: context > ' + $MinContextTokens + '，白名单: ' + ($AllowModel -join ', '))
    Say '步骤: 依赖 -> config.json -> 复制脚本 -> 插件 -> mihomo 配置 -> 启动 -> 过滤 -> 启动项'
    Say '免管理员、不改系统代理/PATH/服务，自启只写 Startup 文件夹。'
    exit 0
}

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
New-Item -ItemType Directory -Path $Bin -Force | Out-Null
Note 'install start'

if (-not $SubscriptionUrl -and -not $ClashConfig) {
    if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'config.json'))) {
        $source = $env:FREE_RICE_SOURCE
        if (-not $source -and [Environment]::UserInteractive) {
            $source = Read-Host 'Clash 订阅地址或本地 YAML 路径'
        }
        if (-not $source) { Fail '需要订阅地址：用 -SubscriptionUrl，或设置 FREE_RICE_SOURCE' }
        if ($source -match '^https?://') { $SubscriptionUrl = $source } else { $ClashConfig = $source }
    }
}

Say '准备运行依赖...'
$node = Ensure-Node
$mihomo = Ensure-Mihomo
$magpie = Ensure-Magpie
$pwsh = Ensure-Pwsh

Say '写入配置...'
$configPath = Write-Config

Say '复制脚本...'
Copy-Item -Path (Join-Path $RepoRoot 'src\*.mjs') -Destination $DataDir -Force
Copy-Item -Path (Join-Path $RepoRoot 'tray\*.ps1') -Destination $DataDir -Force
foreach ($n in 'rice.ps1', 'rice.cmd', 'install.ps1', 'uninstall.ps1') {
    $p = Join-Path $RepoRoot $n
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $DataDir -Force }
}
$iconSrc = Join-Path $RepoRoot 'assets\icon.ico'
if (Test-Path -LiteralPath $iconSrc) { Copy-Item -LiteralPath $iconSrc -Destination (Join-Path $DataDir 'icon.ico') -Force }
if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'zen-router.mjs'))) { Fail '复制脚本失败' }

Say '安装 OpenCode Zen Free 插件...'
$env:PATH = $Bin + ';' + $env:PATH
& $magpie plugin add '@magpie-community/opencode-zen-free-auth' | Out-Null
'public' | & $magpie plugin login opencode-zen-free | Out-Null
& $magpie plugin options opencode-zen-free-auth '{"baseURL":"http://127.0.0.1:7999"}' | Out-Null

Say '生成 mihomo 配置...'
$buildArgs = @((Join-Path $DataDir 'build-config.mjs'))
if ($SubscriptionUrl) { $buildArgs += @('--sub', $SubscriptionUrl) } elseif ($ClashConfig) { $buildArgs += @('--file', $ClashConfig) }
& $node @buildArgs
if ($LASTEXITCODE -ne 0) { Fail '生成 mihomo 配置失败' }

Say '启动网关...'
if (-not (Test-Port 3425)) { Start-Process -FilePath $magpie -ArgumentList 'tray' -WindowStyle Hidden }
$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-Port 3425) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
if (-not (Test-Port 3425)) { Say '网关没有在 30 秒内起来，稍后运行 rice doctor。' }

if ($Probe) {
    Say '测速与验证（先拉起 mihomo 和转发器，可能需要几分钟）...'
    if (Start-Supervisor) {
        & $node (Join-Path $DataDir 'measure.mjs')
        & $node (Join-Path $DataDir 'validate.mjs')
        & $node (Join-Path $DataDir 'probe-models.mjs')
        if ($NoStart) { Say '探测结束，停止本地服务...'; Stop-LocalStack }
    } else {
        Say '本地服务没有起来，跳过测速。'
    }
}

Sync-Models $node

Say '写启动项...'
Write-Launchers $node $pwsh
Write-Shortcuts

if (-not $NoStart) {
    Say '启动守护与托盘...'
    $ok = Start-Stack
    if ($ok) { Say '服务已就绪。' } else { Say '服务未完全就绪，运行 rice status 检查。' }
}

Say ''
Say '=== 安装完成 ==='
Say ('数据目录: ' + $DataDir)
Say '网关:     http://127.0.0.1:3425/v1   key: magpie'
Say '转发器:   http://127.0.0.1:7999/status'
Say '模型: rice models    状态: rice status    体检: rice doctor'
if ($ExtractedRoot -and (Test-Path -LiteralPath $ExtractedRoot)) { Remove-Item -LiteralPath $ExtractedRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
