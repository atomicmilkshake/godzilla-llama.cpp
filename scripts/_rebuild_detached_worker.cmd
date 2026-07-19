@echo off
setlocal
cd /d "%~dp0.."
set "LOG=%cd%\build_king_detached.log"
echo ==== DETACHED REBUILD %DATE% %TIME% > "%LOG%"

call "%~dp0env-godzilla-msvc.cmd" >> "%LOG%" 2>&1
if errorlevel 1 (
  echo ENV_FAIL >> "%LOG%"
  exit /b 1
)

if not exist "build-king\CMakeCache.txt" (
  echo [detached] no cache — running full rebuild_king path via cmake configure
  if exist build-king rmdir /s /q build-king
  mkdir build-king
  cmake -S . -B build-king -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_BUILD_SERVER=ON -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF >> "%LOG%" 2>&1
  if errorlevel 1 (
    echo CMAKE_FAIL >> "%LOG%"
    exit /b 1
  )
)

echo [detached] building llama-server ... >> "%LOG%"
cmake --build build-king --target llama-server --parallel >> "%LOG%" 2>&1
if errorlevel 1 (
  echo BUILD_FAIL >> "%LOG%"
  exit /b 2
)

echo [detached] staging ... >> "%LOG%"
where pwsh >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stage-release-bin.ps1" -RepoRoot "%cd%" -BuildBin "%cd%\build-king\bin" >> "%LOG%" 2>&1
) else (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0stage-release-bin.ps1" -RepoRoot "%cd%" -BuildBin "%cd%\build-king\bin" >> "%LOG%" 2>&1
)
if errorlevel 1 (
  echo STAGE_FAIL >> "%LOG%"
  exit /b 3
)

echo BUILD_OK %DATE% %TIME% >> "%LOG%"
exit /b 0
