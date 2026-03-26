@echo off
REM ralph.cmd - Windows CMD wrapper for Ralph (Issue #156)
REM Delegates to ralph.ps1 which handles WSL/Git Bash detection.
REM Usage: ralph --live, ralph --version, ralph --monitor, etc.

REM Try PowerShell (pwsh) first, then fall back to Windows PowerShell
where pwsh >nul 2>&1
if %ERRORLEVEL% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0ralph.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ralph.ps1" %*
)
exit /b %ERRORLEVEL%
