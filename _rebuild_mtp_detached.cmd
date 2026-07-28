@echo off
cd /d J:\LLM\engines\godzilla-llama.cpp
echo START %DATE% %TIME% > build_king_mtp_fix_final.log
call scripts\env-godzilla-msvc.cmd >> build_king_mtp_fix_final.log 2>&1
if errorlevel 1 (
  echo ENV_FAIL >> build_king_mtp_fix_final.log
  exit /b 1
)
cmake --build build-king --target llama-server --parallel >> build_king_mtp_fix_final.log 2>&1
if errorlevel 1 (
  echo BUILD_FAIL %ERRORLEVEL% >> build_king_mtp_fix_final.log
  exit /b 2
)
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\stage-release-bin.ps1 -RepoRoot . -BuildBin build-king\bin >> build_king_mtp_fix_final.log 2>&1
if errorlevel 1 (
  echo STAGE_FAIL >> build_king_mtp_fix_final.log
  exit /b 3
)
echo BUILD_OK %DATE% %TIME% >> build_king_mtp_fix_final.log
