# quant-god — ik_llama weight quant starter

**Branch:** `quant-god` (forked from `kv-god`)  
**Phase:** Godzilla Phase 2 weight quants ([godzilla-llama-cpp-plan.md](../../docs/godotzilla-llama-cpp-plan.md))

## Scope (Stream D starter)

This branch ports **ik_llama.cpp** weight-quant ideas without touching the Microsoft BitNet vendor slice on `kv-god`.

| Item | Status |
|------|--------|
| `GGML_TYPE_IQ2_BN` (godzilla enum **60**) | CPU quant/dequant + row max prefix |
| `GGML_TYPE_Q8_K64` (godzilla enum **61**) | CPU `quantize_row_q8_K64` for vec_dot activations |
| `block_iq2_bn` row-interleaved 2.0 bpw packing | Ported from ik `iqk_quantize.cpp` |
| CPU `vec_dot_iq2_bn_q8_K64` | **Implemented** (scalar ik fallback) |
| CUDA `mmvq` `vec_dot_iq2_bn_q8_1` | **Implemented** (godzilla vecdotq path) |
| CUDA `dequantize_row_iq2_bn` | **Implemented** (`convert.cu`) |
| MS `GGML_TYPE_I2_S` / `vendor/bitnet/` | **Untouched** — different numerics |
| `IQ2_BN_R4`, full `llama-quant` ftype | **Deferred** |
| ik `row_meta_size` in ggml traits | **Partial** — `ggml_row_size` +4 B for IQ2_BN only |

## ik_llama reference mapping

| ik_llama.cpp | godzilla quant-god |
|--------------|-------------------|
| `GGML_TYPE_IQ2_BN = 135` | `GGML_TYPE_IQ2_BN = 60` (after BitNet 56–59) |
| `GGML_TYPE_Q8_K64 = 136` | `GGML_TYPE_Q8_K64 = 61` |
| `iqk/iqk_quantize.cpp` `quantize_one_row_2bn` | `ggml/src/ggml-iq2-bn.c` |
| `row_meta_size = 4` float prefix | `ggml_row_size(IQ2_BN)` +4 bytes (not full row_meta API) |

## Smoke gate

```powershell
cd <GODZILLA_ROOT>
# WDK: -SdkRoot S:\WADK102 or $env:WDK_ROOT (see docs/LOCAL-SETUP.example.md)
powershell -File scripts/build_cuda.ps1 -SdkRoot S:\WADK102 -Target test-quantize-fns
.\build\bin\test-quantize-fns.exe
# Expect: iq2_bn quant round-trip PASS; vec_dot iq2_bn x q8_K64 PASS
```

`kv-god` CUDA regression (unchanged by this branch until merge):

```powershell
ctest -R "triattention|copilot-coalesce" --test-dir build
```

## Merge policy

Do **not** merge `quant-god` → `kv-god` until enum audit + ctest gates are green. BitNet vendor and TurboQuant enums 42–55 must remain stable on `kv-god`.

## Merge readiness (2026-06-30)

| Gate | Status | Notes |
|------|--------|-------|
| `test-quantize-fns` IQ2_BN round-trip | **PENDING** | Re-verify after Q8_K64 + vec_dot commit |
| `test-quantize-fns` IQ2_BN vec_dot | **PENDING** | CPU `vec_dot_iq2_bn_q8_K64` added |
| CUDA compile (`ggml-cuda` + IQ2_BN) | **PENDING** | mmvq + dequant kernels added; build with WDK @ `S:\WADK102` |
| `kv-god` ctest `triattention\|copilot-coalesce` | **PASS** | Last verified on `kv-god` without quant merge |
| Enum 60/61 audit vs BitNet 56–59 / Turbo 42–55 | **OPEN** | No collision; formal audit before merge |
| CUDA mmq / ik `iqk_mul_mat` fast path | **DEFERRED** | mmvq only (ik uses separate iqk CUDA) |
| `llama-quant` ftype wiring | **DEFERRED** | Starter stub only |

**Verdict:** **Not merge-ready** to `kv-god`. CPU + CUDA inference paths are in-tree; need green `test-quantize-fns` and CUDA build smoke on operator hardware before merge discussion.

### Merge checklist (when gates close)

1. `test-quantize-fns.exe` exit 0 (iq2_bn quant + vec_dot).
2. CUDA build smoke: `build_cuda.ps1 -Target test-quantize-fns` with WDK.
3. `ctest -R "triattention|copilot-coalesce"` **9/9** on merge candidate (quant-god rebased onto current `kv-god`).
4. Enum 60/61 documented; no GGUF collision with MS I2_S.
5. Journal append + user approval; **no** merge without ctest 9/9.

**kv-god delta:** `quant-god` based on `kv-god` @ `0f55d003b` + IQ2_BN; `kv-god` advanced to `fd0f132d4` (profiles/docs only).
