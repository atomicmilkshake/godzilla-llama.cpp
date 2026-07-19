# Godzilla Windows build toolchain (lab pin)

**Read this before any CMake/MSVC rebuild.**  
This lab hits the same library wild-goose chase every time if you skip it.

**Agents:** start here → [`docs/AGENT-BUILD-WORKFLOW.md`](AGENT-BUILD-WORKFLOW.md)  
then run: `python scripts\agent_bootstrap_godzilla.py`

### Reliable rebuild commands (pick one)

| Situation | Command |
|-----------|---------|
| **Src-only fix** (preferred) | `scripts\rebuild_incremental.cmd` |
| **Long / may disconnect** | `scripts\rebuild_detached.cmd` then `python scripts\agent_bootstrap_godzilla.py --wait-build` |
| **Nuke + full CUDA** | `rebuild_king.cmd` |

**Rules:** one ninja only · never kill mid-CUDA · always `stage-release-bin.ps1` · cwd=`release-bin` at runtime.

Canonical clean rebuild:

```bat
J:\LLM\engines\godzilla-llama.cpp\rebuild_king.cmd
```

Or PowerShell (preferred long-term):

```powershell
$env:WDK_ROOT = 'S:\WADK102'   # only if not auto-detected
pwsh -File J:\LLM\engines\godzilla-llama.cpp\scripts\build_cuda.ps1 `
  -Target llama-server -CudaArch 86 -Reconfigure -Clean
```

Also mirrored in:

| Location | Why |
|----------|-----|
| `docs/WINDOWS-BUILD-TOOLCHAIN.md` | **This file — UCRT / pin truth** |
| `docs/AGENT-BUILD-WORKFLOW.md` | **Agent reliable workflow + MTP fix** |
| `scripts/agent_bootstrap_godzilla.py` | Live status + recommended action |
| `scripts/rebuild_incremental.cmd` | Safe single ninja + stage |
| `scripts/rebuild_detached.cmd` | Session-surviving rebuild |
| `docs/LOCAL-SETUP.example.md` | Env vars + profile snippet |
| `GODZILLA_KING.md` | Product/engine policy + link here |
| `rebuild_king.cmd` | Clean full rebuild bootstrap |
| `scripts/env-godzilla-msvc.cmd` | Shared `call`able env for all `.cmd` builds |
| `scripts/godzilla-paths.ps1` | Auto-detect WDK / paths for PS1 |
| `scripts/build_cuda.ps1` | Full CUDA configure+build |
| `X:\My Drive\VandelayNexus\docs\GODZILLA-BUILD.md` | Product-side pointer |
| `J:\LLM\engines\BUILD-WINDOWS.md` | Lab engines umbrella |
| `C:\Users\owenm\.grok\Agents.md` | Agent global reminder |

---

## Root cause (do not re-discover)

On this machine, **VS 18 `vcvars64.bat` finds `S:\WADK102` for `um` / `shared` but does NOT put UCRT on `INCLUDE` / `LIB`.**

After bare `vcvars64`:

| Var | Has MSVC | Has WADK `um` | Has WADK **`ucrt`** |
|-----|----------|---------------|----------------------|
| `INCLUDE` | yes | yes | **NO** |
| `LIB` | yes | yes | **NO** |

Symptoms:

| Error | Meaning | Fix |
|-------|---------|-----|
| `LNK1104: cannot open file 'ucrtd.lib'` | Debug CRT link (CMake try_compile) cannot find UCRT libs | **Prepend** `...\Lib\10.0.26100.0\ucrt\x64` to `LIB` |
| `LNK1104: cannot open file 'ucrt.lib'` | Same, Release | Same path with `ucrt.lib` |
| `C1083: cannot open include file: 'stddef.h'` / `corecrt.h` | UCRT headers missing from `INCLUDE` | **Prepend** `...\Include\10.0.26100.0\ucrt` |
| `C1083: cannot open include file: 'vcruntime.h'` | You **overwrote** `INCLUDE` instead of prepending | Keep MSVC includes; only prepend UCRT/SDK |

**Always prepend UCRT after vcvars. Never replace the whole INCLUDE/LIB.**

Verified working pattern (2026-07-14):

```bat
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
set "WindowsSdkDir=S:\WADK102\"
set "WindowsSDKVersion=10.0.26100.0\"
set "UniversalCRTSdkDir=S:\WADK102\"
set "UCRTVersion=10.0.26100.0"
set "INCLUDE=S:\WADK102\Include\10.0.26100.0\ucrt;S:\WADK102\Include\10.0.26100.0\um;S:\WADK102\Include\10.0.26100.0\shared;%INCLUDE%"
set "LIB=S:\WADK102\Lib\10.0.26100.0\ucrt\x64;S:\WADK102\Lib\10.0.26100.0\um\x64;%LIB%"
set "PATH=S:\WADK102\bin\10.0.26100.0\x64;C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin;%PATH%"
```

CMake configure with Ninja + CUDA 13.2 + `sm_86` succeeds after this.

---

## Pinned tool paths (this lab)

| Component | Path / version |
|-----------|----------------|
| Visual Studio | **18** Community (`VS 2022` bat may be absent) |
| vcvars | `C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat` |
| MSVC toolset | `14.51.36231` (under `VC\Tools\MSVC\`) |
| Windows ADK / kits root | **`S:\WADK102`** (not under `C:\Program Files (x86)\Windows Kits\10` for UCRT) |
| SDK / UCRT version | **`10.0.26100.0`** |
| UCRT headers | `S:\WADK102\Include\10.0.26100.0\ucrt` (`corecrt.h`, `stddef.h`) |
| UCRT libs | `S:\WADK102\Lib\10.0.26100.0\ucrt\x64` (`ucrt.lib`, **`ucrtd.lib`**) |
| UM libs | `S:\WADK102\Lib\10.0.26100.0\um\x64` |
| rc.exe / mt.exe | `S:\WADK102\bin\10.0.26100.0\x64\` |
| CUDA | **`v13.2`** — `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2` |
| nvcc | `...\CUDA\v13.2\bin\nvcc.exe` |
| GPU arch | **`86`** (RTX 3080 10GB) |
| CMake | `C:\Program Files\CMake\bin\cmake.exe` |
| Ninja | `C:\ProgramData\chocolatey\bin\ninja.exe` |
| OpenSSL (optional, found by CMake) | `C:\Program Files\OpenSSL-Win64` |

Env overrides (optional if auto-detect fails):

```text
WDK_ROOT=S:\WADK102
CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2
GODZILLA_ROOT=J:\LLM\engines\godzilla-llama.cpp
```

---

## Required packages (install once)

1. **Visual Studio 18** (or 2022) with **Desktop development with C++**
2. **Windows 11 SDK / ADK bits** providing UCRT 10.0.26100.0 — this lab stores them at `S:\WADK102`
3. **CUDA Toolkit 13.2** matching the driver
4. **CMake** ≥ 3.28 and **Ninja**
5. GPU driver supporting CUDA 13.2

Standard `C:\Program Files (x86)\Windows Kits\10` may exist for *some* kit versions but **UCRT for link may still only live on `S:\WADK102`** — always check for `ucrtd.lib` there first.

---

## CMake flags (king / server)

```bat
cmake -S . -B build-king -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_CUDA=ON ^
  -DCMAKE_CUDA_ARCHITECTURES=86 ^
  -DLLAMA_BUILD_SERVER=ON ^
  -DGGML_NATIVE=OFF ^
  -DGGML_CCACHE=OFF
cmake --build build-king --target llama-server --parallel
```

Staging: copy `build-king\bin\llama-server.exe` + `*.dll` → `release-bin\`, plus CUDA runtime DLLs (`cudart64_*.dll`, `cublas64_*.dll`, `cublasLt64_*.dll`) from the CUDA bin dir if not already present.

**Runtime:** always start `llama-server` with **cwd = directory of the exe** (thin loaders + companion DLLs).

---

## Smoke checks (before a multi-hour CUDA build)

```bat
call scripts\env-godzilla-msvc.cmd
where cl
where nvcc
where cmake
where ninja
dir "%WDK_ROOT%\Lib\10.0.26100.0\ucrt\x64\ucrtd.lib"
cl /nologo /MDd t.c   :: must link ucrtd.lib
```

Quick compile probe: if `cl /MDd` of a hello-world fails with LNK1104, **stop** — env is wrong; do not start full CUDA.

---

## Release packaging (DLL message boxes)

After a successful build, **`scripts/stage-release-bin.ps1`** (called by `rebuild_king.cmd`) must stage a **self-contained** `release-bin\`:

| Required beside `llama-server.exe` | Source |
|------------------------------------|--------|
| `llama-server-impl.dll`, `llama.dll`, `llama-common.dll`, `mtmd.dll`, `ggml*.dll` | `build-king\bin\` |
| `libssl-4-x64.dll`, `libcrypto-4-x64.dll` | `C:\Program Files\OpenSSL-Win64\bin\` |
| `cudart64_13.dll`, `cublas64_13.dll`, **`cublasLt64_13.dll`** | CUDA **`bin\x64`** (13.2 layout) *and/or* `bin\` |

**Classic fail:** only copying `bin\*.dll` from CUDA — on toolkit 13.2, `cublasLt64_13.dll` lives under **`CUDA\v13.2\bin\x64\`**, not `bin\`.  
Missing it → `STATUS_DLL_NOT_FOUND` (`0xC0000135`, exit `-1073741515`) and Windows DLL dialogs.

Verify:

```bat
python scripts\check-release-bin-deps.py --dir release-bin --exe llama-server.exe
REM clean PATH smoke (no OpenSSL/CUDA on PATH):
set PATH=C:\Windows\System32;C:\Windows
cd /d release-bin
llama-server.exe --version
```

VandelayNexus runs the same checks on **every serve** (`package_health.preflight_binary`) and refuses to start if the package is incomplete — diagnostics go to `data/logs/package-preflight-*.json`.

## Anti-patterns (repeat offenders)

1. Calling bare `vcvars64` and assuming UCRT is complete  
2. Setting `INCLUDE=S:\WADK102\...` **without** keeping MSVC `vcruntime.h` paths  
3. Appending UCRT **after** broken empty LIB and expecting CMake try_compile to work — **prepend**  
4. Pointing only at `C:\Program Files (x86)\Windows Kits\10` when UCRT lives on `S:\WADK102`  
5. Building with CUDA 13.3 path when only **13.2** is installed  
6. Forgetting `sm_86` (wrong arch → wrong GPU binary)  
7. Running `llama-server.exe` with cwd elsewhere → missing `ggml-cuda.dll` / impl DLLs  
8. Shipping release-bin without OpenSSL / `cublasLt` → DLL message box cascade  
9. Looking only in `CUDA\bin` and ignoring `CUDA\bin\x64` (CUDA 13.2)  
10. **Two concurrent `ninja` / `cmake --build` on `build-king`** (races, dirty CUDA graph, multi-hour thrash)  
11. **Killing a mid-CUDA rebuild** (leaves hundreds of template objs dirty)  
12. Trusting “BUILD_OK” without checking `.obj` / `release-bin\llama.dll` mtimes vs sources  

---

## Related product behavior

- VandelayNexus engine id `godzilla` → `release-bin\llama-server.exe`
- TriAttention calibration is **auto** on serve (not a separate operator wizard)
- Rebuild after pulling king-of-forks merges; do not rely on foreign thin PE releases for Godzilla
- Qwen3.5/3.6 MTP gate fix + agent workflow: `docs/AGENT-BUILD-WORKFLOW.md`

Last verified: **2026-07-17** (UCRT pin still required; agent workflow + MTP `n_layer_nextn` fix documented).
