
@echo off
call "J:\LLM\engines\godzilla-llama.cpp\scripts\env-godzilla-msvc.cmd"
if errorlevel 1 exit /b 1
cmake --build "J:\LLM\engines\godzilla-llama.cpp\build-king" --target llama-server --parallel
if errorlevel 1 exit /b 2
where pwsh >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "J:\LLM\engines\godzilla-llama.cpp\scripts\stage-release-bin.ps1" -RepoRoot "J:\LLM\engines\godzilla-llama.cpp" -BuildBin "J:\LLM\engines\godzilla-llama.cpp\build-king\bin"
) else (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "J:\LLM\engines\godzilla-llama.cpp\scripts\stage-release-bin.ps1" -RepoRoot "J:\LLM\engines\godzilla-llama.cpp" -BuildBin "J:\LLM\engines\godzilla-llama.cpp\build-king\bin"
)
exit /b %ERRORLEVEL%
