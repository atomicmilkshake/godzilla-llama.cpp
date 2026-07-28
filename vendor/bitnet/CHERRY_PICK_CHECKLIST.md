# BitNet ggml cherry-pick checklist (Eddie-Wang → godzilla)

**Diff base:** `$BITNET_REF_ROOT\3rdparty\llama.cpp` @ `1f86f058` (Eddie-Wang fork in MS BitNet)  
**Target:** `<GODZILLA_ROOT>` branch `bitnet-god`  
**Vendor pin:** see [VENDOR.md](VENDOR.md)

---

## Proposed enum IDs (after godzilla TurboQuant 42–55)

Eddie-Wang fork assigns BitNet types at **36–39**, which collide with godzilla's extended quant layout. Assign **after** `GGML_TYPE_TURBO4_TCQ = 55`:

| Type | Eddie-Wang ID | **Proposed godzilla ID** | GGUF constant |
|------|---------------|--------------------------|---------------|
| `GGML_TYPE_I2_S` | 36 | **56** | `I2_S` |
| `GGML_TYPE_I8_S` | 37 | **57** | `I8_S` |
| `GGML_TYPE_TL1` | 38 | **58** | `TL1` |
| `GGML_TYPE_TL2` | 39 | **59** | `TL2` |
| `GGML_TYPE_COUNT` | — | **60** | — |

**Follow-up:** update `tests/snapshots/` if enum snapshots exist; sync `gguf-py/gguf/constants.py`.

---

## File-by-file cherry-pick map

### Headers / types

| Eddie-Wang file | godzilla target | Action |
|-----------------|-----------------|--------|
| `ggml/include/ggml.h` | `ggml/include/ggml.h` | Add I2_S/I8_S/TL1/TL2 at IDs 56–59; bump COUNT |
| `ggml/src/ggml-common.h` | `ggml/src/ggml-common.h` | Add `QK_I2_S`, block layouts if missing |
| `include/ggml-bitnet.h` | `vendor/bitnet/include/` (already vendored) | Wire include path in CMake |
| `include/bitnet-lut-kernels.h` | generated or `vendor/bitnet/preset_kernels/` | TL1/TL2 codegen target (P2) |

### Core ggml integration

| Eddie-Wang file | godzilla target | Key symbols / regions |
|-----------------|-----------------|----------------------|
| `ggml/src/ggml.c` | `ggml/src/ggml.c` | `#include "ggml-bitnet.h"`; `ggml_bitnet_init()` in init; `type_traits` entries for I2_S/TL1/TL2; `ggml_compute_forward_mul_mat` BitNet fast path (~12680–12810); `ggml_graph_plan` wsize hook (~20464); quantize cases (~22657) |
| `ggml/src/ggml-quants.c` | `ggml/src/ggml-quants.c` | `dequantize_row_i2_s`, `quantize_i2_s` (if enabled), type switch cases |
| `ggml/src/CMakeLists.txt` | `ggml/src/CMakeLists.txt` | Conditional compile of `vendor/bitnet/src/*.cpp` into `ggml-cpu` when `GGML_BITNET_I2_S` |

### CPU backend

| Eddie-Wang file | godzilla target | Action |
|-----------------|-----------------|--------|
| `ggml/src/ggml-cpu/ggml-cpu.c` | same | Verify vec_dot / type_traits delegation for I2_S (godzilla may use refactored cpu path) |

### Tools / Python

| Eddie-Wang file | godzilla target | Action |
|-----------------|-----------------|--------|
| `examples/quantize/quantize.cpp` | `tools/quantize/quantize.cpp` | Add `I2_S`, `TL1`, `TL2` ftype strings |
| `gguf-py/gguf/constants.py` | `gguf-py/gguf/constants.py` | Map new enum IDs |

### Model / server (mostly present in godzilla)

| Eddie-Wang file | godzilla target | Status |
|-----------------|-----------------|--------|
| `src/llama.cpp` | `src/llama-model.cpp` etc. | `LLM_ARCH_BITNET` graph exists; verify `ggml_bitnet_transform_tensor` at load |
| `src/models/bitnet.cpp` | `src/models/bitnet.cpp` | **Present** — layer count / 2B detection may need extension |

### Kernels (vendored — compile only)

| Source | CMake flag |
|--------|------------|
| `vendor/bitnet/src/ggml-bitnet-mad.cpp` | `GGML_BITNET_I2_S=ON` |
| `vendor/bitnet/src/ggml-bitnet-lut.cpp` | `GGML_BITNET_X86_TL2` or `GGML_BITNET_ARM_TL1` |

---

## CMake options (P1)

```cmake
option(GGML_BITNET_I2_S    "BitNet I2_S MAD kernels" OFF)
option(GGML_BITNET_X86_TL2 "BitNet TL2 LUT kernels (x86)" OFF)
option(GGML_BITNET_ARM_TL1 "BitNet TL1 LUT kernels (ARM)" OFF)
```

Default **OFF** — production CUDA builds unchanged; TriAttention regression gate with BitNet disabled.

---

## Build toolchain

| Platform | Requirement |
|----------|-------------|
| Windows x86_64 | **ClangCL** (VS component `Microsoft.VisualStudio.Component.VC.Llvm.Clang`) or WSL side-build |
| Linux / WSL | Clang ≥14, GCC not sufficient per MS `src/CMakeLists.txt` |
| MSVC-only | **Rejected** by BitNet kernel sources |

Script: `scripts/build_bitnet_cpu.ps1` (P1) — ClangCL or documents WSL fallback.

---

## Regression gates (before merge to kv-god)

- [ ] `ctest -R "triattention|copilot-coalesce"` 9/9 PASS with `GGML_BITNET_*=OFF`
- [ ] I2_S `llama-cli` loads `ggml-model-i2_s.gguf` without unknown quant type
- [ ] Greedy decode token match ≥95% vs Microsoft `$BITNET_REF_ROOT` reference on fixed prompt

---

## Known conflicts / deferrals

- **TriAttention:** BitNet master preset omits `--triattention-stats` (Bonsai #8 pattern); no `.triattention` file required.
- **IQ2/TQ GPU path:** existing godzilla paths run but are **not lossless** for BitNet; document in `docs/BITNET.md`.
- **Enum snapshots:** TurboQuant types 42–55 must remain stable; BitNet types append only.
