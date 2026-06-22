@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
set INCLUDE=%INCLUDE%;S:\WADK102\Include\10.0.26100.0\ucrt
set LIB=%LIB%;S:\WADK102\Lib\10.0.26100.0\ucrt\x64
cmake --build J:\LLM\godzilla-llama.cpp\build --target test-triattention-gpu-parity --config Release -j 8
exit /b %ERRORLEVEL%