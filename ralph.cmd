@echo off
REM ralph.cmd - Windows wrapper for Ralph (runs via WSL)
REM Place this file in a directory on your PATH to invoke Ralph from PowerShell or CMD.
REM Usage: ralph --live, ralph --version, ralph --monitor, etc.
wsl ralph %*
