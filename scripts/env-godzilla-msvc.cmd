@echo off
REM =============================================================================
REM env-godzilla-msvc.cmd — SHARED MSVC + UCRT + CUDA env for Godzilla builds
REM =============================================================================
REM CALL this from other scripts:  call "%~dp0env-godzilla-msvc.cmd"
REM Full docs: docs\WINDOWS-BUILD-TOOLCHAIN.md  and  docs\LOCAL-SETUP.example.md
REM
REM ROOT CAUSE (do not re-debug):
REM   VS18 vcvars finds S:\WADK102 um/shared but NOT ucrt on INCLUDE/LIB.
REM   That yields LNK1104 ucrtd.lib / C1083 corecrt.h on every fresh cmake.
REM   FIX: after vcvars, PREPEND UCRT include+lib (never wipe MSVC paths).
REM =============================================================================

if defined GODZILLA_MSVC_ENV_READY (
  if "%GODZILLA_MSVC_ENV_READY%"=="1" goto :eof
)

set "GODZILLA_VCVARS="
if exist "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" (
  set "GODZILLA_VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
  set "GODZILLA_VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" (
  set "GODZILLA_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
)

if not defined GODZILLA_VCVARS (
  echo [env-godzilla-msvc] ERROR: vcvars64.bat not found. Install VS C++ workload.
  exit /b 90
)

call "%GODZILLA_VCVARS%" >nul 2>&1
if errorlevel 1 (
  echo [env-godzilla-msvc] ERROR: vcvars64 failed: %GODZILLA_VCVARS%
  exit /b 91
)

REM --- WDK / Windows kit root (UCRT lives here on this lab) ---
if not defined WDK_ROOT (
  if exist "S:\WADK102\Include\10.0.26100.0\ucrt\corecrt.h" set "WDK_ROOT=S:\WADK102"
)
if not defined WDK_ROOT (
  if exist "C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\ucrt\corecrt.h" set "WDK_ROOT=C:\Program Files (x86)\Windows Kits\10"
)
if not defined WDK_ROOT (
  if exist "C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\ucrt\corecrt.h" set "WDK_ROOT=C:\Program Files (x86)\Windows Kits\10"
)

if not defined WDK_ROOT (
  echo [env-godzilla-msvc] ERROR: WDK_ROOT not found. Set WDK_ROOT to kit root containing Include\^<ver^>\ucrt\corecrt.h
  echo   Lab default: set WDK_ROOT=S:\WADK102
  echo   See docs\WINDOWS-BUILD-TOOLCHAIN.md
  exit /b 92
)

set "WDK_VER="
if exist "%WDK_ROOT%\Include\10.0.26100.0\ucrt\corecrt.h" set "WDK_VER=10.0.26100.0"
if not defined WDK_VER if exist "%WDK_ROOT%\Include\10.0.22621.0\ucrt\corecrt.h" set "WDK_VER=10.0.22621.0"
if not defined WDK_VER if exist "%WDK_ROOT%\Include\10.0.22000.0\ucrt\corecrt.h" set "WDK_VER=10.0.22000.0"
if not defined WDK_VER (
  echo [env-godzilla-msvc] ERROR: no known UCRT version under "%WDK_ROOT%\Include"
  exit /b 93
)

if not exist "%WDK_ROOT%\Lib\%WDK_VER%\ucrt\x64\ucrtd.lib" (
  echo [env-godzilla-msvc] ERROR: missing ucrtd.lib under "%WDK_ROOT%\Lib\%WDK_VER%\ucrt\x64"
  echo   This is the LNK1104 failure mode. Fix WDK_ROOT / kit install.
  exit /b 94
)

set "WindowsSdkDir=%WDK_ROOT%\"
set "WindowsSDKVersion=%WDK_VER%\"
set "UniversalCRTSdkDir=%WDK_ROOT%\"
set "UCRTVersion=%WDK_VER%"

REM PREPEND (critical) — keep MSVC vcruntime paths from vcvars
set "INCLUDE=%WDK_ROOT%\Include\%WDK_VER%\ucrt;%WDK_ROOT%\Include\%WDK_VER%\um;%WDK_ROOT%\Include\%WDK_VER%\shared;%INCLUDE%"
set "LIB=%WDK_ROOT%\Lib\%WDK_VER%\ucrt\x64;%WDK_ROOT%\Lib\%WDK_VER%\um\x64;%LIB%"
set "PATH=%WDK_ROOT%\bin\%WDK_VER%\x64;%PATH%"

REM --- CUDA (lab pin: 13.2) ---
if not defined CUDA_PATH (
  if exist "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin\nvcc.exe" (
    set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2"
  )
)
if defined CUDA_PATH set "PATH=%CUDA_PATH%\bin;%PATH%"

set "GODZILLA_MSVC_ENV_READY=1"
echo [env-godzilla-msvc] OK vcvars + UCRT %WDK_VER% from %WDK_ROOT%
if defined CUDA_PATH echo [env-godzilla-msvc] CUDA_PATH=%CUDA_PATH%
exit /b 0
