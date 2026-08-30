@echo off
setlocal
chcp 65001 >nul 2>&1
title Codex Switch Tools

set "CST_SCRIPT=%~dp0Codex-Switch-Tools.ps1"
if not exist "%CST_SCRIPT%" (
  echo [ERROR] Missing helper: "%CST_SCRIPT%"
  pause
  exit /b 2
)

set "CST_ENGINE="
where pwsh.exe >nul 2>&1 && set "CST_ENGINE=pwsh.exe"
if not defined CST_ENGINE where powershell.exe >nul 2>&1 && set "CST_ENGINE=powershell.exe"
if not defined CST_ENGINE (
  echo [ERROR] PowerShell 5.1 or PowerShell 7 is required.
  pause
  exit /b 3
)

"%CST_ENGINE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CST_SCRIPT%" %*
set "CST_EXIT=%ERRORLEVEL%"
if not "%CST_EXIT%"=="0" (
  echo.
  echo [ERROR] Codex Switch Tools exited with code %CST_EXIT%.
  pause
)
exit /b %CST_EXIT%
