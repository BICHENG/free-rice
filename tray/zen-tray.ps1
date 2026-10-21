#requires -Version 7.0
# Zen Router 托盘监控：纯 PowerShell 7 + WinForms，无外部依赖。
# 数据源：GET /status、GET /v1/models（Bearer magpie）、usage.jsonl 尾部 1500 行。
param(
    [switch]$SelfTest,
    [switch]$PreviewHover
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseUrl = 'http://127.0.0.1:7999'
$script:MagpieUrl = 'http://127.0.0.1:3425'
$script:DataDir = if ($env:ZEN_IP_HOME) { $env:ZEN_IP_HOME } else { Join-Path $env:USERPROFILE '.zen-ip' }
$script:UsagePath = Join-Path $env:USERPROFILE '.config\magpie\usage.jsonl'
$script:LogPath = Join-Path $script:DataDir 'zen-router.log'
$script:NotifyWindow = [TimeSpan]::FromMinutes(5)
$script:Tray = $null
$script:Menu = $null
$script:Timer = $null
$script:Icons = @{}
$script:CurrentColor = ''
$script:LastState = $null
$script:SeenState = $false
$script:LastNotify = @{}
$script:LastView = $null
$script:Snapshot = $null
$script:TipMax = 127
$script:Busy = $false
$script:ModelCache = @()
$script:ModelCacheAt = [datetime]::MinValue
$script:ModelsError = ''
$script:HoverForm = $null
$script:HoverWatch = $null
$script:HoverAnchor = $null
$script:HoverInsideAt = [datetime]::Now
$script:HoverColors = $null
$script:HoverBrushes = $null
$script:HoverPens = $null
$script:HoverFonts = $null
$script:HoverFormats = $null

function Get-ShortText {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $oneLine = ($Text -replace '\s+', ' ').Trim()
    if ($oneLine.Length -le $Max) { return $oneLine }
    if ($Max -le 1) { return '…' }
    return $oneLine.Substring(0, $Max - 1) + '…'
}

function Format-ZenTime {
    param($Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [datetime]) {
        $time = [datetime]$Value
        if ($time.Kind -eq [System.DateTimeKind]::Utc) { $time = $time.ToLocalTime() }
        return $time.ToString('yyyy-MM-dd HH:mm:ss')
    }
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '-' }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    return $text
}

function Format-Num {
    param([double]$Number)
    if ($Number -ge 1000000) { return ('{0:0.0}M' -f ($Number / 1000000)) }
    if ($Number -ge 1000) { return ('{0:0.0}K' -f ($Number / 1000)) }
    return [string][long]$Number
}

function Get-ZenProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Invoke-ZenApi {
    param(
        [string]$Path,
        [string]$Method = 'Get',
        [int]$TimeoutSec = 5
    )
    $request = @{
        Uri         = "$($script:BaseUrl)$Path"
        Method      = $Method
        TimeoutSec  = $TimeoutSec
        NoProxy     = $true
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'Post') {
        $request.ContentType = 'application/json'
        $request.Body = '{}'
    }
    Invoke-RestMethod @request
}

function Get-ZenStatus {
    Invoke-ZenApi -Path '/status' -Method 'Get' -TimeoutSec 5
}

function Get-MagpieModels {
    param([switch]$Force)
    $now = [datetime]::Now
    if (-not $Force -and ($now - $script:ModelCacheAt).TotalSeconds -lt 60) {
        return @($script:ModelCache)
    }
    try {
        $response = Invoke-RestMethod -Uri "$($script:MagpieUrl)/v1/models" -Headers @{ Authorization = 'Bearer magpie' } -TimeoutSec 5 -NoProxy -ErrorAction Stop
        $script:ModelCache = @($response.data)
        $script:ModelsError = ''
        $script:ModelCacheAt = $now
    } catch {
        $script:ModelsError = $_.Exception.Message
        $script:ModelCacheAt = $now
    }
    return @($script:ModelCache)
}

function Get-MagpieUsage {
    $agg = @{}
    if (-not (Test-Path -LiteralPath $script:UsagePath)) { return $agg }
    $lines = @()
    try {
        $lines = @(Get-Content -LiteralPath $script:UsagePath -Tail 1500 -ErrorAction Stop)
    } catch {
        return $agg
    }
    $now = [datetimeoffset]::Now
    $cutoff = $now.AddMinutes(-60)
    $limit = $now.AddMinutes(5)
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try {
            $obj = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            continue
        }
        $req = [string](Get-ZenProperty $obj 'req' '')
        if ([string]::IsNullOrWhiteSpace($req)) { continue }
        $time = [datetimeoffset]::MinValue
        $timeText = [string](Get-ZenProperty $obj 't' '')
        if (-not [datetimeoffset]::TryParse($timeText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$time)) { continue }
        if ($time -lt $cutoff -or $time -gt $limit) { continue }

        if (-not $agg.ContainsKey($req)) {
            $agg[$req] = @{
                calls = 0
                errors = 0
                msSum = 0.0
                msN = 0
                avgMs = 0
                lastStatus = 0
                lastAt = $null
                lastErrorAt = $null
            }
        }
        $item = $agg[$req]
        $item.calls = [int]$item.calls + 1
        $status = [int](Get-ZenProperty $obj 'status' 0)
        if ($status -ne 200) {
            $item.errors = [int]$item.errors + 1
            if ($null -eq $item.lastErrorAt -or $time -gt $item.lastErrorAt) { $item.lastErrorAt = $time }
        }
        $ms = 0.0
        $msText = [string](Get-ZenProperty $obj 'ms' '')
        if ([double]::TryParse($msText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ms)) {
            $item.msSum = [double]$item.msSum + $ms
            $item.msN = [int]$item.msN + 1
        }
        if ($null -eq $item.lastAt -or $time -gt $item.lastAt) {
            $item.lastAt = $time
            $item.lastStatus = $status
        }
    }
    foreach ($key in @($agg.Keys)) {
        $item = $agg[$key]
        if ([int]$item.msN -gt 0) { $item.avgMs = [int]([double]$item.msSum / [int]$item.msN) }
    }
    return $agg
}

function Get-MagpieHealth {
    param($Models, $Usage)
    if ($null -eq $Usage) { $Usage = @{} }
    $modelsById = @{}
    foreach ($model in @($Models)) {
        $id = [string](Get-ZenProperty $model 'id' '')
        if ($id) { $modelsById[$id] = $model }
    }
    $calls = 0
    $errors = 0
    $recent10 = 0
    $recentCutoff = [datetimeoffset]::Now.AddMinutes(-10)
    $errorModels = [System.Collections.Generic.List[object]]::new()

    foreach ($key in @($Usage.Keys)) {
        $item = $Usage[$key]
        $itemCalls = [int](Get-ZenProperty $item 'calls' 0)
        $itemErrors = [int](Get-ZenProperty $item 'errors' 0)
        $lastErrorAt = Get-ZenProperty $item 'lastErrorAt'
        $calls += $itemCalls
        $errors += $itemErrors
        if ($null -ne $lastErrorAt -and $lastErrorAt -ge $recentCutoff) { $recent10++ }
        if ($itemErrors -gt 0) {
            $name = [string](Get-ZenProperty $modelsById[$key] 'display_name' '')
            if (-not $name) { $name = [string](Get-ZenProperty $modelsById[$key] 'id' '') }
            if (-not $name) { $name = ($key -split '/')[-1] }
            $errorModels.Add([pscustomobject]@{
                Name = $name
                Id = $key
                Errors = $itemErrors
                LastErrorAt = $lastErrorAt
            })
        }
    }

    $sorted = @($errorModels | Sort-Object -Property @(
        @{ Expression = { if ($_.LastErrorAt) { $_.LastErrorAt } else { [datetimeoffset]::MinValue } }; Descending = $true },
        @{ Expression = { $_.Errors }; Descending = $true }
    ) | Select-Object -First 3)

    [pscustomobject]@{
        ModelCount = @($Models).Count
        Calls = $calls
        Errors = $errors
        ErrorModels = $sorted
        Recent10mErrors = $recent10
        HasRecent10mError = ($recent10 -gt 0)
    }
}

function ConvertTo-ZenView {
    param($Raw)
    if ($null -eq $Raw -or $Raw.ok -ne $true) { throw '网关返回 ok=false' }
    if ($null -eq $Raw.current) { throw 'status 缺少 current' }

    $ips = @($Raw.ips)
    $exhausted = @($ips | Where-Object { [bool](Get-ZenProperty $_ 'exhausted' $false) })
    $cooling = @($ips | Where-Object {
        $blocked = [bool](Get-ZenProperty $_ 'blocked' $false)
        $ex = [bool](Get-ZenProperty $_ 'exhausted' $false)
        $verdict = [string](Get-ZenProperty $_ 'verdict' '')
        $blocked -or $ex -or ($verdict -eq 'limited')
    })
    $totals = Get-ZenProperty $Raw 'totals'
    $nodes = Get-ZenProperty $Raw 'nodes'
    $events = @($Raw.events)
    $lastEvent = $null
    if ($events.Count -gt 0) { $lastEvent = $events[-1] }

    $available = Get-ZenProperty $totals 'usableIpCount'
    if ($null -eq $available) {
        $available = @($ips | Where-Object {
            -not [bool](Get-ZenProperty $_ 'exhausted' $false) -and -not [bool](Get-ZenProperty $_ 'blocked' $false)
        }).Count
    }
    $total = [int](Get-ZenProperty $totals 'ipCount' $ips.Count)
    $requests = Get-ZenProperty $totals 'requests'
    if ($null -eq $requests) {
        $requests = 0
        foreach ($ip in $ips) { $requests = [long]$requests + [long](Get-ZenProperty $ip 'requests' 0) }
    }
    $tokens = Get-ZenProperty $totals 'tokens'
    if ($null -eq $tokens) {
        $tokens = 0
        foreach ($ip in $ips) { $tokens = [long]$tokens + [long](Get-ZenProperty $ip 'tokens' 0) }
    }
    $sessions = [long](Get-ZenProperty $totals 'sessions' 0)

    $eventAt = '-'
    $eventMessage = ''
    if ($null -ne $lastEvent) {
        $eventAt = Format-ZenTime (Get-ZenProperty $lastEvent 't')
        $eventMessage = [string](Get-ZenProperty $lastEvent 'message' '')
    }

    $nodeTotal = [int](Get-ZenProperty $nodes 'total' $ips.Count)
    $nodeExhausted = [int](Get-ZenProperty $nodes 'exhausted' $exhausted.Count)
    $healthy = Get-ZenProperty $nodes 'healthy'
    if ($null -eq $healthy) { $healthy = $nodeTotal - $nodeExhausted }

    [pscustomobject]@{
        Now = Format-ZenTime $Raw.now
        EgressIp = [string]$Raw.current.egressIp
        Node = [string]$Raw.current.node
        Available = [int]$available
        Total = $total
        Requests = [long]$requests
        Tokens = [long]$tokens
        Sessions = [long]$sessions
        Exhausted = $exhausted
        Cooling = ($cooling.Count -gt 0)
        CoolingCount = $cooling.Count
        Healthy = [int]$healthy
        NodeTotal = $nodeTotal
        NodeExhausted = $nodeExhausted
        EventAt = $eventAt
        EventMessage = $eventMessage
    }
}

function Get-ZenSnapshot {
    param([switch]$RefreshModels)
    $view = $null
    $statusError = ''
    try {
        $view = ConvertTo-ZenView (Get-ZenStatus)
    } catch {
        $statusError = $_.Exception.Message
    }
    $models = Get-MagpieModels -Force:$RefreshModels
    $usage = Get-MagpieUsage
    $health = Get-MagpieHealth -Models $models -Usage $usage
    $online = ($null -ne $view)
    $egressIp = ''
    $node = ''
    $requests = 0
    $tokens = 0
    $sessions = 0
    $available = 0
    $total = 0
    $cooling = $false
    $coolingCount = 0
    $eventAt = '-'
    $eventMessage = ''
    if ($online) {
        $egressIp = $view.EgressIp
        $node = $view.Node
        $requests = $view.Requests
        $tokens = $view.Tokens
        $sessions = $view.Sessions
        $available = $view.Available
        $total = $view.Total
        $cooling = $view.Cooling
        $coolingCount = $view.CoolingCount
        $eventAt = $view.EventAt
        $eventMessage = $view.EventMessage
    }
    [pscustomobject]@{
        UpdatedAt = [datetime]::Now
        View = $view
        Online = $online
        StatusError = $statusError
        EgressIp = $egressIp
        Node = $node
        Requests = $requests
        Tokens = $tokens
        Sessions = $sessions
        Available = $available
        Total = $total
        Cooling = $cooling
        CoolingCount = $coolingCount
        EventAt = $eventAt
        EventMessage = $eventMessage
        Models = @($models)
        ModelCount = @($models).Count
        ModelsOk = [string]::IsNullOrEmpty($script:ModelsError)
        ModelsError = $script:ModelsError
        Usage = $usage
        ModelHealth = $health
    }
}

function Get-IpTail {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return '--' }
    if ($Ip.Contains(':')) {
        $parts = $Ip.Split(':')
        if ($parts.Count -ge 2) { return ($parts[$parts.Count - 2] + ':' + $parts[$parts.Count - 1]) }
        return $Ip
    }
    $parts = $Ip.Split('.')
    if ($parts.Count -ge 2) { return ($parts[$parts.Count - 2] + '.' + $parts[$parts.Count - 1]) }
    return $Ip
}

function Get-ZenColor {
    param($Snapshot)
    if ($null -eq $Snapshot -or -not $Snapshot.Online -or $Snapshot.Available -eq 0) { return 'red' }
    $hasRecentModelError = $false
    if ($null -ne $Snapshot.ModelHealth) { $hasRecentModelError = [bool]$Snapshot.ModelHealth.HasRecent10mError }
    if ($Snapshot.Cooling -or $hasRecentModelError) { return 'yellow' }
    return 'green'
}

function Get-ZenTooltip {
    param($Snapshot)
    if ($null -eq $Snapshot) { return 'Zen Router 启动中…' }
    $modelErrors = 0
    if ($null -ne $Snapshot.ModelHealth) { $modelErrors = [int]$Snapshot.ModelHealth.Errors }
    if (-not $Snapshot.Online) {
        return Get-ShortText "网关离线 · 模型错误 $modelErrors" $script:TipMax
    }
    $text = 'IP {0}/{1} · {2} · 模型错误 {3}' -f $Snapshot.Available, $Snapshot.Total, (Get-IpTail $Snapshot.EgressIp), $modelErrors
    return Get-ShortText $text $script:TipMax
}

function Get-ZenSummary {
    param($Snapshot)
    $nl = [Environment]::NewLine
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Snapshot) {
        $lines.Add('Zen 总览')
        $lines.Add('状态：等待数据')
        return ($lines -join $nl)
    }
    $lines.Add('Zen 总览')
    $lines.Add("更新时间：$($Snapshot.UpdatedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    if ($Snapshot.Online) {
        $state = if ($Snapshot.Available -eq 0) { '无可用 IP' } elseif ($Snapshot.Cooling) { '部分 IP 冷却' } else { '全部正常' }
        $lines.Add("状态：在线（$state）")
        $lines.Add("可用 IP：$($Snapshot.Available)/$($Snapshot.Total)（冷却：$($Snapshot.CoolingCount)）")
        $lines.Add("当前出口 IP：$($Snapshot.EgressIp)")
        $lines.Add("当前节点：$($Snapshot.Node)")
        $lines.Add("累计请求：$($Snapshot.Requests)（tokens：$($Snapshot.Tokens)，会话：$($Snapshot.Sessions)）")
    } else {
        $lines.Add('状态：网关离线')
        if ($Snapshot.StatusError) { $lines.Add("原因：$($Snapshot.StatusError)") }
        $lines.Add('可用 IP：--/--')
    }

    $health = $Snapshot.ModelHealth
    $modelCount = if ($Snapshot.ModelsOk -or $Snapshot.ModelCount -gt 0) { [string]$Snapshot.ModelCount } else { '--' }
    $lines.Add('')
    $lines.Add("magpie 模型：$modelCount 个")
    $lines.Add("近 1 小时：$($health.Calls) 调用，$($health.Errors) 错误")
    if ($health.Recent10mErrors -gt 0) { $lines.Add("近 10 分钟：$($health.Recent10mErrors) 个模型出现错误") }
    $errorModels = @($health.ErrorModels)
    if ($errorModels.Count -gt 0) {
        $lines.Add('异常模型：')
        foreach ($model in $errorModels) {
            $last = if ($model.LastErrorAt) { $model.LastErrorAt.ToLocalTime().ToString('HH:mm:ss') } else { '-' }
            $lines.Add("  - $($model.Name)：$($model.Errors) 错（最近 $last）")
        }
    } else {
        $lines.Add('异常模型：全部模型正常')
    }
    if ($Snapshot.ModelsError) { $lines.Add("模型目录警告：$($Snapshot.ModelsError)") }

    $lines.Add('')
    $lines.Add('最近事件：')
    if ($Snapshot.EventMessage) {
        $lines.Add("  [$($Snapshot.EventAt)] $(Get-ShortText $Snapshot.EventMessage 500)")
    } else {
        $lines.Add('  无')
    }
    return ($lines -join $nl)
}

function Test-Notify {
    param([string]$Key)
    $now = [datetime]::UtcNow
    if ($script:LastNotify.ContainsKey($Key)) {
        if (($now - $script:LastNotify[$Key]) -lt $script:NotifyWindow) { return $false }
    }
    $script:LastNotify[$Key] = $now
    return $true
}

function Show-ZenBalloon {
    param([string]$Title, [string]$Text, [string]$Icon = 'Info')
    if ($null -eq $script:Tray -or -not $script:Tray.Visible) { return }
    $tipIcon = switch ($Icon) {
        'Error' { [System.Windows.Forms.ToolTipIcon]::Error }
        'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
        default { [System.Windows.Forms.ToolTipIcon]::Info }
    }
    $script:Tray.ShowBalloonTip(5000, (Get-ShortText $Title 63), (Get-ShortText $Text 240), $tipIcon)
}

function Update-ZenNotifyState {
    param($View)
    # 默认静音：状态变化只在托盘颜色、悬浮总览和面板里体现。
    # 需要气泡时设 ZEN_NOTIFY=on。
    if ($env:ZEN_NOTIFY -ne 'on') { return }
    $new = if ($null -eq $View) {
        [pscustomobject]@{ Online = $false; Ip = ''; Available = 0; Total = 0; Exhausted = @(); NoAvailable = $true }
    } else {
        [pscustomobject]@{
            Online = $true
            Ip = $View.EgressIp
            Available = $View.Available
            Total = $View.Total
            Exhausted = @($View.Exhausted | ForEach-Object { [string]$_.ip })
            NoAvailable = ($View.Available -eq 0)
        }
    }

    if (-not $script:SeenState) {
        $script:LastState = $new
        $script:SeenState = $true
        return
    }

    $old = $script:LastState
    $messages = [System.Collections.Generic.List[string]]::new()
    $icon = 'Info'

    if (-not $old.Online -and $new.Online) {
        if (Test-Notify 'online') { $messages.Add('网关已恢复在线') }
    } elseif ($old.Online -and -not $new.Online) {
        $icon = 'Error'
        if (Test-Notify 'offline') { $messages.Add('网关离线') }
    } elseif ($old.Online -and $new.Online) {
        if ($new.NoAvailable -and -not $old.NoAvailable) {
            if (Test-Notify 'no-available') { $messages.Add('无可用出口 IP'); $icon = 'Error' }
        } else {
            $newIps = @($new.Exhausted | Where-Object { $_ -notin $old.Exhausted })
            if ($newIps.Count -gt 0 -and (Test-Notify ('exhausted:' + ($new.Exhausted -join ',')))) {
                $messages.Add('IP 耗尽：' + ($newIps -join '、'))
                $icon = 'Warning'
            }
        }
        if ($new.Ip -ne $old.Ip -and (Test-Notify ('ip:' + $new.Ip))) {
            $messages.Add(('出口已切换：{0} → {1}' -f $old.Ip, $new.Ip))
        }
    }

    $script:LastState = $new
    if ($messages.Count -gt 0) {
        Show-ZenBalloon -Title 'Zen Router 状态变化' -Text ($messages -join '；') -Icon $icon
    }
}

function New-ZenIcon {
    param([string]$Color)
    if (-not ('ZenTrayNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZenTrayNative {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@
    }

    $fill = switch ($Color) {
        'green' { [System.Drawing.Color]::FromArgb(46, 204, 113) }
        'yellow' { [System.Drawing.Color]::FromArgb(241, 196, 15) }
        default { [System.Drawing.Color]::FromArgb(231, 76, 60) }
    }
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $fillBrush = [System.Drawing.SolidBrush]::new($fill)
    $g.FillEllipse($fillBrush, 1, 1, 30, 30)
    $fillBrush.Dispose()

    $ring = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2)
    $g.DrawEllipse($ring, 2, 2, 28, 28)
    $ring.Dispose()

    $mark = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 3.5)
    $mark.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $mark.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

    switch ($Color) {
        'green' {
            $g.DrawLines($mark, [System.Drawing.Point[]]@(
                [System.Drawing.Point]::new(9, 17),
                [System.Drawing.Point]::new(14, 22),
                [System.Drawing.Point]::new(23, 10)
            ))
        }
        'yellow' {
            $g.DrawLine($mark, 16, 8, 16, 19)
            $dot = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
            $g.FillEllipse($dot, 13.5, 23, 5, 5)
            $dot.Dispose()
        }
        default {
            $g.DrawLine($mark, 10, 10, 22, 22)
            $g.DrawLine($mark, 22, 10, 10, 22)
        }
    }
    $mark.Dispose()

    $handle = $bmp.GetHicon()
    try {
        $temp = [System.Drawing.Icon]::FromHandle($handle)
        $icon = $temp.Clone()
        $temp.Dispose()
    } finally {
        [ZenTrayNative]::DestroyIcon($handle) | Out-Null
        $g.Dispose()
        $bmp.Dispose()
    }
    return $icon
}

function Set-ZenTray {
    param($Snapshot)
    if ($null -eq $script:Tray) { return }
    $color = Get-ZenColor -Snapshot $Snapshot
    if ($color -ne $script:CurrentColor) {
        $script:Tray.Icon = $script:Icons[$color]
        $script:CurrentColor = $color
    }
    $script:Tray.Text = Get-ZenTooltip -Snapshot $Snapshot
}

function Add-ZenHoverType {
    if ('ZenHoverForm' -as [type]) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $refs = @(
        [System.Windows.Forms.Form].Assembly.Location
        [System.Drawing.Bitmap].Assembly.Location
        [System.Drawing.Color].Assembly.Location
        [System.ComponentModel.Component].Assembly.Location
        [System.Windows.Forms.Message].Assembly.Location
    ) | Sort-Object -Unique
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class ZenHoverForm : Form {
    public ZenHoverForm() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        Width = 420;
        Height = 240;
        BackColor = Color.FromArgb(13, 17, 23);
        DoubleBuffered = true;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
    }
    protected override bool ShowWithoutActivation {
        get { return true; }
    }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;
            cp.ExStyle |= 0x00000080;
            return cp;
        }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) {
            m.Result = (IntPtr)3;
            return;
        }
        base.WndProc(ref m);
    }
    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        if (Width <= 0 || Height <= 0) return;
        int radius = 14;
        using (var path = new GraphicsPath()) {
            var rect = new Rectangle(0, 0, Width, Height);
            path.AddArc(rect.X, rect.Y, radius * 2, radius * 2, 180, 90);
            path.AddArc(rect.Right - radius * 2, rect.Y, radius * 2, radius * 2, 270, 90);
            path.AddArc(rect.Right - radius * 2, rect.Bottom - radius * 2, radius * 2, radius * 2, 0, 90);
            path.AddArc(rect.X, rect.Bottom - radius * 2, radius * 2, radius * 2, 90, 90);
            path.CloseFigure();
            var old = Region;
            Region = new Region(path);
            if (old != null) old.Dispose();
        }
    }
}
'@ -ReferencedAssemblies $refs
}

function Initialize-ZenHoverResources {
    if ($null -ne $script:HoverFonts) { return }
    $script:HoverColors = @{
        bg = [System.Drawing.Color]::FromArgb(13, 17, 23)
        line = [System.Drawing.Color]::FromArgb(48, 54, 61)
        text = [System.Drawing.Color]::FromArgb(230, 237, 243)
        muted = [System.Drawing.Color]::FromArgb(139, 148, 158)
        green = [System.Drawing.Color]::FromArgb(63, 185, 80)
        yellow = [System.Drawing.Color]::FromArgb(210, 153, 34)
        red = [System.Drawing.Color]::FromArgb(248, 81, 73)
    }
    $script:HoverBrushes = @{}
    foreach ($key in $script:HoverColors.Keys) {
        $script:HoverBrushes[$key] = [System.Drawing.SolidBrush]::new($script:HoverColors[$key])
    }
    $script:HoverPens = @{
        border = [System.Drawing.Pen]::new($script:HoverColors.line, 1)
        line = [System.Drawing.Pen]::new($script:HoverColors.line, 1)
    }
    $script:HoverFonts = @{
        title = [System.Drawing.Font]::new('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
        big = [System.Drawing.Font]::new('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
        body = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
        small = [System.Drawing.Font]::new('Microsoft YaHei UI', 8)
        tiny = [System.Drawing.Font]::new('Microsoft YaHei UI', 7.5)
        mono = [System.Drawing.Font]::new('Consolas', 8)
    }
    $script:HoverFormats = @{
        left = [System.Drawing.StringFormat]::new()
        right = [System.Drawing.StringFormat]::new()
        ellipsis = [System.Drawing.StringFormat]::new()
    }
    $script:HoverFormats.left.Alignment = [System.Drawing.StringAlignment]::Near
    $script:HoverFormats.left.LineAlignment = [System.Drawing.StringAlignment]::Center
    $script:HoverFormats.right.Alignment = [System.Drawing.StringAlignment]::Far
    $script:HoverFormats.right.LineAlignment = [System.Drawing.StringAlignment]::Center
    $script:HoverFormats.right.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $script:HoverFormats.ellipsis.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $script:HoverFormats.ellipsis.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $script:HoverFormats.ellipsis.LineAlignment = [System.Drawing.StringAlignment]::Center
}

function New-ZenHoverForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-ZenHoverType
    Initialize-ZenHoverResources
    if ($null -ne $script:HoverForm) { return $script:HoverForm }
    $form = [ZenHoverForm]::new()
    $form.Text = 'ZenHoverPreview'
    $form.add_Paint({ param($sender, $e) Paint-ZenHover -Graphics $e.Graphics -Snapshot $script:Snapshot })
    $form.add_MouseClick({ Hide-ZenHover })
    $script:HoverForm = $form
    return $form
}

function Paint-ZenHover {
    param($Graphics, $Snapshot)
    $g = $Graphics
    $w = $script:HoverForm.ClientSize.Width
    $h = $script:HoverForm.ClientSize.Height
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear($script:HoverColors.bg)
    $br = $script:HoverBrushes
    $fonts = $script:HoverFonts
    $formats = $script:HoverFormats

    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $radius = 14
    $rect = [System.Drawing.Rectangle]::new(0, 0, $w - 1, $h - 1)
    $path.AddArc($rect.X, $rect.Y, $radius * 2, $radius * 2, 180, 90)
    $path.AddArc($rect.Right - $radius * 2, $rect.Y, $radius * 2, $radius * 2, 270, 90)
    $path.AddArc($rect.Right - $radius * 2, $rect.Bottom - $radius * 2, $radius * 2, $radius * 2, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $radius * 2, $radius * 2, $radius * 2, 90, 90)
    $path.CloseFigure()
    $g.DrawPath($script:HoverPens.border, $path)
    $path.Dispose()

    $g.DrawString('ZEN 总览', $fonts.title, $br.text, 16, 10)
    $nowText = [datetime]::Now.ToString('HH:mm:ss')
    $g.DrawString($nowText, $fonts.small, $br.muted, [System.Drawing.RectangleF]::new(16, 12, $w - 32, 18), $formats.right)
    $g.DrawLine($script:HoverPens.line, 16, 34, $w - 16, 34)

    if ($null -eq $Snapshot) {
        $g.DrawString('正在读取…', $fonts.big, $br.muted, 16, 44)
        $g.DrawString('更新 --:--:-- · magpie 3425 / zen 7999', $fonts.tiny, $br.muted, 16, 222)
        return
    }

    $colorKey = Get-ZenColor -Snapshot $Snapshot
    $accent = $br[$colorKey]
    $health = $Snapshot.ModelHealth
    if ($null -eq $health) {
        $health = [pscustomobject]@{ Calls = 0; Errors = 0; ErrorModels = @(); Recent10mErrors = 0; HasRecent10mError = $false }
    }

    if ($Snapshot.Online) {
        $g.FillEllipse($accent, 16, 48, 14, 14)
        $g.DrawString(('可用 {0} / {1} 个出口 IP' -f $Snapshot.Available, $Snapshot.Total), $fonts.big, $br.text, 38, 39)
        $ipLine = '出口 {0} · 请求 {1} · tokens {2} · 会话 {3}' -f $Snapshot.EgressIp, (Format-Num $Snapshot.Requests), (Format-Num $Snapshot.Tokens), $Snapshot.Sessions
        $g.DrawString($ipLine, $fonts.body, $br.text, 16, 74)
    } else {
        $g.FillEllipse($br.red, 16, 48, 14, 14)
        $g.DrawString('网关离线', $fonts.big, $br.red, 38, 39)
        $errorText = Get-ShortText $Snapshot.StatusError 70
        if (-not $errorText) { $errorText = '无法连接 zen-router' }
        $g.DrawString("状态接口不可用：$errorText", $fonts.body, $br.red, 16, 74)
    }

    $modelCount = if ($Snapshot.ModelsOk -or $Snapshot.ModelCount -gt 0) { [string]$Snapshot.ModelCount } else { '--' }
    $modelLine = 'magpie {0} 个模型 · 近 1 小时 {1} 调用 · {2} 错误' -f $modelCount, (Format-Num $health.Calls), $health.Errors
    $g.DrawString($modelLine, $fonts.body, $br.muted, 16, 92)
    $g.DrawLine($script:HoverPens.line, 16, 110, $w - 16, 110)

    $errorModels = @($health.ErrorModels | Select-Object -First 3)
    if ($health.Errors -gt 0 -and $errorModels.Count -gt 0) {
        $g.DrawString('异常模型（近 1 小时，最多 3 个）', $fonts.small, $br.muted, 16, 116)
        $y = 134
        foreach ($model in $errorModels) {
            $g.FillEllipse($br.red, 16, $y + 5, 6, 6)
            $g.DrawString([string]$model.Name, $fonts.body, $br.text, [System.Drawing.RectangleF]::new(28, $y, 250, 18), $formats.ellipsis)
            $g.DrawString(('{0} 错' -f $model.Errors), $fonts.body, $br.red, [System.Drawing.RectangleF]::new(286, $y, 58, 18), $formats.right)
            $y += 18
        }
    } else {
        $g.FillEllipse($br.green, 16, 119, 6, 6)
        $g.DrawString('全部模型正常', $fonts.body, $br.green, 28, 112)
    }

    $eventText = '最近事件  '
    if ($Snapshot.EventMessage) {
        $eventTime = [string]$Snapshot.EventAt
        if ($eventTime.Length -ge 8) { $eventTime = $eventTime.Substring($eventTime.Length - 8) }
        $eventText += "$eventTime  $($Snapshot.EventMessage)"
    } else {
        $eventText += '暂无'
    }
    $g.DrawString($eventText, $fonts.small, $br.muted, [System.Drawing.RectangleF]::new(16, 192, $w - 32, 20), $formats.ellipsis)
    $g.DrawString(('更新 {0} · magpie 3425 / zen 7999' -f $Snapshot.UpdatedAt.ToString('HH:mm:ss')), $fonts.tiny, $br.muted, 16, 222)
}

function Show-ZenHover {
    if ($null -eq $script:Snapshot) { return }
    if ($null -ne $script:Menu -and $script:Menu.Visible) { return }
    $form = New-ZenHoverForm
    if (-not $form.Visible) {
        $cursor = [System.Windows.Forms.Cursor]::Position
        $area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
        $x = $cursor.X + 18
        $y = $cursor.Y - $form.Height - 14
        if ($x + $form.Width -gt $area.Right) { $x = $cursor.X - $form.Width - 18 }
        if ($y -lt $area.Top) { $y = $cursor.Y + 18 }
        if ($x -lt $area.Left) { $x = $area.Left }
        if ($y + $form.Height -gt $area.Bottom) { $y = $area.Bottom - $form.Height }
        if ($x + $form.Width -gt $area.Right) { $x = $area.Right - $form.Width }
        $form.Location = [System.Drawing.Point]::new([int]$x, [int]$y)
        $form.Show()
        $script:HoverAnchor = $cursor
    } else {
        $script:HoverAnchor = [System.Windows.Forms.Cursor]::Position
    }
    $script:HoverInsideAt = [datetime]::Now
    $form.Invalidate()
}

function Hide-ZenHover {
    if ($null -ne $script:HoverForm -and $script:HoverForm.Visible) { $script:HoverForm.Hide() }
}

function Start-ZenHoverWatch {
    if ($null -ne $script:HoverWatch) { return }
    $watch = [System.Windows.Forms.Timer]::new()
    $watch.Interval = 100
    $watch.add_Tick({
        if ($null -eq $script:HoverForm -or -not $script:HoverForm.Visible) { return }
        $cursor = [System.Windows.Forms.Cursor]::Position
        $inside = $script:HoverForm.Bounds.Contains($cursor)
        if (-not $inside -and $null -ne $script:HoverAnchor) {
            $dx = [math]::Abs($cursor.X - $script:HoverAnchor.X)
            $dy = [math]::Abs($cursor.Y - $script:HoverAnchor.Y)
            if ($dx -le 40 -and $dy -le 40) { $inside = $true }
        }
        if ($inside) {
            $script:HoverInsideAt = [datetime]::Now
        } elseif ((([datetime]::Now - $script:HoverInsideAt).TotalMilliseconds) -ge 400) {
            Hide-ZenHover
        }
    })
    $script:HoverWatch = $watch
    $watch.Start()
}

function Clear-ZenHoverResources {
    if ($null -ne $script:HoverWatch) {
        $script:HoverWatch.Stop()
        $script:HoverWatch.Dispose()
        $script:HoverWatch = $null
    }
    if ($null -ne $script:HoverForm) {
        $script:HoverForm.Dispose()
        $script:HoverForm = $null
    }
    if ($null -ne $script:HoverBrushes) {
        foreach ($brush in $script:HoverBrushes.Values) { $brush.Dispose() }
        $script:HoverBrushes = $null
    }
    if ($null -ne $script:HoverPens) {
        foreach ($pen in $script:HoverPens.Values) { $pen.Dispose() }
        $script:HoverPens = $null
    }
    if ($null -ne $script:HoverFonts) {
        foreach ($font in $script:HoverFonts.Values) { $font.Dispose() }
        $script:HoverFonts = $null
    }
    if ($null -ne $script:HoverFormats) {
        foreach ($format in $script:HoverFormats.Values) { $format.Dispose() }
        $script:HoverFormats = $null
    }
}

function Show-ZenDashboard {
    Hide-ZenHover
    $title = 'Zen 状态面板'
    try {
        $h = [ZenWin32]::FindWindow($null, $title)
        if ($h -ne [IntPtr]::Zero) {
            [void][ZenWin32]::ShowWindow($h, 9)
            [void][ZenWin32]::SetForegroundWindow($h)
            return
        }
    } catch { }
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $panel = Join-Path $PSScriptRoot 'zen-dashboard.ps1'
    if (Test-Path -LiteralPath $panel) {
        Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $panel) -WindowStyle Hidden
    }
}

function Show-ZenStatusDialog {
    Hide-ZenHover
    try {
        $snapshot = Get-ZenSnapshot
        [System.Windows.Forms.MessageBox]::Show((Get-ZenSummary $snapshot), 'Zen 状态摘要', 'OK', 'Information') | Out-Null
    } catch {
        $nl = [Environment]::NewLine
        $msg = '获取状态失败。' + $nl + $nl + $_.Exception.Message
        if ($script:Snapshot) {
            $msg += $nl + $nl + '最后一次总览：' + $nl + (Get-ZenSummary $script:Snapshot)
        }
        [System.Windows.Forms.MessageBox]::Show($msg, 'Zen 状态摘要', 'OK', 'Error') | Out-Null
    }
}

function Invoke-ZenCommand {
    param([string]$Path, [string]$Name, [int]$TimeoutSec = 10)
    Hide-ZenHover
    try {
        $response = Invoke-ZenApi -Path $Path -Method 'Post' -TimeoutSec $TimeoutSec
        if ((Get-ZenProperty $response 'ok') -eq $false) {
            throw [string](Get-ZenProperty $response 'message' '接口返回 ok=false')
        }
        $text = "$Name 请求已完成，状态已刷新。"
        if ($response -is [pscustomobject]) {
            $message = $response.PSObject.Properties['message']
            if ($null -ne $message -and $message.Value) { $text += [Environment]::NewLine + [Environment]::NewLine + [string]$message.Value }
        }
        [System.Windows.Forms.MessageBox]::Show($text, 'Zen Router', 'OK', 'Information') | Out-Null
        Update-ZenStatus
    } catch {
        [System.Windows.Forms.MessageBox]::Show("$Name 失败：$($_.Exception.Message)", 'Zen Router', 'OK', 'Error') | Out-Null
    }
}

function Open-ZenLog {
    Hide-ZenHover
    if (-not (Test-Path -LiteralPath $script:LogPath)) {
        [System.Windows.Forms.MessageBox]::Show("日志文件不存在：$([Environment]::NewLine)$($script:LogPath)", 'Zen Router', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        Start-Process -FilePath 'notepad.exe' -ArgumentList $script:LogPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show("打开日志失败：$($_.Exception.Message)", 'Zen Router', 'OK', 'Error') | Out-Null
    }
}

function Update-ZenStatus {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $snapshot = Get-ZenSnapshot
        $script:Snapshot = $snapshot
        if ($snapshot.Online) { $script:LastView = $snapshot.View }
        Set-ZenTray -Snapshot $snapshot
        Update-ZenNotifyState -View $snapshot.View
        if ($null -ne $script:HoverForm -and $script:HoverForm.Visible) { $script:HoverForm.Invalidate() }
    } catch {
        $script:Snapshot = $null
        if ($null -ne $script:Tray) {
            if ($script:CurrentColor -ne 'red') {
                $script:Tray.Icon = $script:Icons['red']
                $script:CurrentColor = 'red'
            }
            $script:Tray.Text = Get-ShortText ('网关离线：' + $_.Exception.Message) $script:TipMax
        }
        Update-ZenNotifyState -View $null
    } finally {
        $script:Busy = $false
    }
}

function Start-ZenTray {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    if (-not ('ZenWin32' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ZenWin32 {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
    }

    $mutex = [System.Threading.Mutex]::new($false, 'Local\ZenRouterTrayMonitor')
    $owned = $false
    try {
        $owned = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $owned = $true
    }
    if (-not $owned) {
        $mutex.Dispose()
        return
    }

    try {
        $script:Icons = @{
            green = New-ZenIcon -Color 'green'
            yellow = New-ZenIcon -Color 'yellow'
            red = New-ZenIcon -Color 'red'
        }

        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        $menu.ShowImageMargin = $false
        $menu.add_Opening({ Hide-ZenHover })
        $item = $menu.Items.Add('打开状态面板')
        $item.add_Click({ Show-ZenDashboard })
        $item = $menu.Items.Add('状态摘要')
        $item.add_Click({ Show-ZenStatusDialog })
        $item = $menu.Items.Add('立即换 IP')
        $item.add_Click({ Invoke-ZenCommand -Path '/rotate' -Name '换 IP' })
        $item = $menu.Items.Add('重新测速')
        $item.add_Click({ Invoke-ZenCommand -Path '/probe' -Name '重新测速' -TimeoutSec 30 })
        $item = $menu.Items.Add('打开日志')
        $item.add_Click({ Open-ZenLog })
        $menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
        $item = $menu.Items.Add('退出')
        $item.add_Click({
            Hide-ZenHover
            if ($script:Tray) { $script:Tray.Visible = $false }
            [System.Windows.Forms.Application]::Exit()
        })
        $script:Menu = $menu

        $tray = [System.Windows.Forms.NotifyIcon]::new()
        $tray.Icon = $script:Icons['red']
        try {
            $tray.Text = ('x' * 127)
            $script:TipMax = 127
        } catch {
            $script:TipMax = 63
        }
        $tray.Text = 'Zen Router 启动中…'
        $tray.ContextMenuStrip = $menu
        $tray.add_MouseMove({ Show-ZenHover })
        $tray.add_MouseClick({ param($sender, $eventArgs) if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Hide-ZenHover; Show-ZenDashboard } })
        $tray.add_DoubleClick({ Hide-ZenHover; Show-ZenDashboard })
        $tray.Visible = $true
        $script:Tray = $tray
        $script:CurrentColor = 'red'

        Update-ZenStatus
        Start-ZenHoverWatch

        $script:Timer = [System.Windows.Forms.Timer]::new()
        $script:Timer.Interval = 10000
        $script:Timer.add_Tick({ Update-ZenStatus })
        $script:Timer.Start()

        [System.Windows.Forms.Application]::Run()
    } finally {
        if ($script:Timer) {
            $script:Timer.Stop()
            $script:Timer.Dispose()
            $script:Timer = $null
        }
        Clear-ZenHoverResources
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
            $script:Tray = $null
        }
        if ($script:Menu) {
            $script:Menu.Dispose()
            $script:Menu = $null
        }
        foreach ($icon in $script:Icons.Values) { $icon.Dispose() }
        $script:Icons = @{}
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($PreviewHover) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    $script:Snapshot = Get-ZenSnapshot -RefreshModels
    $form = New-ZenHoverForm
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = [System.Drawing.Point]::new(
        [int]($area.Left + ($area.Width - $form.Width) / 2),
        [int]($area.Top + ($area.Height - $form.Height) / 2)
    )
    $form.Show()
    $previewTimer = [System.Windows.Forms.Timer]::new()
    $previewTimer.Interval = 8000
    $previewTimer.add_Tick({
        $previewTimer.Stop()
        if ($script:HoverForm) { $script:HoverForm.Close() }
        [System.Windows.Forms.Application]::Exit()
    })
    $previewTimer.Start()
    [System.Windows.Forms.Application]::Run()
    $previewTimer.Dispose()
    Clear-ZenHoverResources
    exit 0
}

if ($SelfTest) {
    Write-Host "Zen Router 自测：$($script:BaseUrl)/status + $($script:MagpieUrl)/v1/models" -ForegroundColor Cyan
    try {
        $snapshot = Get-ZenSnapshot -RefreshModels
        Write-Host (Get-ZenSummary $snapshot)
        if (-not $snapshot.Online) {
            Write-Host ''
            Write-Host '自测失败：zen-router /status 不可用。' -ForegroundColor Red
            exit 1
        }
        if ($snapshot.ModelsError) {
            Write-Host ''
            Write-Host "模型目录警告：$($snapshot.ModelsError)" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '自测通过：/status 与模型健康数据可读取。' -ForegroundColor Green
        exit 0
    } catch {
        Write-Host ''
        Write-Host '自测失败：读取总览数据时出错。' -ForegroundColor Red
        Write-Host "  原因：$($_.Exception.Message)"
        exit 1
    }
}

Start-ZenTray

# 启动说明：
# 1. 隐藏启动：
#    pwsh -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\Administrator\.zen-ip\zen-tray.ps1"
#    本机若 PATH 中没有 pwsh，可用 DSH 自带：
#    C:\Users\Administrator\.dsh\profiles\desktop\node_modules\@dsh-ops\pwsh-win32-x64\bin\pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\Administrator\.zen-ip\zen-tray.ps1"
# 2. 开机自启快捷方式：
#    Win+R 输入 shell:startup 回车，打开 Start Menu\Programs\Startup 文件夹。
#    右键 -> 新建 -> 快捷方式，目标填上面的完整命令（含参数），名称填 Zen Router 托盘。
# 3. 自测：
#    pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Administrator\.zen-ip\zen-tray.ps1" -SelfTest
# 4. 悬浮总览预览（8 秒，供截图）：
#    pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Administrator\.zen-ip\zen-tray.ps1" -PreviewHover
