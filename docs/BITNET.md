# BitNet in godzilla-llama.cpp

Microsoft **I2_S / TL1 / TL2** CPU kernels are vendored under `vendor/bitnet/` and gated by CMake flags. Production CUDA godzilla on `:8090` keeps BitNet **OFF** by default.

## Quick reference

| Phase | Endpoint | Binary | Status |
|-------|----------|--------|--------|
| **P0** | `:8091` | `$BITNET_REF_ROOT` Microsoft fork (WSL Clang) | Operational |
| **P1** | dev | `build-bitnet-cpu` with `GGML_BITNET_I2_S=ON` | Build + load OK; greedy parity vs MS (use `llama-completion --no-conversation`) |
| **P2** | `:8090` | Unified godzilla + `start-bitnet-godzilla.bat` | Preset **#47** in master.ps1 (no TriAttention) |
| **GPU** | *(CLI)* | `$BITNET_REF_ROOT\gpu` PyTorch + `libbitnet.so` | Separate stack; WSL only; no HTTP server |

## P2 unified launcher (`start-bitnet-godzilla.bat`)

- **Binary:** `godzilla-llama.cpp/build-bitnet-cpu/bin/llama-server` (WSL) or `bin/llama-server.exe` (Windows ClangCL).
- **Model:** prefers `$MODELS_DIR/bitnet-b1.58-2B-4T\ggml-model-i2_s.gguf`; falls back to `$BITNET_REF_ROOT\models\...`.
- **Context:** `-c 4096` (matches `n_ctx_train`; avoids cap warning).
- **Not** the Microsoft fork binary on `:8091` — that stack is P0 reference only.

```powershell
<operator-launcher>.bat
curl http://127.0.0.1:8090/v1/models
```

Load log must **not** show `unknown type i2_s` (requires godzilla build with `GGML_BITNET_I2_S=ON` and `LLAMA_FTYPE_MOSTLY_I2_S` ftype case).

## Ports (Caddy)

| Port | Stack | Notes |
|------|-------|-------|
| **8090** | Production godzilla CUDA (kv-god) or BitNet godzilla CPU (preset 47 / `start-bitnet-godzilla.bat`) | Caddy reverse proxy target |
| **8091** | Microsoft BitNet fork WSL (`start-bitnet-2b-godzilla-stack.bat`) | P0 reference; deprecate after I2_S parity gate |

## P0 dual-binary (no godzilla code required)

```powershell
# Model already at $BITNET_REF_ROOT\models\BitNet-b1.58-2B-4T\ggml-model-i2_s.gguf
<operator-launcher>.bat
curl http://127.0.0.1:8091/v1/models
```

Build notes (Microsoft clone):

- **WSL:** `cd $BITNET_REF_ROOT && python3 scripts/compile via setup_env` — Clang 14+ in WSL works.
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
pwsh -File <GODZILLA_ROOT>\scripts\build_bitnet_cpu.ps1 -UseWsl -Target llama-cli
# Server (preset 47 / start-bitnet-godzilla.bat):
pwsh -File <GODZILLA_ROOT>\scripts\build_bitnet_cpu.ps1 -UseWsl -Target llama-server
```

### Enum IDs

BitNet types use IDs **56–59** (after TurboQuant 42–55). See `vendor/bitnet/CHERRY_PICK_CHECKLIST.md`.

### Model fetch (P2)

```powershell
pwsh -File <GODZILLA_ROOT>\scripts\fetch-bitnet-model.ps1
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

## PyTorch GPU (Microsoft `gpu/`)

Microsoft ships a **separate** W2A8 PyTorch stack under `$BITNET_REF_ROOT\gpu\` (pin `01eb415` on `main`). It is **not** integrated into ggml/`llama-server` and does **not** share checkpoints with I2_S GGUF.

| | **CPU I2_S (P0–P2)** | **PyTorch GPU (`gpu/`)** |
|---|---|---|
| Runtime | ggml / godzilla `llama-server` | PyTorch 2.2+ + xformers + custom CUDA GEMV |
| Quant | I2_S GGUF (`ggml-model-i2_s.gguf`) | BF16 prefill + int2 decode (`model_state_fp16.pt`, `model_state_int2.pt`) |
| Platform | WSL Clang or Windows ClangCL | **Linux/WSL only** (`libbitnet.so` via `ctypes`) |
| Serving | OpenAI-compatible HTTP (`:8090` / `:8091`) | `generate.py` CLI only (no MS OpenAI wrapper in repo) |
| Parity | Greedy match vs MS `llama-cli` on GGUF | Different stack; not comparable token-for-token to I2_S |

### What `gpu/` supports

- **BitNet-b1.58-2B-4T** only (`model.py` `ModelArgs`: 30 layers, dim 2560).
- Custom **W2A8** kernel (`bitnet_kernels/bitnet_kernels.cu`): 2-bit weights × 8-bit activations GEMV with `dp4a`.
- Prefill: BF16 weights (`use_kernel=False`); decode: int2 + CUDA kernel (`use_kernel=True`).
- CUDA graphs + xformers block-diagonal attention masks.
- Checkpoint pipeline: HF `microsoft/bitnet-b1.58-2B-4T-bf16` → `convert_safetensors.py` → `convert_checkpoint.py`.

### Linux / WSL constraints

- `compile.sh` / `nvcc` builds `bitnet_kernels/libbitnet.so` (`.so` only; **no Windows-native path**).
- `model.py` loads the `.so` with a **relative** path (`bitnet_kernels/libbitnet.so`); run from `gpu/` root.
- Requires **CUDA toolkit in WSL** (`nvcc`), NVIDIA driver passthrough, and GPU with **sm_80+** (RTX 30xx = 8.6).
- `gpu-dev` branch differs only cosmetically from `main` for `gpu/` (drops `weights_only=True` on `torch.load`; README table edits). Stay on **`main` @ `01eb415`** unless MS merges GPU fixes.

### Windows native feasibility

**Not supported** without WSL: no `.dll` build, no MSVC path, PyTorch CUDA + xformers + nvcc expect Linux. Use WSL2 with CUDA (same pattern as P0 WSL `llama-server`).

### Setup (this workspace)

```powershell
# One-time: venv, pip deps, nvcc kernel (auto sm_XX), HF download + convert, kernel test
pwsh -File <workspace-scripts>/setup-bitnet-gpu-pytorch.ps1

# Interactive chat (WSL)
<operator-launcher>.bat
```

Manual WSL steps (equivalent):

```bash
cd $BITNET_REF_ROOT/gpu
python3 -m venv venv-bitnet-gpu && source venv-bitnet-gpu/bin/activate
pip install -r requirements.txt
cd bitnet_kernels
# RTX 3080 (8.6): use sm_86; A100: sm_80 is fine
nvcc -std=c++17 -Xcudafe --diag_suppress=177 --compiler-options -fPIC -lineinfo --shared \
  bitnet_kernels.cu -lcuda -gencode=arch=compute_86,code=sm_86 -o libbitnet.so
cd ..
python test.py
mkdir -p checkpoints
huggingface-cli download microsoft/bitnet-b1.58-2B-4T-bf16 --local-dir ./checkpoints/bitnet-b1.58-2B-4T-bf16
python convert_safetensors.py --safetensors_file ./checkpoints/bitnet-b1.58-2B-4T-bf16/model.safetensors \
  --output checkpoints/model_state.pt --model_name 2B
python convert_checkpoint.py --input ./checkpoints/model_state.pt
rm checkpoints/model_state.pt
python generate.py ./checkpoints/ --chat_format   # non-interactive smoke
```

### Smoke / limits

- Non-interactive smoke: `python generate.py ./checkpoints/` (default prompt `Hello, my name is`).
- Set `NO_CUDA_GRAPHS=1` in env if CUDA graph capture fails on older drivers.
- No Flask/OpenAI server in `gpu/`; keep P0 `:8091` for HTTP reference until a wrapper is added.
- GPU stack is experimental throughput research; production BitNet on godzilla remains **CPU I2_S**.

## TL2 (P2)

`GGML_BITNET_X86_TL2` wires `vendor/bitnet/src/ggml-bitnet-lut.cpp` + `preset_kernels/` codegen (`codegen_tl2.py`). **BitNet-b1.58-2B-4T** ships as prebuilt **I2_S** GGUF; TL2 is optional for future 3B pretuned builds. Benchmark note: MS fork reports ~1.37× decode speedup vs I2_S on x86 when pretuned TL2 kernels exist (see Microsoft BitNet README).

## Vendor pin

- `vendor/bitnet/VENDOR.md` — commit `01eb415772c342d9f20dc42772f1583ae1e5b102`
- Cherry-pick map: `vendor/bitnet/CHERRY_PICK_CHECKLIST.md`

## Regression gates

```powershell
ctest -R "triattention|copilot-coalesce"   # must pass with GGML_BITNET_*=OFF
```

I2_S parity: greedy decode vs `$BITNET_REF_ROOT\build/bin/llama-cli` on same prompt (≥95% token match) before deprecating `:8091`.

```bash
# Raw completion parity (not chat-formatted llama-cli)
MODEL=$MODELS_DIR/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf
MS=$BITNET_REF_ROOT/build/bin/llama-cli
GZ=$WSL_GODZILLA_ROOT/build-bitnet-cpu/bin/llama-completion
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
cd <GODZILLA_ROOT>
git checkout kv-god
git merge --no-ff bitnet-god -m "merge(bitnet): I2_S CPU path for BitNet-b1.58 (BitNet OFF by default on CUDA)"
```
