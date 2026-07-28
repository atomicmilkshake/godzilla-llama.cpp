@echo off
setlocal
REM =============================================================================
REM rebuild_detached.cmd — start ONE long rebuild in a separate process
REM Survives agent/session exit. Log: build_king_detached.log
REM Poll: python scripts\agent_bootstrap_godzilla.py --wait-build
REM See docs\AGENT-BUILD-WORKFLOW.md
REM =============================================================================
cd /d "%~dp0.."

tasklist /FI "IMAGENAME eq ninja.exe" 2>nul | find /I "ninja.exe" >nul
if not errorlevel 1 (
  echo [detached] REFUSE: ninja already running
  exit /b 40
)
tasklist /FI "IMAGENAME eq nvcc.exe" 2>nul | find /I "nvcc.exe" >nul
if not errorlevel 1 (
  echo [detached] REFUSE: nvcc already running
  exit /b 41
)

set "WORKER=%cd%\scripts\_rebuild_detached_worker.cmd"
echo [detached] starting worker → build_king_detached.log
REM /MIN new console, independent of parent job when possible
start "godzilla-rebuild-detached" /MIN cmd /c "%WORKER%"
echo [detached] started. Poll with:
echo   python scripts\agent_bootstrap_godzilla.py --wait-build
exit /b 0
