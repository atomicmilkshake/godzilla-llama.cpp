@echo off
setlocal enabledelayedexpansion
REM =============================================================================
REM rebuild_king.cmd — Godzilla CUDA llama-server → release-bin (CLEAN full)
REM =============================================================================
REM Agents: prefer docs\AGENT-BUILD-WORKFLOW.md + scripts\agent_bootstrap_godzilla.py
REM   src-only → scripts\rebuild_incremental.cmd
REM   long/session-safe → scripts\rebuild_detached.cmd
REM   this file DELETES build-king and recompiles CUDA (slow)
REM DO NOT invent new library paths. Shared env + full writeup:
REM   scripts\env-godzilla-msvc.cmd
REM   docs\WINDOWS-BUILD-TOOLCHAIN.md
REM   docs\AGENT-BUILD-WORKFLOW.md
REM   docs\LOCAL-SETUP.example.md
REM   GODZILLA_KING.md
REM
REM Classic failure without UCRT prepend: LNK1104 cannot open file 'ucrtd.lib'
REM NEVER run a second ninja while this is active.
REM =============================================================================

cd /d "%~dp0"
echo ==== GODZILLA KING REBUILD %DATE% %TIME% > build_king_rebuild.log

call "%~dp0scripts\env-godzilla-msvc.cmd"
if errorlevel 1 (
  echo ENV_FAIL >> build_king_rebuild.log
  echo See docs\WINDOWS-BUILD-TOOLCHAIN.md
  exit /b 1
)

set "CUDA_ARCH=86"
if not "%~1"=="" set "CUDA_ARCH=%~1"

if exist build-king rmdir /s /q build-king
mkdir build-king

echo [rebuild_king] cmake configure CUDA arch=%CUDA_ARCH% ...
cmake -S . -B build-king -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_CUDA=ON ^
  -DCMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH% ^
  -DLLAMA_BUILD_SERVER=ON ^
  -DGGML_NATIVE=OFF ^
  -DGGML_CCACHE=OFF ^
  > build_king_cmake.log 2>&1
if errorlevel 1 (
  echo CMAKE_FAIL >> build_king_rebuild.log
  echo [rebuild_king] cmake failed — see build_king_cmake.log
  echo Tip: LNK1104 ucrtd.lib = UCRT not prepended. Read docs\WINDOWS-BUILD-TOOLCHAIN.md
  exit /b 1
)

echo [rebuild_king] building llama-server and llama-cli ...
cmake --build build-king --target llama-server llama-cli --parallel > build_king_build.log 2>&1
if errorlevel 1 (
  echo BUILD_FAIL >> build_king_rebuild.log
  echo [rebuild_king] build failed — see build_king_build.log
  exit /b 1
)

if not exist build-king\bin\llama-server.exe if not exist build-king\llama-server.exe (
  echo NO_EXE >> build_king_rebuild.log
  exit /b 2
)

REM Stage self-contained release-bin (OpenSSL + CUDA bin\x64 + PE check + clean-PATH smoke).
REM Do NOT hand-copy a partial DLL set — that causes DLL-not-found message boxes.
where pwsh >nul 2>&1
if errorlevel 1 (
  echo [rebuild_king] pwsh missing — falling back to scripts\stage-release-bin.ps1 via powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stage-release-bin.ps1" -RepoRoot "%~dp0." -BuildBin "%~dp0build-king\bin"
) else (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stage-release-bin.ps1" -RepoRoot "%~dp0." -BuildBin "%~dp0build-king\bin"
)
if errorlevel 1 (
  echo STAGE_FAIL >> build_king_rebuild.log
  echo [rebuild_king] stage-release-bin failed — release package incomplete
  exit /b 3
)

echo BUILD_OK >> build_king_rebuild.log
echo [rebuild_king] BUILD_OK → release-bin\llama-server.exe
echo Runtime: cwd must be release-bin (DLL pack). Preflight: scripts\check-release-bin-deps.py
exit /b 0
