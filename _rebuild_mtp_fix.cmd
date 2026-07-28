@echo off
setlocal
cd /d "%~dp0"
echo ==== MTP FIX REBUILD %DATE% %TIME% > build_king_mtp_fix.log
call "%~dp0scripts\env-godzilla-msvc.cmd"
if errorlevel 1 (
  echo ENV_FAIL >> build_king_mtp_fix.log
  exit /b 1
)
echo [mtp-fix] incremental build llama-server ...
cmake --build build-king --target llama-server --parallel >> build_king_mtp_fix.log 2>&1
if errorlevel 1 (
  echo BUILD_FAIL >> build_king_mtp_fix.log
  exit /b 2
)
echo [mtp-fix] staging release-bin ...
where pwsh >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stage-release-bin.ps1" -RepoRoot "%~dp0." -BuildBin "%~dp0build-king\bin" >> build_king_mtp_fix.log 2>&1
) else (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stage-release-bin.ps1" -RepoRoot "%~dp0." -BuildBin "%~dp0build-king\bin" >> build_king_mtp_fix.log 2>&1
)
if errorlevel 1 (
  echo STAGE_FAIL >> build_king_mtp_fix.log
  exit /b 3
)
echo BUILD_OK >> build_king_mtp_fix.log
echo [mtp-fix] BUILD_OK
exit /b 0
