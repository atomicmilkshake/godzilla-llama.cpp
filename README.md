# Godzilla llama.cpp

**King of the Monsters** — one fork that combines the best KV compression, pruning, weight quants, and speculative decoding work into a single maintainable tree.

> The fork that collected and perfected the best KV work (TurboQuant + TriAttention + KVarN + spiritbuun dequant), the best weight work (ik_llama), the best speculative decoding (BeeLlama + AtomicBot-ai/NJannasch), and made them play together.

**Maintainer:** [atomicmilkshake](https://github.com/atomicmilkshake)  
**Base:** [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp) (`beellama-upstream`)  
**Active integration branch:** `kv-god` (TriAttention on BeeLlama TurboQuant/TCQ stack)

## Godzilla stack (target architecture)

```
Model Loading
├── Weight Quantization (ik_llama Trellis/IQ* + row-interleaved packing)     [Phase 2]
│
Inference Graph
├── KV Cache Quantization (TurboQuant/TCQ + spiritbuun dequant/norm)         [Phase 1]
├── KV Pruning / Eviction (TriAttention GPU scoring + compaction)            [kv-god ✓]
├── Speculative Decoding (DFlash/MTP + model-specific heads + Tri-aware)     [Phase 3]
└── Backend Execution (CUDA/HIP/Metal/CPU + hybrid offload)                  [ongoing]
```

## What works today (`kv-god`)

Cherry-picked from [spiritbuun/buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) onto BeeLlama `main` @ `85e22ea0b`:

- **TriAttention V3** — calibration-guided KV eviction ([arXiv:2604.04921](https://arxiv.org/abs/2604.04921))
- Full CLI surface: `--triattention-stats`, `--triattention-budget`, `--triattention-window`, buckets, hard-prefix, etc.
- CUDA scoring kernel: `ggml/src/ggml-cuda/triattention-score.cu`
- Docs: [docs/TRIATTENTION.md](docs/TRIATTENTION.md), [docs/TRIATTENTION-API.md](docs/TRIATTENTION-API.md)

Inherited from BeeLlama (unchanged on `kv-god` until later phases):

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
$env:INCLUDE += ";S:\WADK102\Include\10.0.26100.0\ucrt"
$env:LIB     += ";S:\WADK102\Lib\10.0.26100.0\ucrt\x64"

cmake -S . -B build -G Ninja `
  -DGGML_CUDA=ON -DGGML_NATIVE=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON `
  -DGGML_CCACHE=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86
cmake --build build -j 8 --target llama-server
```

### TurboQuant + TriAttention server example

```powershell
.\build\bin\llama-server.exe `
  -m J:\MOODLES\your-model.gguf `
  --cache-type-k turbo3 --cache-type-v turbo4 `
  --flash-attn on `
  --triattention-stats J:\LLM\VibeThinker\vibethinker-3b.triattention `
  --triattention-budget 2048 --triattention-window 128 `
  -c 32768 --port 8090
```

Calibration: `J:\LLM\TurboQuantExperimentation\calibrate.py` (see workspace TriAttention rule).

### VSCode Copilot / agent mode (Qwopus-style)

For remote Copilot through Caddy, keep reasoning in `reasoning_content` only and coalesce visible `content` deltas so agent mode does not treat every token as a completed step:

```powershell
.\build\bin\llama-server.exe `
  -m J:\MOODLES\Qwopus3.5-9B-coder-Exp-Q4_K_M.gguf `
  -c 262144 -ngl 99 --flash-attn on -nkvo --kv-unified `
  --host 0.0.0.0 --port 8090 --parallel 1 `
  --alias "Qwopus Coder,Godzilla Test" --jinja `
  --reasoning on --reasoning-budget 8192 --reasoning-format deepseek `
  --no-reasoning-promote-to-content `
  --verbose --log-payloads
```

Build helper: `pwsh -File scripts/build_cuda.ps1 -Target llama-server` (stop any running `llama-server` first on Windows to avoid DLL lock).

## Benchmarks

```powershell
pwsh -File scripts/benchmarks/run-engine-preflight.ps1
pwsh -File scripts/benchmarks/run-kv-matrix.ps1 -Model path\to\model.gguf
```

Results land in `logs/benchmarks/`.

## Branching model

| Branch | Purpose |
|--------|---------|
| `main` | BeeLlama-stable baseline (releases) |
| `kv-god` | TurboQuant + TriAttention + KVarN integration |
| `quant-god` | ik_llama weight quant backports |
| `spec-god` | TriAttention-aware speculative decoding |

Upstream sync: `beellama-upstream` → periodic merge into `main`, then rebase integration branches. Full procedure: [docs/godotzilla-upstream-sync-process.md](docs/godotzilla-upstream-sync-process.md).

## Roadmap

Full phased plan: [J:\LLM\docs\godzilla-llama-cpp-plan.md](../docs/godotzilla-llama-cpp-plan.md)

| Phase | Focus | Status |
|-------|-------|--------|
| 0 | Repo + branches + TriAttention port | **in progress** |
| 1 | KV domination (spiritbuun dequant, KVarN, profiles) | queued |
| 2 | ik_llama weight quants + MoE | queued |
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