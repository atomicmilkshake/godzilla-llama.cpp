# Microsoft BitNet vendor pin

**Upstream:** https://github.com/microsoft/BitNet  
**Pinned commit:** `01eb415772c342d9f20dc42772f1583ae1e5b102` (2026-06-28 clone)  
**Eddie-Wang llama.cpp submodule:** `1f86f058de0c3f4098dedae2ae8653c335c868a1` (branch `merge-dev` at pin time)

## Scope (read-only vendor slice)

This directory holds a **pinned copy** of Microsoft bitnet.cpp CPU kernel sources and tooling. It is **not** a git submodule of the full `microsoft/BitNet` repo (which vendors a stale Eddie-Wang1120 llama.cpp fork).

| Path | Source in microsoft/BitNet |
|------|---------------------------|
| `src/ggml-bitnet-mad.cpp` | `src/ggml-bitnet-mad.cpp` |
| `src/ggml-bitnet-lut.cpp` | `src/ggml-bitnet-lut.cpp` |
| `include/ggml-bitnet.h` | `include/ggml-bitnet.h` |
| `include/gemm-config.h` | `include/gemm-config.h` |
| `preset_kernels/` | `preset_kernels/` |
| `utils/codegen_tl1.py` | `utils/codegen_tl1.py` |
| `utils/codegen_tl2.py` | `utils/codegen_tl2.py` |
| `utils/convert-hf-to-gguf-bitnet.py` | `utils/convert-hf-to-gguf-bitnet.py` |

## Local build note (P0 dual-binary)

P0 validation uses the **full** clone at `$BITNET_REF_ROOT` (WSL Clang build; Windows requires VS **ClangCL** component). Godzilla integration (P1+) compiles only this vendor slice behind `GGML_BITNET_*` CMake flags.

## WSL const fix (BitNet clone only)

Clang 14 on WSL required one const-correctness fix in `$BITNET_REF_ROOT\src\ggml-bitnet-mad.cpp` line 811 (`const int8_t * y_col`). Vendor copy here remains **unmodified** until P1 port applies the same fix if needed.

## Model weights

- **P0:** `$BITNET_REF_ROOT\models\BitNet-b1.58-2B-4T\ggml-model-i2_s.gguf` (HF `microsoft/bitnet-b1.58-2B-4T-gguf`)
- **P2 target:** `$MODELS_DIR/bitnet-b1.58-2B-4T\ggml-model-i2_s.gguf` (via `scripts/fetch-bitnet-model.ps1`)

## Do not merge

- Microsoft `gpu/` PyTorch stack
- Whole Eddie-Wang `3rdparty/llama.cpp` submodule
