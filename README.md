# Godzilla llama.cpp

Godzilla is a BeeLlama/llama.cpp fork that integrates speculative decoding, KV compression/pruning, and fork-specific quantization changes in one codebase.

## Project scope

- Base lineage: [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp)
- Maintainer: [atomicmilkshake](https://github.com/atomicmilkshake)
- Security policy: [SECURITY.md](SECURITY.md)
- Primary integration branch: `godzilla`

## Implemented features

### Speculative decoding

- DFlash draft-model architecture and server flow
- Flat and tree DFlash verification paths
- Adaptive draft-max controllers (`profit`, `fringe`)
- CopySpec/suffix/recycle and n-gram speculative variants
- Server-side reasoning loop guard
- Native MTP speculative decoding (draft-mtp)
  > [!NOTE]
  > **Qwen 3.6 Compatibility**: This fork includes a custom conversion patch in `convert_hf_to_gguf.py` that automatically maps Qwen 3.6 `mtp_layer`/`mtp_layers` tensor prefixes and registers Qwen 3.6 HF architectures. This enables seamless, out-of-the-box conversion of Qwen 3.6 MTP weights, bridging naming limitations in upstream.

Reference docs:

- [docs/beellama-features.md](docs/beellama-features.md)
- [docs/beellama-args.md](docs/beellama-args.md)
- [docs/quickstart-qwen36-dflash.md](docs/quickstart-qwen36-dflash.md)
- [docs/quickstart-gemma-4-31b-dflash.md](docs/quickstart-gemma-4-31b-dflash.md)

### KV compression and pruning

- TurboQuant KV cache types: `turbo2`, `turbo3`, `turbo4`
- TCQ KV cache types: `turbo2_tcq`, `turbo3_tcq`
- KVarN pseudo cache-type surface and runtime integration
- TriAttention calibration-guided KV eviction (CPU + CUDA scoring paths)

Reference docs:

- [docs/TRIATTENTION.md](docs/TRIATTENTION.md)
- [docs/TRIATTENTION-API.md](docs/TRIATTENTION-API.md)
- [docs/PROFILES.md](docs/PROFILES.md)

### Weight quantization extensions

- IQ2_BN and Q8_K64 type integration (including CUDA-side support paths)
- Current status and scope notes tracked in [docs/QUANT-GOD.md](docs/QUANT-GOD.md)

## Roadmap execution status

This section lists roadmap items that are already implemented in the current tree.

| Milestone | Status |
| --- | --- |
| Single-branch Godzilla integration line | Executed |
| TriAttention integration (CLI, runtime, CUDA scoring) | Executed |
| KV stack integration (TurboQuant/TCQ + KVarN surfaces) | Executed |
| IQ2_BN starter quant stream merged | Executed |
| DFlash + adaptive controllers + loop guard | Executed |
| DFlash and TriAttention coexistence support | Executed |

Future planning is tracked in issues and docs.

## Build

### Windows (CUDA)

```powershell
cmake -S . -B build -G Ninja `
  -DGGML_CUDA=ON `
  -DGGML_NATIVE=ON `
  -DGGML_CUDA_FA=ON `
  -DGGML_CUDA_FA_ALL_QUANTS=ON `
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release --parallel --target llama-server
```

### Linux (CUDA)

```bash
cmake -B build \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build -j
```

### macOS (Metal)

```bash
cmake -B build -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

## Environment Variables

- `GGML_CUDA_FA_IGNORE_UNCOMPILED_PAIRS=1`: Warn instead of failing when a CUDA FlashAttention K/V cache quant pair was not compiled into the build.

## Launch examples

### TurboQuant + TriAttention

```bash
./build/bin/llama-server \
  -m /path/to/model.gguf \
  --flash-attn on \
  --cache-type-k turbo3 \
  --cache-type-v turbo4 \
  --triattention-stats /path/to/model.triattention \
  --triattention-budget 8192 \
  --triattention-window 128 \
  -c 32768 --port 8080
```

### DFlash

```bash
./build/bin/llama-server \
  -m /path/to/target.gguf \
  --spec-type dflash \
  --spec-draft-model /path/to/draft.gguf \
  --spec-draft-n-max 8 \
  --spec-branch-budget 0 \
  --spec-dflash-cross-ctx 512
```

### Native MTP (Multi-Token Prediction)

```bash
./build/bin/llama-server \
  -m /path/to/Qwen3.6-27B-MTP.gguf \
  --spec-type draft-mtp \
  --spec-draft-n-max 3
```


## Testing and validation

```bash
ctest --test-dir build -C Release --output-on-failure
```

Commonly used test binaries include `test-dflash-plumbing`, `test-server-context`, `test-server-loop-guard`, `test-gguf`, and `test-kvarn`.

## Benchmark helpers

```powershell
pwsh -File scripts/benchmarks/run-engine-preflight.ps1
pwsh -File scripts/benchmarks/run-kv-matrix.ps1 -Model path\to\model.gguf
```

Artifacts are written under `logs/benchmarks/`.

## Documentation index

- [docs/beellama-features.md](docs/beellama-features.md)
- [docs/beellama-args.md](docs/beellama-args.md)
- [docs/TRIATTENTION.md](docs/TRIATTENTION.md)
- [docs/TRIATTENTION-API.md](docs/TRIATTENTION-API.md)
- [docs/QUANT-GOD.md](docs/QUANT-GOD.md)
- [docs/PROFILES.md](docs/PROFILES.md)
- [docs/CADRE-INTEGRATION.md](docs/CADRE-INTEGRATION.md)
- [docs/godzilla-upstream-sync-process.md](docs/godzilla-upstream-sync-process.md)

## Attribution

| Area | Upstream source |
| --- | --- |
| BeeLlama base, DFlash, adaptive spec | [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp) |
| TurboQuant / TCQ lineage | [TheTom/llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant), [spiritbuun/buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) |
| TriAttention lineage | domvox / atomicmilkshake integration via buun lineage |
| IQ2_BN quant ideas | [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) |
