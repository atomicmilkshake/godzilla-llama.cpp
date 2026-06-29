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
| `WDK_ROOT` | `C:\Program Files (x86)\Windows Kits\10` | Windows SDK/WDK root if MSVC UCRT paths are needed |

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
```

## WSL parity (BitNet)

```bash
export GODZILLA_ROOT=/path/to/godzilla-llama.cpp
export MODELS_DIR=/path/to/models
export BITNET_REF_ROOT=/path/to/BitNet   # optional MS reference build
cd "$GODZILLA_ROOT"
pwsh.exe -File scripts/build_bitnet_cpu.ps1 -UseWsl
```

## Public reverse proxy

Point Caddy or nginx at `http://127.0.0.1:8090` (or your chosen port). Example host placeholder:

```
https://your-host.example.com {
    reverse_proxy 127.0.0.1:8090
}
```

Set `LLAMA_API_KEY` on the server and pass `Authorization: Bearer <key>` from clients.
