# BitNet in godzilla-llama.cpp

Microsoft **I2_S / TL1 / TL2** CPU kernels are vendored under `vendor/bitnet/` and gated by CMake flags. Production CUDA godzilla on `:8090` keeps BitNet **OFF** by default.

## Quick reference

| Phase | Endpoint | Binary | Status |
|-------|----------|--------|--------|
| **P0** | `:8091` | `J:\LLM\BitNet` Microsoft fork (WSL Clang) | Operational |
| **P1** | dev | `build-bitnet-cpu` with `GGML_BITNET_I2_S=ON` | Build + load OK; greedy parity vs MS (use `llama-completion --no-conversation`) |
| **P2** | `:8090` | Unified godzilla + `start-bitnet-godzilla.bat` | Preset **#47** in master.ps1 (no TriAttention) |

## Ports (Caddy)

| Port | Stack | Notes |
|------|-------|-------|
| **8090** | Production godzilla CUDA (kv-god) or BitNet godzilla CPU (preset 47 / `start-bitnet-godzilla.bat`) | Caddy reverse proxy target |
| **8091** | Microsoft BitNet fork WSL (`start-bitnet-2b-godzilla-stack.bat`) | P0 reference; deprecate after I2_S parity gate |

## P0 dual-binary (no godzilla code required)

```powershell
# Model already at J:\LLM\BitNet\models\BitNet-b1.58-2B-4T\ggml-model-i2_s.gguf
J:\LLM\start-bitnet-2b-godzilla-stack.bat
curl http://127.0.0.1:8091/v1/models
```

Build notes (Microsoft clone):

- **WSL:** `cd /mnt/j/LLM/BitNet && python3 scripts/compile via setup_env` — Clang 14+ in WSL works.
- **Windows native:** requires VS **ClangCL** component (`Microsoft.VisualStudio.Component.VC.Llvm.Clang`); MSVC alone fails.
- **Python 3.14:** install `gguf` with `pip install 3rdparty/llama.cpp/gguf-py --no-deps` after `pip install sentencepiece`.
- **`-p` pretuned:** `BitNet-b1.58-2B-4T` has no `preset_kernels/` folder; use codegen path or download pre-quantized GGUF from `microsoft/bitnet-b1.58-2B-4T-gguf`.

## P1 godzilla integration

### CMake flags

```cmake
-DGGML_BITNET_I2_S=ON      # I2_S MAD kernels (vendor/bitnet/src/ggml-bitnet-mad.cpp)
-DGGML_BITNET_X86_TL2=OFF   # TL2 LUT (P2)
-DGGML_BITNET_ARM_TL1=OFF   # TL1 LUT (ARM only)
```

**Clang or GCC required** for BitNet sources; MSVC-only builds must keep all `GGML_BITNET_*` OFF.

### Build (WSL recommended)

```powershell
pwsh -File J:\LLM\godzilla-llama.cpp\scripts\build_bitnet_cpu.ps1 -UseWsl -Target llama-cli
```

### Enum IDs

BitNet types use IDs **56–59** (after TurboQuant 42–55). See `vendor/bitnet/CHERRY_PICK_CHECKLIST.md`.

### Model fetch (P2)

```powershell
pwsh -File J:\LLM\godzilla-llama.cpp\scripts\fetch-bitnet-model.ps1
```

## Quant paths

| Path | Tool | Output | Notes |
|------|------|--------|-------|
| MS lossless | `vendor/bitnet/utils/convert-hf-to-gguf-bitnet.py` | I2_S / TL2 | Parity reference |
| godzilla legacy | `conversion/bitnet.py` | TQ1 / IQ1 | GPU experiments; **not lossless** vs I2_S |

**Warning:** IQ2/TQ GPU offload may run but gives **wrong** BitNet results per Microsoft `ggml-bitnet.h`.

## TriAttention

BitNet master preset omits `--triattention-stats` (same as Bonsai #8). No `.triattention` calibration file required.

## CUDA / `-ngl`

Optional TQ1/TQ2 CUDA mmq for BitNet GPU experiments is **not implemented** (P4). Default BitNet serving is **CPU I2_S** (`-ngl 0`). **Do not** use IQ2/TQ GPU paths for I2_S models — results are numerically wrong per Microsoft `ggml-bitnet.h` and godzilla TurboQuant layout.

## TL2 (P2)

`GGML_BITNET_X86_TL2` wires `vendor/bitnet/src/ggml-bitnet-lut.cpp` + `preset_kernels/` codegen (`codegen_tl2.py`). **BitNet-b1.58-2B-4T** ships as prebuilt **I2_S** GGUF; TL2 is optional for future 3B pretuned builds. Benchmark note: MS fork reports ~1.37× decode speedup vs I2_S on x86 when pretuned TL2 kernels exist (see Microsoft BitNet README).

## Vendor pin

- `vendor/bitnet/VENDOR.md` — commit `01eb415772c342d9f20dc42772f1583ae1e5b102`
- Cherry-pick map: `vendor/bitnet/CHERRY_PICK_CHECKLIST.md`

## Regression gates

```powershell
ctest -R "triattention|copilot-coalesce"   # must pass with GGML_BITNET_*=OFF
```

I2_S parity: greedy decode vs `J:\LLM\BitNet\build/bin/llama-cli` on same prompt (≥95% token match) before deprecating `:8091`.

```bash
# Raw completion parity (not chat-formatted llama-cli)
MODEL=/mnt/j/MOODLES/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf
MS=/mnt/j/LLM/BitNet/build/bin/llama-cli
GZ=/mnt/j/LLM/godzilla-llama.cpp/build-bitnet-cpu/bin/llama-completion
$MS -m "$MODEL" -p "Hello" -n 16 -ngl 0 --temp 0 --no-warmup --no-display-prompt -t 4
$GZ -m "$MODEL" -p "Hello" -n 16 -ngl 0 --temp 0 --fit off --no-warmup --no-display-prompt --no-conversation --single-turn -t 4
```

**Note:** BitNet-b1.58 uses **ReLU²** FFN (`LLM_FFN_RELU_SQR`), not SiLU. Wrong activation caused token drift after ~3 tokens (fixed in `src/models/bitnet.cpp`).

## Merge checklist (`bitnet-god` → `kv-god`)

Before merge:

- [ ] `ctest -R "triattention|copilot-coalesce"` on default CUDA `build/` (BitNet OFF) — **9/9 PASS**
- [ ] `llama-completion --no-conversation` greedy parity vs MS on `Hello` n=16
- [ ] `test-bitnet-i2s-quant` PASS (bitnet-cpu build)
- [ ] `llama-server` smoke: `/v1/models` 200 on `:8090`
- [ ] Confirm production `:8090` preset still uses CUDA build with `GGML_BITNET_*=OFF`
- [ ] Append `agent-journal.md` with merge SHA

Merge (no force-push):

```powershell
cd J:\LLM\godzilla-llama.cpp
git checkout kv-god
git merge --no-ff bitnet-god -m "merge(bitnet): I2_S CPU path for BitNet-b1.58 (BitNet OFF by default on CUDA)"
```
