# Godzilla llama.cpp

**King of the Monsters** — one fork that combines the best KV compression, pruning, weight quants, and speculative decoding work into a single maintainable tree.

> The fork that collected and perfected the best KV work (TurboQuant + TriAttention + KVarN + spiritbuun dequant), the best weight work (ik_llama), the best speculative decoding (BeeLlama + AtomicBot-ai/NJannasch), and made them play together.

**Maintainer:** [atomicmilkshake](https://github.com/atomicmilkshake)  
**Security:** see [SECURITY.md](SECURITY.md) · local paths: [docs/LOCAL-SETUP.example.md](docs/LOCAL-SETUP.example.md)  
**Base:** [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp) (`beellama-upstream`)  
**Active branch:** `main` (single integration line — TriAttention, TurboQuant/TCQ, IQ2_BN, KVarN)

## Godzilla stack (target architecture)

```
Model Loading
├── Weight Quantization (ik_llama Trellis/IQ* + row-interleaved packing)     [Phase 2]
│
Inference Graph
├── KV Cache Quantization (TurboQuant/TCQ + spiritbuun dequant/norm)         [Phase 1]
├── KV Pruning / Eviction (TriAttention GPU scoring + compaction)            [main ✓]
├── Speculative Decoding (DFlash/MTP + model-specific heads + Tri-aware)     [Phase 3]
└── Backend Execution (CUDA/HIP/Metal/CPU + hybrid offload)                  [ongoing]
```

## What works today (`main`)

Cherry-picked from [spiritbuun/buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) onto BeeLlama `main` @ `85e22ea0b`:

- **TriAttention V3** — calibration-guided KV eviction ([arXiv:2604.04921](https://arxiv.org/abs/2604.04921))
- Full CLI surface: `--triattention-stats`, `--triattention-budget`, `--triattention-window`, buckets, hard-prefix, etc.
- CUDA scoring kernel: `ggml/src/ggml-cuda/triattention-score.cu`
- Docs: [docs/TRIATTENTION.md](docs/TRIATTENTION.md), [docs/TRIATTENTION-API.md](docs/TRIATTENTION-API.md)

Inherited from BeeLlama:

- TurboQuant / TCQ KV types (`turbo2`, `turbo3`, `turbo4`, `turbo2_tcq`, `turbo3_tcq`)
- DFlash speculative decoding, adaptive draft control, reasoning-loop protection
- Multimodal + upstream llama.cpp server/API parity

## Quick start (CUDA, Windows)

```powershell
# MSVC + CUDA (RTX 3080 = arch 86)
$Vcvars = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
cmd /c "`"$Vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") { Set-Item "env:$($matches[1])" $matches[2] }
}
$env:INCLUDE += ";$WDK_ROOT\Include\10.0.26100.0\ucrt"
$env:LIB     += ";$WDK_ROOT\Lib\10.0.26100.0\ucrt\x64"

cmake -S . -B build -G Ninja `
  -DGGML_CUDA=ON -DGGML_NATIVE=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON `
  -DGGML_CCACHE=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86
cmake --build build -j 8 --target llama-server
```

### TurboQuant + TriAttention server example

```powershell
.\build\bin\llama-server.exe `
  -m $MODELS_DIR/your-model.gguf `
  --cache-type-k turbo3 --cache-type-v turbo4 `
  --flash-attn on `
  --triattention-stats $TRIATTENTION_CALIB_DIR/vibethinker-3b.triattention `
  --triattention-budget 2048 --triattention-window 128 `
  -c 32768 --port 8090
```

Calibration: set `TRIATTENTION_PYTHON` and `TRIATTENTION_CALIBRATE_PY` (see [docs/LOCAL-SETUP.example.md](docs/LOCAL-SETUP.example.md)).

### VSCode Copilot / agent mode (Qwopus-style)

For remote Copilot through Caddy, keep reasoning in `reasoning_content` only and coalesce visible `content` deltas so agent mode does not treat every token as a completed step:

```powershell
.\build\bin\llama-server.exe `
  -m $MODELS_DIR/Qwopus3.5-9B-coder-Exp-Q4_K_M.gguf `
  -c 262144 -ngl 99 --flash-attn on -nkvo --kv-unified `
  --host 0.0.0.0 --port 8090 --parallel 1 `
  --alias "Qwopus Coder,Godzilla Test" --jinja `
  --reasoning on --reasoning-budget 8192 --reasoning-format deepseek `
  --no-reasoning-promote-to-content `
  --verbose --log-payloads
```

Build helper: `pwsh -File scripts/build_cuda.ps1 -Target llama-server` (stop any running `llama-server` first on Windows to avoid DLL lock).

### Extended context + KV-RAM (hybrid Qwen3.5 / Cadre)

For YaRN beyond `n_ctx_train` (e.g. `-c 524288` with `--yarn-orig-ctx 262144`), pass `--allow-extended-ctx` so slot init respects the requested context instead of clamping to training size. Pair with `--kv-ram` to keep large KV in system RAM on 10 GB GPUs.

```powershell
.\build\bin\llama-server.exe `
  -m $MODELS_DIR/your-hybrid-thinking.gguf `
  --allow-extended-ctx --kv-ram --flash-attn on `
  --rope-scaling yarn --yarn-orig-ctx 262144 -c 524288 `
  --parallel 1 --jinja --reasoning on --reasoning-budget 8192 `
  --no-reasoning-promote-to-content `
  --host 0.0.0.0 --port 8090
```

Cadre integration (managed server, HumanEval): see [docs/CADRE-INTEGRATION.md](docs/CADRE-INTEGRATION.md). Rebuild helper: `V:\cadre\scripts\rebuild-godzilla.bat`.

For CUDA builds, the escape hatch environment variable `GGML_CUDA_FA_IGNORE_UNCOMPILED_PAIRS=1` can be set to warn instead of failing when a requested KV cache type pair is not compiled into the backend.


## Benchmarks

```powershell
pwsh -File scripts/benchmarks/run-engine-preflight.ps1
pwsh -File scripts/benchmarks/run-kv-matrix.ps1 -Model path\to\model.gguf
```

Results land in `logs/benchmarks/`.

## Branch policy

**Single branch:** all Godzilla work lands on `main`. Legacy topic branches (`kv-god`, `quant-god`, `spec-god`, `bitnet-god`) were consolidated 2026-07-01; IQ2_BN from `quant-god` is merged and kept.

Upstream sync: `beellama-upstream/main` → merge into `main`. Full procedure: [docs/godotzilla-upstream-sync-process.md](docs/godotzilla-upstream-sync-process.md).

## Roadmap

Phased roadmap is tracked in project issues and `docs/`; operator-specific plans stay outside this repo.

| Phase | Focus | Status |
|-------|-------|--------|
| 0 | Repo + branches + TriAttention port | **done** (`main` only) |
| 1 | KV domination (spiritbuun dequant, KVarN, profiles) | queued |
| 2 | ik_llama weight quants + MoE | **starter** (IQ2_BN on `main`) |
| 3 | Speculative + TriAttention coexistence | queued |
| 4 | Embedded polish + CPU turbo path | queued |
| 5 | Docs, prebuilts, upstream discipline | ongoing |

## Inherited BeeLlama documentation

- [BeeLlama features](docs/beellama-features.md)
- [CLI reference](docs/beellama-args.md)
- [Qwen 3.6 + DFlash quickstart](docs/quickstart-qwen36-dflash.md)
- [Gemma 4 + DFlash quickstart](docs/quickstart-gemma-4-31b-dflash.md)

## Attribution

| Innovation | Source |
|------------|--------|
| BeeLlama base, DFlash, adaptive spec | [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp) |
| TurboQuant / TCQ | [TheTom/llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant), [spiritbuun/buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) |
| TriAttention | domvox / atomicmilkshake (ported via buun) |
| ik_llama quants (planned) | [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) |
| RotorQuant / KVarN (planned) | community forks per roadmap |