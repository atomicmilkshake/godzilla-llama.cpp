# Godzilla — king of the monsters

Godzilla is the **lab integration engine**: not a pure upstream, but the fork that is supposed to carry the **best innovations** from the other llama.cpp-class trees under `J:\LLM\engines`.

## Innovation map (source truth)

| Innovation | Origin forks | In Godzilla tree? | Notes |
|------------|--------------|-------------------|--------|
| **TriAttention** (KV eviction + CLI) | buun-llama-cpp | **Yes** (`--triattention-stats`, GPU scorers, calibrate file) | **Auto-calibrated by VandelayNexus** on serve — not a manual bolt-on |
| **TurboQuant / TURBO2/3/4 + TCQ** KV types | buun, atomic, TheTom, johndpope | **Yes** (GGML_TYPE_TURBO*, CUDA templates) | Quant path depends on model + flags |
| **dFlash** hooks | experimental / buun lineage | **Yes** (CUDA dflash markers) | Enable when recipe/cap requests |
| **Gemma4 / NEXTN / assistant tensors** | beellama / modern llama.cpp | **Yes** (recent godzilla commits) | |
| **SWA / ik normalize guards** | ik_llama.cpp | Partial / monitor when rebasing | Pull carefully on merge |
| **Stock llama.cpp HEAD** | ggml-org/llama.cpp | Via `llama-org` remote | Rebase/merge regularly |
| **MTP / draft** | various | Server draft path when present | Pair with MTP GGUF in recipe |

Remotes already wired on this repo:

- `origin` — atomicmilkshake/godzilla-llama.cpp  
- `llama-org` — ggml-org/llama.cpp  
- `beellama-upstream` / `upstream` — Anbeeld/beellama  
- `buun-source` — spiritbuun/buun-llama-cpp  
- `tq3-source` — turbo-tan/llama.cpp-tq3  
- `bitnet-upstream` — microsoft/BitNet  

## Binary policy

- **Other engines** may use **official/binary releases** (e.g. llama.cpp CUDA 13.3 under `release-bin/`).
- **Godzilla must be rebuilt** from this tree (CUDA sm_86 for RTX 3080).  
- Thin PE + DLL packs: always run with **cwd = binary directory**.

## Windows rebuild (STOP — read before library hunting)

**Do not re-discover UCRT paths.** Full pin lives in multiple places on purpose:

| Doc / script | Role |
|--------------|------|
| [`docs/WINDOWS-BUILD-TOOLCHAIN.md`](docs/WINDOWS-BUILD-TOOLCHAIN.md) | **Canonical** MSVC / UCRT / CUDA map |
| [`docs/LOCAL-SETUP.example.md`](docs/LOCAL-SETUP.example.md) | Env profile snippet |
| [`scripts/env-godzilla-msvc.cmd`](scripts/env-godzilla-msvc.cmd) | Shared `call`able env bootstrap |
| [`rebuild_king.cmd`](rebuild_king.cmd) | One-shot king rebuild → `release-bin/` |
| [`scripts/build_cuda.ps1`](scripts/build_cuda.ps1) | PowerShell CUDA build |
| [`scripts/godzilla-paths.ps1`](scripts/godzilla-paths.ps1) | Auto-detect `S:\WADK102` + UCRT prepend |

**One command:**

```bat
rebuild_king.cmd
```

**Root cause of every past failure:** VS 18 `vcvars64` finds `S:\WADK102` **um/shared** but **not UCRT** → `LNK1104: ucrtd.lib`. Always **prepend** UCRT via `env-godzilla-msvc.cmd` / `Add-WdkUcrtToEnv`.

Lab pins: WDK `S:\WADK102` @ `10.0.26100.0`, CUDA **13.2**, arch **86**, VS **18**.

## Current runtime binary

`release-bin/llama-server.exe` — prefer a freshly built artifact from `rebuild_king.cmd` / `build-king`.  
If a build is in progress, interim CUDA builds may be staged from the last known good TurboQuant+TriAttention package until `BUILD_OK`.

## Auto TriAttention (product)

VandelayNexus, on start with `triattention` capability / godzilla recipe:

1. Resolve GGUF → HF base id  
2. Reuse `data/triattention/*.triattention` or lab calibrations  
3. Else run TurboQuantExperimentation calibrator  
4. Inject `--triattention-stats <path>` (+ budget/window defaults) into argv  

Operator does **not** run a separate “calibrate then start” dance.
