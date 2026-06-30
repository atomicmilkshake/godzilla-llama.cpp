# quant-god — ik_llama weight quant starter

**Branch:** `quant-god` (forked from `kv-god`)  
**Phase:** Godzilla Phase 2 weight quants ([godzilla-llama-cpp-plan.md](../../docs/godotzilla-llama-cpp-plan.md))

## Scope (Stream D starter)

This branch ports **ik_llama.cpp** weight-quant ideas without touching the Microsoft BitNet vendor slice on `kv-god`.

| Item | Status |
|------|--------|
| `GGML_TYPE_IQ2_BN` (godzilla enum **60**) | CPU `quantize_row_iq2_bn_ref` + `dequantize_row_iq2_bn` |
| `block_iq2_bn` row-interleaved 2.0 bpw packing | Ported from ik `iqk_quantize.cpp` |
| MS `GGML_TYPE_I2_S` / `vendor/bitnet/` | **Untouched** — different numerics |
| CUDA `mmvq` / `Q8_K64` vec_dot | **Deferred** — requires `Q8_K64` + ik CUDA paths |
| `IQ2_BN_R4`, full `llama-quant` ftype | **Deferred** |

## ik_llama reference mapping

| ik_llama.cpp | godzilla quant-god |
|--------------|-------------------|
| `GGML_TYPE_IQ2_BN = 135` | `GGML_TYPE_IQ2_BN = 60` (after BitNet 56–59) |
| `iqk/iqk_quantize.cpp` `quantize_one_row_2bn` | `ggml/src/ggml-iq2-bn.c` |
| `row_meta_size = 4` float prefix | **Deferred** — godzilla ggml has no row_meta yet |

## Smoke gate

```powershell
cd <GODZILLA_ROOT>
cmake --build build -j 8 --target test-quantize-fns
.\build\bin\test-quantize-fns.exe
# Expect: iq2_bn quant round-trip PASS (vec_dot skipped — no CPU vec_dot yet)
```

`kv-god` CUDA regression (unchanged by this branch):

```powershell
ctest -R "triattention|copilot-coalesce" --test-dir build
```

## Merge policy

Do **not** merge `quant-god` → `kv-god` until enum audit + CUDA inference path + ctest gates are green. BitNet vendor and TurboQuant enums 42–55 must remain stable on `kv-god`.

## Merge readiness (2026-06-29)

| Gate | Status | Notes |
|------|--------|-------|
| `test-quantize-fns` IQ2_BN round-trip | **PASS** | CPU quant/dequant @ `6af1ccf81`; vec_dot skipped |
| `kv-god` ctest `triattention\|copilot-coalesce` | **PASS** | Verified on `kv-god` @ `997abec34` without quant merge |
| Enum 60 audit vs BitNet 56–59 / Turbo 42–55 | **OPEN** | No collision; formal audit before merge |
| CPU `vec_dot_iq2_bn_q8_K64` | **BLOCKED** | No `Q8_K64` type in godzilla ggml yet |
| CUDA `mmvq` / dequant kernels | **BLOCKED** | ik CUDA path not ported |
| `row_meta` float prefix (ik parity) | **DEFERRED** | godzilla ggml has no row_meta |
| `llama-quant` ftype wiring | **DEFERRED** | Starter stub only |

**Verdict:** **Not merge-ready** to `kv-god`. Safe to keep on `quant-god` @ `6af1ccf81` for CPU smoke; next port is `Q8_K64` + `vec_dot_iq2_bn_q8_K64` before any merge discussion.

**kv-god delta:** `quant-god` is based on `kv-god` @ `0f55d003b` + IQ2_BN commit `bfb0678f4`; `kv-god` has since advanced to `997abec34` (Stream B harness/docs only — no quant conflicts).
