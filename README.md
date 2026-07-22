# 🦖 Godzilla llama.cpp

[![Release](https://img.shields.io/github/v/release/atomicmilkshake/godzilla-llama.cpp?color=00f0ff&style=for-the-badge)](https://github.com/atomicmilkshake/godzilla-llama.cpp/releases)
[![Build Status](https://img.shields.io/github/actions/workflow/status/atomicmilkshake/godzilla-llama.cpp/release.yml?branch=godzilla&style=for-the-badge&label=CI%20Build)](https://github.com/atomicmilkshake/godzilla-llama.cpp/actions)
[![License](https://img.shields.io/github/license/atomicmilkshake/godzilla-llama.cpp?color=b8ff3c&style=for-the-badge)](LICENSE)
[![CUDA](https://img.shields.io/badge/CUDA-v13.2%20%7C%20v12.4-76B900?style=for-the-badge&logo=nvidia)](https://developer.nvidia.com/cuda-toolkit)

**Godzilla** is a high-performance, specialized fork of `beellama.cpp` / `llama.cpp` engineered for extreme long-context inference ($512K+$ tokens), sub-4bit KV cache compression, speculative draft sidecars, and advanced GPU memory allocation.

---

## 🌟 Key Architecture & Innovations

### 🚩 "Six Flags over Texas" 6-Layer Context Stack
Godzilla introduces the **"Six Flags over Texas"** orthogonal context stack, combining 6 independent optimization technologies to run **512K context windows inside 64 GB System RAM**:

| Flag | Technology | Mechanism | Target Impact |
| :--- | :--- | :--- | :--- |
| **Flag 1** | **SnapKV / PyramidKV** | Positional KV token pruning & attention sink windowing | 512K $\rightarrow$ 64K active KV slots |
| **Flag 2** | **DFlash / DSpark** | Speculative draft sidecar verification | **25.5 $\rightarrow$ 75+ tok/s** decode acceleration |
| **Flag 3** | **TurboQuant / MXFP4** | Sub-4bit micro-exponent KV cache quantization (`turbo4`) | 268 GB $\rightarrow$ 67 GB KV byte compression |
| **Flag 4** | **Chunked Prefill** | Ring-Attention prompt ingestion in 4K chunks (`-ub 512`) | **< 8.5 GB peak VRAM** prompt ingestion |
| **Flag 5** | **YaRN RoPE Scaling** | Runtime rotary position frequency scaling | Positional precision retention at 512K tokens |
| **Flag 6** | **CUDA UVM / RAM-KV** | Unified virtual memory PCIe 4.0 paging (`--kv-ram`) | **< 36 GB System RAM** physical footprint |

### ⚡ `--kv-vram-only` GPU Memory Allocator (New in v0.3.5)
Forces the KV cache onto GPU VRAM even when model weights are offloaded to System RAM (`-ngl 0` / `-ngl 1`), enabling ultra-fast token decoding on VRAM-constrained systems.

### 🧠 Native Multi-Token Prediction (MTP) & Qwen 3.6 Conversion
* Full support for native MTP draft headers (`--spec-type draft-mtp`).
* Built-in `convert_hf_to_gguf.py` tensor remapping patch automatically maps Qwen 3.6 `mtp_layer`/`mtp_layers` tensor prefixes out-of-the-box.

---

## 🚀 Quickstart Launch Examples

### 1. "Six Flags over Texas" 512K Context Stack
```bash
./llama-server \
  -m /path/to/model.gguf \
  --port 8080 \
  -ngl 99 -fa on \
  -c 524288 \
  --kv-ram \
  -ctk q4_0 -ctv q4_0 \
  --triattention-stats /path/to/model.triattention \
  --triattention-budget 2048 --triattention-window 128 \
  -ub 512 \
  --rope-scaling yarn --rope-freq-scale 0.25
```

### 2. VRAM-Only KV Offload (`--kv-vram-only`)
```bash
./llama-server \
  -m /path/to/model.gguf \
  -ngl 1 \
  --kv-vram-only \
  -fa on \
  -c 65536
```

### 3. DFlash Speculative Draft Acceleration
```bash
./llama-server \
  -m /path/to/target.gguf \
  --spec-type dflash \
  --spec-draft-model /path/to/draft.gguf \
  --spec-draft-n-max 8 \
  --spec-dflash-cross-ctx 512
```

---

## 🛠️ Multi-Platform Build Instructions

### Windows (MSVC + CUDA 13.2 / 12.x)
```powershell
cmake -S . -B build -G Ninja `
  -DGGML_CUDA=ON `
  -DGGML_NATIVE=ON `
  -DGGML_CUDA_FA=ON `
  -DGGML_CUDA_FA_ALL_QUANTS=ON `
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release --parallel --target llama-server llama-cli
```

### Linux (GCC + CUDA)
```bash
cmake -B build \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build -j
```

### macOS (Metal / Apple Silicon ARM64)
```bash
cmake -B build -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

---

## 📊 Milestone Execution Roadmap

| Milestone | Status |
| :--- | :---: |
| Single-branch Godzilla integration line (`godzilla`) | ✅ Executed |
| TriAttention integration (CLI, runtime, CUDA scoring) | ✅ Executed |
| KV stack integration (TurboQuant/TCQ + KVarN surfaces) | ✅ Executed |
| DFlash + adaptive controllers + loop guard | ✅ Executed |
| `--kv-vram-only` GPU memory allocator | ✅ Executed |
| "Six Flags over Texas" 512K context optimization stack | ✅ Executed |

---

## 📖 Documentation Index

- [docs/SIX_FLAGS_OVER_TEXAS.md](docs/SIX_FLAGS_OVER_TEXAS.md) — 6-Layer Orthogonal Context Stack Architecture
- [docs/TRIATTENTION.md](docs/TRIATTENTION.md) — TriAttention Covariance Eviction Guide
- [docs/TRIATTENTION-API.md](docs/TRIATTENTION-API.md) — C++ Engine API Reference
- [docs/PROFILES.md](docs/PROFILES.md) — Candidate Profile Benchmarks
- [docs/QUANT-GOD.md](docs/QUANT-GOD.md) — Weight & KV Quantization Extensions
- [docs/beellama-features.md](docs/beellama-features.md) — Inherited DFlash & BeeLlama Features

---

## 🤝 Attribution & Lineage

| Area | Lineage & Upstream Credit |
| :--- | :--- |
| **Base Engine & DFlash** | [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp) |
| **TurboQuant & TCQ** | [TheTom/llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant), [spiritbuun/buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) |
| **TriAttention** | domvox / atomicmilkshake integration via buun lineage |
| **Quantization Extensions** | [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) |
