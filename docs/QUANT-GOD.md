# IQ2_BN weight quant (merged into `main`)

**Status:** `quant-god` merged into `main` on **2026-07-01** (IQ2_BN **kept** — ctest 9/9 after merge).  
**Phase:** Godzilla Phase 2 weight quants ([godzilla-llama-cpp-plan.md](../../docs/godotzilla-llama-cpp-plan.md))

> Historical branch name: `quant-god`. All new work uses `main` only.

## Scope (Stream D starter)

Ports **ik_llama.cpp** weight-quant ideas without touching the Microsoft BitNet vendor slice.

| Item | Status |
|------|--------|
| `GGML_TYPE_IQ2_BN` (godzilla enum **60**) | CPU quant/dequant + row-meta scale |
| `GGML_TYPE_Q8_K64` (enum **61**) | CPU `quantize_row_q8_K64` + `vec_dot_iq2_bn_q8_K64` |
| `block_iq2_bn` row-interleaved 2.0 bpw packing | Ported from ik `iqk_quantize.cpp` |
| MS `GGML_TYPE_I2_S` / `vendor/bitnet/` | **Untouched** — different numerics |
| CUDA `mmvq` / `vec_dot_iq2_bn_q8_1` | **Implemented** — `vecdotq.cuh`, `mmvq.cu`, `convert.cu` |
| `IQ2_BN_R4`, full `llama-quant` ftype | **Deferred** |

## ik_llama reference mapping

| ik_llama.cpp | godzilla `main` |
|--------------|-------------------|
| `GGML_TYPE_IQ2_BN = 135` | `GGML_TYPE_IQ2_BN = 60` (after BitNet 56–59) |
| `GGML_TYPE_Q8_K64 = 136` | `GGML_TYPE_Q8_K64 = 61` |
| `iqk/iqk_quantize.cpp` `quantize_one_row_2bn` | `ggml/src/ggml-iq2-bn.c` |
| `row_meta_size = 4` float prefix | `ggml_row_size` +4 for `IQ2_BN` (ik `row_meta` field deferred) |

## Smoke gate

```powershell
cd <GODZILLA_ROOT>
# CPU + CUDA (WDK UCRT if VS18 needs it)
pwsh -File scripts/build_cuda.ps1 -SdkRoot S:\WADK102 -WithTests -Target test-quantize-fns
.\build\bin\test-quantize-fns.exe
# Expect: iq2_bn quant + vec_dot PASS (iq2_bn uses relaxed starter thresholds)
```



**Isolated CUDA tree (`build-qg`):** optional side build for quant-only experiments — do not run parallel ninja on `build/` and `build-qg`.

```powershell
# After vcvars + WDK UCRT (see scripts/build_cuda.ps1)
cmake --build build-qg --config Release -j 4 --target ggml-cuda
.\build-qg\bin\test-quantize-fns.exe
```

`main` CUDA regression:

```powershell
ctest -R "triattention|copilot-coalesce" --test-dir build
```

## Merge policy (2026-07-01)

IQ2_BN merged to `main` after enum audit (60–61 vs BitNet 56–59 / Turbo 42–55 — no collision) and **ctest 9/9** on merge candidate. BitNet vendor and TurboQuant enums 42–55 remain stable on `main`.

## Merge readiness (2026-06-30)

| Gate | Status | Notes |
|------|--------|-------|
| `test-quantize-fns` IQ2_BN round-trip | **PASS** | row-meta scaled dequant; starter RMSE gate 0.010; re-verified CPU-only @ `2543f8a8a` |
| `test-quantize-fns` IQ2_BN vec_dot | **PASS** | `vec_dot_iq2_bn_q8_K64` + `Q8_K64`; starter dot gate 0.15; re-verified CPU-only @ `2543f8a8a` |
| CUDA `mmvq` / `convert` compile | **PASS** | nvcc sm86: `mmvq.cu` + `convert.cu` (IQ2_BN `vec_dot_iq2_bn_q8_1`, `dequantize_block_iq2_bn`) green with WDK `-SdkRoot` (e.g. `S:\WADK102`) |
| Full CUDA link (`ggml-cuda.dll`) | **PASS** | `build-qg/bin/ggml-cuda.dll` linked @ `7e64e8c23` (2026-06-30 04:50, ~134 MB); single-writer `cmake --build build-qg -j 4 --target ggml-cuda` + WDK `S:\WADK102` |
| CUDA `test-quantize-fns` (build-qg) | **PASS** | `build-qg/bin/test-quantize-fns.exe` exit 0 incl. `iq2_bn` + `q8_K64` (CPU quant paths; CUDA DLL present) |
| `main` ctest `triattention\|copilot-coalesce` | **PASS 9/9** | After merge @ `14d6b1b77`; re-verified post-stability commits 2026-07-01 |
| Enum 60–61 audit vs BitNet 56–59 / Turbo 42–55 | **OPEN** | No collision; formal audit before merge |
| `row_meta` ggml field (ik parity) | **PARTIAL** | `ggml_row_size` +4 hack; no `row_meta_size` trait |
| `llama-quant` ftype wiring | **DEFERRED** | Starter stub only |
| End-to-end IQ2_BN GGUF inference | **DEFERRED** | No certified IQ2_BN model on godzilla yet |

**Verdict:** **Merged and kept** on `main`. Remaining deferred: tighter vec_dot parity vs ik, `llama-quant` ftype wiring, end-to-end IQ2_BN GGUF inference, GPU `MUL_MAT` IQ2_BN smoke.

**Merge commit:** `14d6b1b77` (`merge quant-god IQ2_BN into main`). Stability + `--allow-extended-ctx` on `main` @ `2a55d3c4d` (2026-07-01).
