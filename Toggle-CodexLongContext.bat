@echo off
setlocal
chcp 65001 >nul
title Codex Context Window Toggle

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Toggle-CodexLongContext.ps1"
set "toggleExitCode=%ERRORLEVEL%"
exit /b %toggleExitCode%
