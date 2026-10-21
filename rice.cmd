@echo off
setlocal
set "PS=%USERPROFILE%\.zen-ip\bin\pwsh\pwsh.exe"
if exist "%PS%" goto run
where pwsh >nul 2>nul
if not errorlevel 1 (
  set "PS=pwsh"
  goto run
)
echo 需要 PowerShell 7 ^(pwsh^)，请先安装 PowerShell 7。
exit /b 9009
:run
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0rice.ps1" %*
exit /b %errorlevel%
