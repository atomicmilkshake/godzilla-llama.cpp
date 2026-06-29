# Local setup (example)

Copy this file to a private location (or export variables in your shell profile). **Do not commit real paths or secrets.**

## Directory layout

| Variable | Example (Windows) | Purpose |
|----------|-------------------|---------|
| `GODZILLA_ROOT` | `C:\dev\godzilla-llama.cpp` | Clone of this repository |
| `MODELS_DIR` | `D:\models` | GGUF model weights |
| `TRIATTENTION_CALIB_DIR` | `%GODZILLA_ROOT%\calibrations` | `.triattention` calibration files |
| `BITNET_REF_ROOT` | `C:\dev\BitNet` | Optional Microsoft BitNet reference clone (P0 parity) |
| `SOMS_ROOT` | `C:\dev\soms` | Optional benchmark harness (hot-rod certification) |
| `WSL_GODZILLA_ROOT` | `/mnt/c/dev/godzilla-llama.cpp` | WSL path to `GODZILLA_ROOT` |
| `WDK_ROOT` | `C:\Program Files (x86)\Windows Kits\10` | **Required for CUDA builds on VS18** when `stddef.h` is missing from default MSVC INCLUDE paths; also pass as `-SdkRoot` to `scripts/build_cuda.ps1` |

## TriAttention auto-calibration

| Variable | Purpose |
|----------|---------|
| `TRIATTENTION_PYTHON` | Python executable with `torch` + deps (venv) |
| `TRIATTENTION_CALIBRATE_PY` | Path to `calibrate-triattention.py` (or workspace calibrator) |
| `LLAMA_ENSURE_TRIATTENTION_SCRIPT` | Path to `scripts/ensure-triattention.ps1` (C++ auto-cal hook) |
| `HF_HOME` | Hugging Face cache directory (large checkpoints) |

## Server / API (optional)

| Variable | Purpose |
|----------|---------|
| `LLAMA_API_KEY` | `llama-server --api-key` / Bearer auth |
| `HF_TOKEN` | Hugging Face downloads (`--hf-token`) |
| `POE_API_KEY` | External integrations only — never commit |
| `BENCHMARK_WATCH_SCRIPT` | Optional path to benchmark watchdog script (hot-rod harness) |
| `GODZILLA_OPERATOR_JOURNAL` | Optional private journal path (autopilot scripts) |

## PowerShell profile snippet

```powershell
$env:GODZILLA_ROOT = "C:\dev\godzilla-llama.cpp"
$env:MODELS_DIR = "D:\models"
$env:TRIATTENTION_CALIB_DIR = "$env:GODZILLA_ROOT\calibrations"
$env:LLAMA_ENSURE_TRIATTENTION_SCRIPT = "$env:GODZILLA_ROOT\scripts\ensure-triattention.ps1"
# $env:WSL_GODZILLA_ROOT = "/mnt/c/dev/godzilla-llama.cpp"
# $env:WDK_ROOT = "C:\Program Files (x86)\Windows Kits\10"   # VS18 CUDA builds
```

## Windows CUDA build (VS18 / missing stddef.h)

`scripts/build_cuda.ps1` fails fast when `stddef.h` is not on the MSVC INCLUDE path after `vcvars64`. Set `WDK_ROOT` to the Windows Kits 10 install root (same path as `-SdkRoot`):

```powershell
$env:WDK_ROOT = "C:\Program Files (x86)\Windows Kits\10"
pwsh -File scripts/build_cuda.ps1 -Target llama-server
```

GitHub Actions can supply the same path via the `WDK_ROOT` repository secret (see `.github/workflows/kv-god-ctest.yml`).

## WSL parity (BitNet)

```bash
export GODZILLA_ROOT=/path/to/godzilla-llama.cpp
export MODELS_DIR=/path/to/models
export BITNET_REF_ROOT=/path/to/BitNet   # optional MS reference build
export WSL_GODZILLA_ROOT=/path/to/godzilla-llama.cpp   # native WSL path (required for build_bitnet_cpu.ps1 -UseWsl)
cd "$GODZILLA_ROOT"
pwsh.exe -File scripts/build_bitnet_cpu.ps1 -UseWsl
```

## Operator launcher template (outside this repo)

Keep workspace `start-*.bat` files **local** (not committed). Dot-source `godzilla-paths.ps1` via PowerShell env vars set in your profile:

```bat
@echo off
setlocal
title BitNet b1.58-2B-4T I2_S (Godzilla) - Port 8090

if not defined GODZILLA_ROOT (
  echo Set GODZILLA_ROOT and MODELS_DIR in your PowerShell profile. See docs/LOCAL-SETUP.example.md
  exit /b 1
)
if not defined MODELS_DIR (
  echo MODELS_DIR is not set. See docs/LOCAL-SETUP.example.md
  exit /b 1
)

set "BINDIR=%GODZILLA_ROOT%\build-bitnet-cpu\bin"
set "MODEL=%MODELS_DIR%\bitnet-b1.58-2B-4T\ggml-model-i2_s.gguf"

if not exist "%MODEL%" (
  if defined BITNET_REF_ROOT if exist "%BITNET_REF_ROOT%\models\BitNet-b1.58-2B-4T\ggml-model-i2_s.gguf" (
    set "MODEL=%BITNET_REF_ROOT%\models\BitNet-b1.58-2B-4T\ggml-model-i2_s.gguf"
  ) else (
    echo Model not found. Run: pwsh -File "%GODZILLA_ROOT%\scripts\fetch-bitnet-model.ps1"
    exit /b 1
  )
)

if exist "%BINDIR%\llama-server.exe" (
  cd /d "%BINDIR%"
  llama-server.exe -m "%MODEL%" -c 4096 -ngl 0 --fit off --no-warmup --host 0.0.0.0 --port 8090 --parallel 1 --alias "BitNet 2B,Godzilla" --jinja
  exit /b %ERRORLEVEL%
)

if not defined WSL_GODZILLA_ROOT (
  for /f "delims=" %%P in ('wsl wslpath -u "%GODZILLA_ROOT%" 2^>nul') do set "WSL_GODZILLA_ROOT=%%P"
)
if not defined WSL_GODZILLA_ROOT (
  echo Set WSL_GODZILLA_ROOT or install WSL wslpath. See docs/LOCAL-SETUP.example.md
  exit /b 1
)

for /f "delims=" %%M in ('wsl wslpath -u "%MODEL%"') do set "WSL_MODEL=%%M"
wsl -e bash -lc "cd '%WSL_GODZILLA_ROOT%/build-bitnet-cpu/bin' && ./llama-server -m '%WSL_MODEL%' -c 4096 -ngl 0 --fit off --no-warmup --host 0.0.0.0 --port 8090 --parallel 1 --alias 'BitNet 2B,Godzilla' --jinja"
```

## Public reverse proxy

Point Caddy or nginx at `http://127.0.0.1:8090` (or your chosen port). Example host placeholder:

```
https://your-host.example.com {
    reverse_proxy 127.0.0.1:8090
}
```

Set `LLAMA_API_KEY` on the server and pass `Authorization: Bearer <key>` from clients.
