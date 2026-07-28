@echo off
REM Optional UCRT paths when WDK_ROOT is set (see docs/LOCAL-SETUP.example.md).
if defined WDK_ROOT (
  set INCLUDE=%INCLUDE%;%WDK_ROOT%\Include\10.0.26100.0\ucrt
  set LIB=%LIB%;%WDK_ROOT%\Lib\10.0.26100.0\ucrt\x64
)
