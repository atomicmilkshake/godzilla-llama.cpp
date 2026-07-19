@echo off
setlocal enabledelayedexpansion
REM =============================================================================
REM rebuild_incremental.cmd — ONE ninja build of llama-server + stage release-bin
REM Prefer this for src/tools/common edits. See docs\AGENT-BUILD-WORKFLOW.md
REM =============================================================================
cd /d "%~dp0.."
set "LOG=%cd%\build_king_incremental.log"
echo ==== INCREMENTAL REBUILD %DATE% %TIME% > "%LOG%"

REM Refuse if another build is running
tasklist /FI "IMAGENAME eq ninja.exe" 2>nul | find /I "ninja.exe" >nul
if not errorlevel 1 (
  echo [incremental] REFUSE: ninja.exe already running. Poll bootstrap --wait-build
  echo REFUSE_CONCURRENT >> "%LOG%"
  exit /b 40
)
tasklist /FI "IMAGENAME eq nvcc.exe" 2>nul | find /I "nvcc.exe" >nul
if not errorlevel 1 (
  echo [incremental] REFUSE: nvcc.exe already running.
  echo REFUSE_CONCURRENT >> "%LOG%"
  exit /b 41
)

if not exist "build-king\CMakeCache.txt" (
  echo [incremental] No build-king cache. Use rebuild_king.cmd instead.
  echo NO_CACHE >> "%LOG%"
  exit /b 42
)

call "%~dp0env-godzilla-msvc.cmd"
if errorlevel 1 (
  echo ENV_FAIL >> "%LOG%"
  exit /b 1
)

echo [incremental] cmake --build build-king --target llama-server llama-cli ...
cmake --build build-king --target llama-server --parallel >> "%LOG%" 2>&1
if errorlevel 1 (
  echo BUILD_FAIL >> "%LOG%"
  echo [incremental] BUILD_FAIL — see %LOG%
  exit /b 2
)
cmake --build build-king --target llama-cli --parallel >> "%LOG%" 2>&1
if errorlevel 1 (
  echo BUILD_FAIL_CLI >> "%LOG%"
  echo [incremental] BUILD_FAIL llama-cli — see %LOG%
  exit /b 2
)

echo [incremental] staging release-bin ...
where pwsh >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stage-release-bin.ps1" -RepoRoot "%cd%" -BuildBin "%cd%\build-king\bin" >> "%LOG%" 2>&1
) else (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0stage-release-bin.ps1" -RepoRoot "%cd%" -BuildBin "%cd%\build-king\bin" >> "%LOG%" 2>&1
)
if errorlevel 1 (
  echo STAGE_FAIL >> "%LOG%"
  echo [incremental] STAGE_FAIL
  exit /b 3
)

echo BUILD_OK %DATE% %TIME% >> "%LOG%"
echo [incremental] BUILD_OK → release-bin\llama-server.exe + llama-cli.exe
cd /d "%cd%\release-bin"
llama-server.exe --version
llama-cli.exe --version
exit /b 0
