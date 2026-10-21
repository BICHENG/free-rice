# free-rice uninstall
[CmdletBinding()]
param([switch]$Purge, [switch]$KeepGateway)
if ($env:ZEN_IP_HOME) { $DataDir = $env:ZEN_IP_HOME } else { $DataDir = Join-Path $env:USERPROFILE '.zen-ip' }
$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$h = [regex]::Escape($DataDir)
Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -and (
        ($_.Name -eq 'node.exe' -and $_.CommandLine -match ($h + '.*(zen-supervisor|zen-router)\.mjs')) -or
        ($_.Name -eq 'mihomo.exe' -and $_.CommandLine -like ('*' + $DataDir + '*')) -or
        ((-not $KeepGateway) -and $_.Name -eq 'magpie.exe' -and ($_.CommandLine -like ('*' + $DataDir + '*') -or $_.ExecutablePath -like ($DataDir + '*'))) -or
        ($_.Name -eq 'pwsh.exe' -and $_.CommandLine -like ('*' + $DataDir + '*zen-tray.ps1*'))
    )
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (-not $KeepGateway) {
    $magpie = Join-Path $DataDir 'bin\magpie.exe'
    if (Test-Path -LiteralPath $magpie) { Get-Process magpie -ErrorAction SilentlyContinue | Stop-Process -Force }
} else { Write-Host '保留 magpie 网关' }
foreach ($n in 'free-rice-start.vbs', 'free-rice-tray.vbs', 'zen-router.vbs', 'zen-tray.vbs') {
    $p = Join-Path $startup $n
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($n in 'free-rice', 'free-rice-tray') {
    if (Test-Path $key) { Remove-ItemProperty -Path $key -Name $n -ErrorAction SilentlyContinue }
}
$menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\free-rice'
if (Test-Path -LiteralPath $menu) { Remove-Item -LiteralPath $menu -Recurse -Force }
Write-Host '已停止进程并移除启动项'
if ($Purge) {
    if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
    Write-Host ('已删除数据目录 ' + $DataDir)
} else {
    Write-Host ('数据目录保留: ' + $DataDir + '（加 -Purge 删除）')
}
