#requires -Version 7.0
# Zen 状态面板：出口 IP 热力图 + magpie 全模型健康，一眼看明白。
param(
    [string]$BaseUrl = 'http://127.0.0.1:7999',
    [string]$MagpieUrl = 'http://127.0.0.1:3425',
    [string]$UsagePath = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:DataDir = if ($env:ZEN_IP_HOME) { $env:ZEN_IP_HOME } else { Join-Path $env:USERPROFILE '.zen-ip' }
if (-not $UsagePath) { $UsagePath = Join-Path $env:USERPROFILE '.config\magpie\usage.jsonl' }
$script:Status = $null
$script:Models = @()
$script:Usage = @{}
$script:Limits = @{}
$script:ErrorText = ''
$script:Updated = $null

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-Status {
    Invoke-RestMethod -Uri "$BaseUrl/status" -TimeoutSec 4 -NoProxy
}

function Get-ModelList {
    $r = Invoke-RestMethod -Uri "$MagpieUrl/v1/models" -Headers @{ Authorization = 'Bearer magpie' } -TimeoutSec 5 -NoProxy
    @($r.data)
}

function Get-UsageAgg {
    if (-not (Test-Path -LiteralPath $UsagePath)) { return @{} }
    $agg = @{}
    $lines = Get-Content -LiteralPath $UsagePath -Tail 2500 -ErrorAction SilentlyContinue
    $now = [DateTimeOffset]::Now
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        $key = [string](Get-Prop $o 'req' '')
        if (-not $key) { $key = [string](Get-Prop $o 'provider' '') + '/' + [string](Get-Prop $o 'model' '') }
        if (-not $agg.ContainsKey($key)) {
            $agg[$key] = @{ calls = 0; errors = 0; msSum = 0.0; msN = 0; tokens = 0; maxIn = 0; last = $null; lastStatus = $null; lastModel = '' }
        }
        $a = $agg[$key]
        $a.maxIn = [Math]::Max([int]$a.maxIn, [int](Get-Prop $o 'in' 0))
        $t = $null
        try { $t = [DateTimeOffset]::Parse([string](Get-Prop $o 't' '')) } catch {}
        $status = Get-Prop $o 'status' 0
        if ($t -and ($now - $t).TotalHours -le 1) {
            $a.calls++
            if ($status -ne 200) { $a.errors++ }
            $ms = Get-Prop $o 'ms' 0
            if ($ms) { $a.msSum += [double]$ms; $a.msN++ }
            $a.tokens += [int](Get-Prop $o 'in' 0) + [int](Get-Prop $o 'out' 0)
        }
        if ($null -eq $a.last -or ($t -and $t -gt $a.last)) {
            $a.last = $t; $a.lastStatus = $status; $a.lastModel = [string](Get-Prop $o 'model' '')
        }
    }
    $agg
}

function Get-LimitMap {
    try {
        $raw = Get-Content -LiteralPath (Join-Path $script:DataDir 'model-limits.json') -Raw -ErrorAction Stop
        return ($raw | ConvertFrom-Json -AsHashtable)
    } catch { return @{} }
}

function Update-Data {
    try {
        $script:Limits = Get-LimitMap
        $script:Status = Get-Status
        $script:Models = Get-ModelList
        $script:Usage = Get-UsageAgg
        $script:ErrorText = ''
    } catch {
        $script:ErrorText = $_.Exception.Message
    }
    $script:Updated = Get-Date
}

function Format-Num {
    param([double]$n)
    if ($n -ge 1000000) { return ('{0:0.0}M' -f ($n / 1000000)) }
    if ($n -ge 1000) { return ('{0:0.0}K' -f ($n / 1000)) }
    return [string][int]$n
}

$script:C = @{
    bg     = [System.Drawing.Color]::FromArgb(13, 17, 23)
    panel  = [System.Drawing.Color]::FromArgb(22, 27, 34)
    line   = [System.Drawing.Color]::FromArgb(48, 54, 61)
    text   = [System.Drawing.Color]::FromArgb(230, 237, 243)
    muted  = [System.Drawing.Color]::FromArgb(139, 148, 158)
    green  = [System.Drawing.Color]::FromArgb(46, 160, 67)
    amber  = [System.Drawing.Color]::FromArgb(210, 153, 34)
    red    = [System.Drawing.Color]::FromArgb(218, 54, 51)
    gray   = [System.Drawing.Color]::FromArgb(72, 79, 88)
    accent = [System.Drawing.Color]::FromArgb(56, 139, 253)
}
$script:F = @{
    h1   = [System.Drawing.Font]::new('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
    h2   = [System.Drawing.Font]::new('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    body = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
    small = [System.Drawing.Font]::new('Microsoft YaHei UI', 8)
    mono = [System.Drawing.Font]::new('Consolas', 9)
}

function Get-IpState {
    param($Ip)
    $st = Get-Prop $Ip 'verdict' 'unknown'
    $ex = [bool](Get-Prop $Ip 'exhausted' $false)
    $bl = [bool](Get-Prop $Ip 'blocked' $false)
    if ($bl -or $st -eq 'blocked' -or $st -eq 'unavailable') { return 'red' }
    if ($ex -or $st -eq 'limited') { return 'amber' }
    if ($st -eq 'ok' -or $st -eq 'unknown') { if ($ex -or $bl) { return 'amber' } return 'green' }
    return 'gray'
}

function Paint-Header {
    param($g, $w)
    $g.Clear($script:C.bg)
    if ($script:Status) {
        $totals = Get-Prop $script:Status 'totals'
        $cur = Get-Prop $script:Status 'current'
        $usable = [int](Get-Prop $totals 'usableIpCount' 0)
        $total = [int](Get-Prop $totals 'ipCount' 0)
        $requests = [double](Get-Prop $totals 'requests' 0)
        $tokens = [double](Get-Prop $totals 'tokens' 0)
        $sessions = [int](Get-Prop $totals 'sessions' 0)
        $color = if ($usable -eq 0) { $script:C.red } else { $script:C.green }
        $g.FillEllipse([System.Drawing.SolidBrush]::new($color), 12, 16, 16, 16)
        $g.DrawString("$usable", $script:F.h1, [System.Drawing.SolidBrush]::new($script:C.text), 36, 6)
        $g.DrawString("/ $total 个出口 IP 可用", $script:F.body, [System.Drawing.SolidBrush]::new($script:C.muted), 86, 22)
        $g.DrawString("当前出口 " + [string](Get-Prop $cur 'egressIp' '-') + "   ·   请求 " + (Format-Num $requests) + "   ·   tokens " + (Format-Num $tokens) + "   ·   会话 " + $sessions, $script:F.body, [System.Drawing.SolidBrush]::new($script:C.text), 12, 52)
        $models = @($script:Models | Where-Object { [string](Get-Prop $_ 'id' '').StartsWith('opencode-zen-free/') }).Count
        $errs = 0
        foreach ($k in $script:Usage.Keys) { $errs += [int]$script:Usage[$k].errors }
        $g.DrawString("magpie 3425 · $models 个模型 · 近 1 小时错误 $errs    " + $(if ($script:Updated) { $script:Updated.ToString('HH:mm:ss') } else { '' }), $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 12, 76)
    } else {
        $g.DrawString('网关离线', $script:F.h1, [System.Drawing.SolidBrush]::new($script:C.red), 12, 20)
    }
}

function Paint-Heat {
    param($g, $w, $h)
    $g.Clear($script:C.panel)
    $g.DrawString('出口 IP 健康热力图', $script:F.h2, [System.Drawing.SolidBrush]::new($script:C.text), 10, 8)
    $ips = @()
    if ($script:Status) { $ips = @(Get-Prop $script:Status 'ips' @()) }
    $ips = @($ips | Sort-Object -Property @(
        @{ Expression = { switch (Get-IpState $_) { 'green' { 0 } 'amber' { 1 } 'red' { 2 } default { 3 } } } },
        @{ Expression = { -[int](Get-Prop $_ 'requests' 0) } }
    ))
    $count = @{ green = 0; amber = 0; red = 0; gray = 0 }
    foreach ($ip in $ips) { $count[(Get-IpState $ip)]++ }
    $g.DrawString(("可用 {0} · 冷却/额度 {1} · 被拒 {2} · 未测 {3} · 白框是当前" -f $count.green, $count.amber, $count.red, $count.gray), $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 205, 14)
    $curIp = [string](Get-Prop (Get-Prop $script:Status 'current') 'egressIp' '')
    $cols = 12
    $tileW = 58; $tileH = 30; $gap = 6
    $x0 = 10; $y0 = 38
    for ($i = 0; $i -lt $ips.Count; $i++) {
        $ip = $ips[$i]
        $col = $i % $cols; $row = [math]::Floor($i / $cols)
        $x = $x0 + $col * ($tileW + $gap); $y = $y0 + $row * ($tileH + $gap)
        $state = Get-IpState $ip
        $brush = [System.Drawing.SolidBrush]::new($script:C[$state])
        $g.FillRectangle($brush, $x, $y, $tileW, $tileH)
        $addr = [string](Get-Prop $ip 'ip' '')
        $last = ($addr -split '\.')[-1]
        $g.DrawString($last, $script:F.mono, [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White), $x + 4, $y + 3)
        $n = [int](Get-Prop $ip 'requests' 0)
        if ($n -gt 0) { $g.DrawString([string]$n, $script:F.small, [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White), $x + 24, $y + 14) }
        if ($addr -eq $curIp) { $g.DrawRectangle([System.Drawing.Pen]::new([System.Drawing.Color]::White, 2), $x - 1, $y - 1, $tileW + 2, $tileH + 2) }
        $brush.Dispose()
    }
}

function Paint-Models {
    param($g, $w, $h)
    $g.Clear($script:C.panel)
    $g.DrawString('模型健康（近 1 小时 / 最近一次）', $script:F.h2, [System.Drawing.SolidBrush]::new($script:C.text), 10, 8)
    $rows = @()
    $seen = @{}
    foreach ($m in @($script:Models)) {
        $id = [string](Get-Prop $m 'id' '')
        if (-not $id) { continue }
        if (-not $id.StartsWith('opencode-zen-free/')) { continue }
        $seen[$id] = $true
        $u = if ($script:Usage.ContainsKey($id)) { $script:Usage[$id] } else { $null }
        $cap = [int](Get-Prop $m 'context_length' 0)
        $lim = Get-Prop $script:Limits $id $null
        if ($lim) { $cap = [int](Get-Prop $lim 'contextWindow' $cap) }
        $rows += [pscustomobject]@{ id = $id; name = [string](Get-Prop $m 'display_name' $id); usage = $u; cap = $cap }
    }
    # 只显示当前 magpie 暴露的模型，历史里已经下线的模型不再占一行。
    $rows = $rows | Sort-Object -Property @{ Expression = { if ($_.usage -and $_.usage.last) { $_.usage.last } else { [DateTimeOffset]::MinValue } }; Descending = $true }
    $y = 46
    $g.DrawString('模型', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 12, $y - 16)
    $g.DrawString('1h 输入峰值 / 上限', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 300, $y - 16)
    $g.DrawString('1h 调用', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 455, $y - 16)
    $g.DrawString('错误', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 520, $y - 16)
    $g.DrawString('平均延迟', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 565, $y - 16)
    $g.DrawString('最近一次', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 655, $y - 16)
    foreach ($r in $rows) {
        if ($y -gt $h - 22) { break }
        $u = $r.usage
        $ok = $true
        if ($u -and [int]$u.errors -gt 0) { $ok = $false }
        $dot = if (-not $u) { $script:C.gray } elseif ($ok) { $script:C.green } else { $script:C.red }
        $g.FillEllipse([System.Drawing.SolidBrush]::new($dot), 12, $y + 4, 8, 8)
        $name = $r.name
        if ($name.Length -gt 28) { $name = $name.Substring(0, 27) + '…' }
        $g.DrawString($name, $script:F.body, [System.Drawing.SolidBrush]::new($script:C.text), 26, $y)
        if ($u) {
            $calls = [int]$u.calls; $errsN = [int]$u.errors; $ms = if ([int]$u.msN -gt 0) { [int]($u.msSum / $u.msN) } else { 0 }
            $peak = [int]$u.maxIn; $cap = [int](Get-Prop $r 'cap' 0)
            if ($peak -gt 0) {
                $inText = if ($cap -gt 0) { (Format-Num $peak) + ' / ' + (Format-Num $cap) } else { Format-Num $peak }
                $inColor = if ($cap -gt 0 -and $peak -ge $cap * 0.8) { $script:C.amber } else { $script:C.text }
                $g.DrawString($inText, $script:F.body, [System.Drawing.SolidBrush]::new($inColor), 305, $y)
            }
            $g.DrawString([string]$calls, $script:F.body, [System.Drawing.SolidBrush]::new($script:C.text), 460, $y)
            $g.DrawString([string]$errsN, $script:F.body, [System.Drawing.SolidBrush]::new($(if ($errsN -gt 0) { $script:C.red } else { $script:C.muted })), 525, $y)
            if ($ms -gt 0) { $g.DrawString("$ms ms", $script:F.body, [System.Drawing.SolidBrush]::new($script:C.text), 570, $y) }
            $last = if ($u.last) { $u.last.ToLocalTime().ToString('HH:mm:ss') } else { '-' }
            $g.DrawString($last, $script:F.body, [System.Drawing.SolidBrush]::new($script:C.muted), 660, $y)
        } else {
            $g.DrawString('—', $script:F.body, [System.Drawing.SolidBrush]::new($script:C.gray), 305, $y)
        }
        $y += 22
    }
}

function Paint-Events {
    param($g, $w, $h)
    $g.Clear($script:C.panel)
    $g.DrawString('最近事件', $script:F.h2, [System.Drawing.SolidBrush]::new($script:C.text), 10, 8)
    $y = 34
    $events = @()
    if ($script:Status) { $events = @(Get-Prop $script:Status 'events' @()) }
    foreach ($e in ($events | Select-Object -Last 5)) {
        $type = [string](Get-Prop $e 'type' '')
        $color = switch ($type) { 'ok' { $script:C.green } 'rotate' { $script:C.accent } 'exhausted' { $script:C.amber } 'blocked' { $script:C.red } 'upstream5xx' { $script:C.amber } 'nodefail' { $script:C.red } 'recovered' { $script:C.green } default { $script:C.muted } }
        $t = [string](Get-Prop $e 't' '')
        if ($t.Length -ge 19) { $t = $t.Substring(11, 8) }
        $msg = [string](Get-Prop $e 'message' '')
        if ($msg.Length -gt 96) { $msg = $msg.Substring(0, 95) + '…' }
        $g.FillEllipse([System.Drawing.SolidBrush]::new($color), 12, $y + 4, 6, 6)
        $g.DrawString("$t  $msg", $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 24, $y)
        $y += 20
    }
    if ($events.Count -eq 0) { $g.DrawString('暂无事件', $script:F.small, [System.Drawing.SolidBrush]::new($script:C.muted), 24, $y) }
}

if ($SelfTest) {
    Update-Data
    if ($script:ErrorText) { Write-Host "自测失败：$($script:ErrorText)" -ForegroundColor Red; exit 1 }
    $bmp = [System.Drawing.Bitmap]::new(760, 760)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        Paint-Header -g $g -w 760
        Paint-Heat -g $g -w 760 -h 240
        Paint-Models -g $g -w 760 -h 420
        Paint-Events -g $g -w 760 -h 140
        Write-Host '面板绘制自测通过' -ForegroundColor Green
    } catch {
        Write-Host ("面板绘制失败：" + $_.Exception.Message) -ForegroundColor Red
        exit 1
    } finally {
        $g.Dispose(); $bmp.Dispose()
    }
    $t = Get-Prop $script:Status 'totals'
    Write-Host ("出口 IP 可用 {0}/{1}，请求 {2}，模型 {3} 个，使用记录 {4} 条" -f (Get-Prop $t 'usableIpCount' 0), (Get-Prop $t 'ipCount' 0), (Get-Prop $t 'requests' 0), @($script:Models).Count, $script:Usage.Count) -ForegroundColor Green
    exit 0
}

# single instance
$mutex = [System.Threading.Mutex]::new($false, 'Local\ZenDashboard')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Zen 状态面板'
$form.Width = 780
$form.Height = 820
$form.MinimumSize = [System.Drawing.Size]::new(720, 700)
$form.BackColor = $script:C.bg
$form.ForeColor = $script:C.text
$form.StartPosition = 'CenterScreen'
$form.Font = $script:F.body
$form.AutoScaleMode = 'Dpi'
$iconPath = Join-Path $script:DataDir 'icon.ico'
if (Test-Path -LiteralPath $iconPath) { try { $form.Icon = [System.Drawing.Icon]::new($iconPath) } catch {} }

$header = [System.Windows.Forms.Panel]::new()
$header.Dock = 'Top'; $header.Height = 100; $header.BackColor = $script:C.bg
$header.add_Paint({ param($s, $e) try { Paint-Header -g $e.Graphics -w $s.Width } catch { $e.Graphics.Clear($script:C.bg); $e.Graphics.DrawString(('绘制失败：' + $_.Exception.Message), $script:F.body, [System.Drawing.SolidBrush]::new($script:C.red), 12, 12) } })

$heat = [System.Windows.Forms.Panel]::new()
$heat.Dock = 'Top'; $heat.Height = 240; $heat.BackColor = $script:C.panel
$heat.add_Paint({ param($s, $e) try { Paint-Heat -g $e.Graphics -w $s.Width -h $s.Height } catch { $e.Graphics.Clear($script:C.panel); $e.Graphics.DrawString(('绘制失败：' + $_.Exception.Message), $script:F.body, [System.Drawing.SolidBrush]::new($script:C.red), 12, 12) } })

$models = [System.Windows.Forms.Panel]::new()
$models.Dock = 'Top'; $models.Height = 250; $models.BackColor = $script:C.panel
$models.add_Paint({ param($s, $e) try { Paint-Models -g $e.Graphics -w $s.Width -h $s.Height } catch { $e.Graphics.Clear($script:C.panel); $e.Graphics.DrawString(('绘制失败：' + $_.Exception.Message), $script:F.body, [System.Drawing.SolidBrush]::new($script:C.red), 12, 12) } })

$events = [System.Windows.Forms.Panel]::new()
$events.Dock = 'Top'; $events.Height = 140; $events.BackColor = $script:C.panel
$events.add_Paint({ param($s, $e) try { Paint-Events -g $e.Graphics -w $s.Width -h $s.Height } catch { $e.Graphics.Clear($script:C.panel); $e.Graphics.DrawString(('绘制失败：' + $_.Exception.Message), $script:F.body, [System.Drawing.SolidBrush]::new($script:C.red), 12, 12) } })

$bar = [System.Windows.Forms.FlowLayoutPanel]::new()
$bar.Dock = 'Bottom'; $bar.Height = 46; $bar.BackColor = $script:C.bg
$bar.FlowDirection = 'LeftToRight'; $bar.Padding = [System.Windows.Forms.Padding]::new(10, 8, 10, 8)

function New-Button {
    param([string]$Text, [scriptblock]$Click)
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $Text
    $b.Width = 100; $b.Height = 28
    $b.FlatStyle = 'Flat'
    $b.BackColor = $script:C.panel
    $b.ForeColor = $script:C.text
    $b.FlatAppearance.BorderColor = $script:C.line
    $b.add_Click($Click)
    return $b
}

$bar.Controls.Add((New-Button '换一个 IP' {
    try { Invoke-RestMethod -Method Post -Uri "$BaseUrl/rotate" -TimeoutSec 8 -NoProxy | Out-Null; Update-Data; $form.Invalidate($true) } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '换 IP 失败') }
})) | Out-Null
$bar.Controls.Add((New-Button '重新测速' {
    try { Invoke-RestMethod -Method Post -Uri "$BaseUrl/probe" -TimeoutSec 30 -NoProxy | Out-Null; Update-Data; $form.Invalidate($true) } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '测速失败') }
})) | Out-Null
$bar.Controls.Add((New-Button '刷新' { Update-Data; $form.Invalidate($true) })) | Out-Null
$bar.Controls.Add((New-Button '打开日志' { Start-Process notepad.exe (Join-Path $script:DataDir 'zen-router.log') })) | Out-Null

$form.Controls.Add($bar)
$form.Controls.Add($events)
$form.Controls.Add($models)
$form.Controls.Add($heat)
$form.Controls.Add($header)

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 5000
$timer.add_Tick({ Update-Data; $form.Invalidate($true) })

$form.add_Shown({ Update-Data; $form.Invalidate($true); $timer.Start() })
$form.add_FormClosed({ $timer.Stop(); $timer.Dispose() })

[void]$form.ShowDialog()
if ($owned) { $mutex.ReleaseMutex() }
$mutex.Dispose()