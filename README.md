# Godzilla llama.cpp

[![Release](https://img.shields.io/github/v/release/atomicmilkshake/godzilla-llama.cpp)](https://github.com/atomicmilkshake/godzilla-llama.cpp/releases)
[![Build Status](https://img.shields.io/github/actions/workflow/status/atomicmilkshake/godzilla-llama.cpp/release.yml?branch=godzilla)](https://github.com/atomicmilkshake/godzilla-llama.cpp/actions)
[![License](https://img.shields.io/github/license/atomicmilkshake/godzilla-llama.cpp)](LICENSE)

Windows-first **MSVC + CUDA** fork of [beellama.cpp](https://github.com/Anbeeld/beellama.cpp) / [llama.cpp](https://github.com/ggml-org/llama.cpp). Built for this lab’s RTX 3080 (sm_86) + long-context work: fused GDN/KDA paths, KV placement options, TurboQuant/TCQ cache types when the build supports them, and speculative draft (DFlash / DSpark / MTP).

**What this is not:** a universal “10× free lunch” engine. Numbers below are **lab measurements on one box**, not marketing SLAs. Features ship when they work; features that fail transfer stay opt-in or off.

### Honest defaults

| Path | Status |
| :--- | :--- |
| Flash attention + `q8_0` / measured KV | **Default recommendation** |
| `--kv-ram` / RAM-KV long context | Preferred for long windows on 10 GB VRAM |
| DFlash / DSpark / MTP | Use when the model has a real draft/MTP companion |
| TurboQuant / TCQ KV | Opt-in; verify quality per model |
| **TriAttention** | **Not recommended.** Off unless you pass explicit `--triattention-stats`. **No auto-calibration.** See [docs/TRIATTENTION.md](docs/TRIATTENTION.md) |

### What Godzilla adds (relative to stock)

| Area | Notes |
| :--- | :--- |
| **KDA / FlashKDA** | CUDA `gated_delta_net_cuda<…, KDA=true>` path; `LLM_ARCH_KIMI_LINEAR` |
| **GDN** | Fused GDN on by default for supported archs; `--no-fused-gdn` for isolation |
| **KV surface** | Classic quants + turbo/TCQ/KVarN where compiled; `-ctk` / `-ctv` |
| **Memory** | `--kv-ram`, `--kv-vram-only`, chunked prefill (`-ub`) |
| **Speculative** | DFlash, DSpark, native `draft-mtp`, CopySpec |
| **Windows build** | Documented MSVC + UCRT + CUDA pin (see build docs) |

---

## Lab leaderboard (measured winners)

**Hardware:** RTX **3080 10 GB** · **64 GB** DDR4  
**Source:** VandelayNexus overnight hotrod winners (profile names are lab labels).  
**Note:** Rows are “what won on this box,” not claims that every install will match.

| Model | Arch | Winning profile | Decode (tok/s) | Notes |
| :--- | :--- | :--- | :---: | :--- |
| Bonsai 27B | qwen35 GDN | `godzilla:fa+gdn+kv-q8` | 44.27 | 64K stable · fused GDN |
| VibeThinker 3B | qwen2 | `godzilla:fa+kv-q8` | 160.21 | FA + Q8 KV |
| Qwythos 9B 1M | qwen35 GDN | `godzilla:fa+gdn+kv-q8` | 88.65 | long-ctx GDN path |
| Ornith 9B MTP | qwen35 GDN | `godzilla:fa+gdn+kv-q8` | 75.74 | 64K · fused GDN |
| Astrea 9B | qwen35 GDN | `godzilla:fa+kv-q8+nofused` | 41.15 | quality gate pass |
| Qwen 3.6 14B MoE | qwen35moe | `godzilla:fa+ncmoe20+kv-q8` | 43.21 | `ncmoe20` |
| Laguna XS-2.1 Q4 | laguna MoE | `godzilla:fa+ncmoe20+kv-q8` | 7.73 | MoE offload |
| Laguna XS-2.1 MXFP4 | laguna | `godzilla:fa+draft(dflash)` | 4.68 | DFlash draft |
| ThinkingCap 27B | qwen35 MTP | `godzilla:fa+draft(mtp)` | 4.18 | native MTP |

TriAttention profiles are **not** promoted here; they rarely won and are out of default test matrix.

---

## ⚡ Spotlight — v0.3.7: Kimi Delta Attention (KDA / FlashKDA)

**v0.3.7** is the KDA release: Gated Linear Attention moves from aspiration to **hardware-backed recurrence**.

### Zero-stub CUDA kernel

Real kernel path — not a CPU fallback dressed as CUDA:

```text
gated_delta_net_cuda<…, KDA=true>
```

Located in `ggml/src/ggml-cuda/gated_delta_net.cu`, with compile-time `KDA` specialization for head dims **16 / 32 / 64 / 128**.

### Recurrent memory update

Kimi Delta Attention maintains a compressed linear state \(S_t\) with **O(1)** memory growth in sequence length:

$$
S_t = \bigl(I - \beta_t\, k_t k_t^{\mathsf{T}}\bigr)\,\mathrm{Diag}(\alpha_t)\, S_{t-1} + \beta_t\, k_t v_t^{\mathsf{T}}
$$

| Symbol | Role |
| :--- | :--- |
| \(S_t\) | Recurrent memory state at step \(t\) |
| \(k_t, v_t\) | Key / value projections |
| \(\beta_t\) | Mixing coefficient (learned gate, sigmoid-activated) |
| \(\mathrm{Diag}(\alpha_t)\) | Per-dimension decay / retention gate |
| \(I - \beta_t k_t k_t^{\mathsf{T}}\) | Rank-1 delta update (write + forget in one step) |

This is the mathematical core of **FlashKDA-style Gated Linear Attention**: constant-size state, long-horizon retention, CUDA-resident transitions.

### `LLM_ARCH_KIMI_LINEAR` architecture

Native architecture id:

| Enum | GGUF name | Graph |
| :--- | :--- | :--- |
| `LLM_ARCH_KIMI_LINEAR` | `"kimi-linear"` | Hybrid **KDA linear recurrence** + periodic **MLA** layers |

Implementation lives in `src/models/kimi-linear.cpp`: causal conv1d on Q/K/V, \(\beta\) / \(g_1\) gating, and `ggml_kda_scan` recurrence — wired end-to-end for **million-token context scaling**.

### Auto-fused GDN flags

| Flag | Behavior |
| :--- | :--- |
| **Default** | Fused CUDA Gated DeltaNet / KDA kernels **on** |
| `--no-fused-gdn` | Isolation fallback — disable fused GDN for debug / backend parity |

Fused GDN keeps accept-path and decode-path recurrent updates on the fast kernel lane; the kill switch exists so you can A/B kernel vs graph without rebuilding.

---

## Long-context stack (lab recipe — without TriAttention)

Practical composition on this box: **compress or page KV**, keep prefill bounded, extend RoPE when needed, then add speculation. **Do not enable TriAttention by default.**

| Layer | Mechanism | Role |
| :---: | :--- | :--- |
| 1 | FA + measured KV type (`q8_0`, `q4_0`, kvarn/turbo when verified) | Fewer bytes per token |
| 2 | `--kv-ram` or lower `-c` | Long windows when VRAM is tight |
| 3 | Chunked prefill (`-ub 512`) | Cap peak VRAM during prompt ingest |
| 4 | YaRN (`--rope-scaling yarn`, `--rope-freq-scale`) | Extended context when the model needs it |
| 5 | DFlash / DSpark / MTP | Throughput when a real draft/MTP path exists |
| 6 | ~~TriAttention eviction~~ | **Not default.** Code exists; lab policy is off. See [docs/TRIATTENTION.md](docs/TRIATTENTION.md) |

---

## Quickstart — `llama-server`

Binaries from a Godzilla build or release pack. On Windows, run from the package directory so CUDA/OpenSSL DLLs resolve.

### 1. Long context with RAM-KV (recommended default pattern)

```bash
./llama-server \
  -m /path/to/model.gguf \
  --port 8080 \
  -ngl 99 -fa on \
  -c 524288 \
  --kv-ram \
  -ctk q4_0 -ctv q4_0 \
  -ub 512 \
  --rope-scaling yarn --rope-freq-scale 0.25
```

**Windows:**

```powershell
.\llama-server.exe `
  -m D:\models\target.gguf `
  --port 8080 `
  -ngl 99 -fa on `
  -c 524288 `
  --kv-ram `
  -ctk q4_0 -ctv q4_0 `
  -ub 512 `
  --rope-scaling yarn --rope-freq-scale 0.25
```

Optional turbo/TCQ cache types only after you verify quality on *your* model.

### 2. VRAM-only KV (`--kv-vram-only`)

Pin the KV cache on GPU even when weights stay mostly in system RAM:

```bash
./llama-server \
  -m /path/to/model.gguf \
  -ngl 1 \
  --kv-vram-only \
  -fa on \
  -c 65536
```

> Mutually exclusive with `--kv-ram` and `-nkvo` / `--no-kv-offload`.

### 3. DFlash speculative draft acceleration

```bash
./llama-server \
  -m /path/to/target.gguf \
  --spec-type dflash \
  --spec-draft-model /path/to/draft.gguf \
  --spec-draft-n-max 8 \
  --spec-dflash-cross-ctx 512
```

### 4. Native MTP speculative path

```bash
./llama-server \
  -m /path/to/target-with-mtp.gguf \
  --spec-type draft-mtp \
  -fa on \
  -c 32768 \
  -ngl 99
```

### 5. KDA / kimi-linear (fused GDN default)

```bash
./llama-server \
  -m /path/to/kimi-linear.gguf \
  -ngl 99 -fa on \
  -c 131072 \
  --port 8080
# Debug isolation only:
#   --no-fused-gdn
```

---

## 🧠 More architecture firepower

### Sub-4bit & advanced KV surface

| Family | Examples | Role |
| :--- | :--- | :--- |
| **TurboQuant** | `turbo2`, `turbo3`, `turbo4` | Aggressive KV compression |
| **TCQ** | `turbo2_tcq`, `turbo3_tcq` | TCQ-coded KV variants |
| **Classic** | `q4_0`, `q5_0`, `q6_0`, `q8_0`, … | Portable baselines |
| **KVarN** | KVarN manager / pseudo-types | Extended KV control plane |

Set independently: `-ctk` / `--cache-type-k` and `-ctv` / `--cache-type-v`.

### Speculative decoding matrix

| Mode | Flag | Notes |
| :--- | :--- | :--- |
| **DFlash** | `--spec-type dflash` | Hidden-state cross-attention draft GGUF |
| **MTP** | `--spec-type draft-mtp` | Native multi-token prediction headers |
| **CopySpec** | `--spec-type copyspec` | Model-free rolling-hash suffix match |
| **Adaptive DM** | profit / fringe controllers | Runtime draft-horizon control |

### Hybrid & specialty models

- **Kimi Linear** (`LLM_ARCH_KIMI_LINEAR`) — KDA + MLA hybrid  
- **Qwen 3.5 / 3.6** — MoE, MTP conversion remaps (`mtp_layer*` → `mtp.`)  
- **Laguna** — `LLM_ARCH_LAGUNA` load/graph path  
- **Gemma 4** — multimodal / ISWA paths from modern base  
- **BitNet** — optional `GGML_BITNET_*` CPU I2_S stack  

### Memory placement controls

| Control | Purpose |
| :--- | :--- |
| `--kv-ram` | UVM / system-RAM-backed KV paging |
| `--kv-vram-only` | Force KV on VRAM with low `-ngl` weight offload |
| `-ngl` | Layer offload count |
| `-ub` / `-b` | µbatch / batch for prefill VRAM shape |

---

## 🛠️ Build — MSVC + CUDA (Windows king path)

### Windows (MSVC + CUDA 13.2 / 12.x)

Lab-hardened path (preferred on this tree):

```bat
rebuild_king.cmd
```

Or configure + build:

```powershell
cmake -S . -B build -G Ninja `
  -DGGML_CUDA=ON `
  -DGGML_NATIVE=ON `
  -DGGML_CUDA_FA=ON `
  -DGGML_CUDA_FA_ALL_QUANTS=ON `
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release --parallel --target llama-server llama-cli
```

> **Windows toolchain truth:** VS `vcvars` often finds WDK um/shared but **omits UCRT** → `LNK1104: ucrtd.lib`. Use `scripts/env-godzilla-msvc.cmd` / `docs/WINDOWS-BUILD-TOOLCHAIN.md` — do not invent UCRT paths.

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

### macOS (Metal / Apple Silicon)

```bash
cmake -B build -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Stage a complete runtime pack after Windows builds (`scripts/stage-release-bin.ps1`) so CUDA + OpenSSL DLLs ship with the PE.

---

## Milestone board

| Milestone | Status |
| :--- | :---: |
| Single-branch Godzilla integration line | done |
| KV stack (TurboQuant / TCQ + KVarN surfaces) | done (measure per model) |
| DFlash + adaptive controllers + loop guard | done |
| `--kv-vram-only` GPU memory allocator | done |
| Long-context RAM-KV / chunked prefill recipes | done |
| KDA zero-stub CUDA + `LLM_ARCH_KIMI_LINEAR` + fused GDN | done (v0.3.7 line) |
| TriAttention code present | yes — **not recommended / not default** |

---

## 📖 Documentation index

| Doc | Topic |
| :--- | :--- |
| [docs/WINDOWS-BUILD-TOOLCHAIN.md](docs/WINDOWS-BUILD-TOOLCHAIN.md) | MSVC / UCRT / CUDA pin map |
| [docs/AGENT-BUILD-WORKFLOW.md](docs/AGENT-BUILD-WORKFLOW.md) | Reliable agent rebuild workflow |
| [docs/TRIATTENTION.md](docs/TRIATTENTION.md) | **TriAttention policy: not recommended, opt-in only, no auto-calib** |
| [docs/TRIATTENTION-API.md](docs/TRIATTENTION-API.md) | C++ API (historical / explicit use) |
| [docs/QUANT-GOD.md](docs/QUANT-GOD.md) | Weight & KV quantization extensions |
| [docs/beellama-features.md](docs/beellama-features.md) | DFlash, GDN, speculative inheritance |
| [docs/beellama-args.md](docs/beellama-args.md) | Full CLI / env surface |
| [docs/BITNET.md](docs/BITNET.md) | BitNet I2_S build & serve |
| [docs/CADRE-INTEGRATION.md](docs/CADRE-INTEGRATION.md) | Cadre / recurrent expand notes |
| [GODZILLA_KING.md](GODZILLA_KING.md) | Lab integration map & remotes |

---

## 🤝 Attribution & lineage

Godzilla is an **integration engine**: it intentionally absorbs best-in-class work from multiple llama.cpp-class trees.

| Area | Credit |
| :--- | :--- |
| **Base engine & DFlash** | [Anbeeld/beellama.cpp](https://github.com/Anbeeld/beellama.cpp) |
| **Upstream llama.cpp** | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) |
| **TurboQuant / TCQ** | [TheTom/llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant), [spiritbuun/buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) |
| **TriAttention (legacy / opt-in)** | domvox / buun lineage; lab does **not** recommend default use |
| **Quantization extensions** | [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) |
| **BitNet** | [microsoft/BitNet](https://github.com/microsoft/BitNet) |

---

## 🔗 Releases & support

- **Latest binaries / notes:** [GitHub Releases](https://github.com/atomicmilkshake/godzilla-llama.cpp/releases)  
- **Current spotlight tag:** **v0.3.7** — KDA zero-stub · FlashKDA recurrence · kimi-linear · fused GDN  
- **Issues / discussion:** use the GitHub issue tracker on this repository  

---

### GitHub About (truthful)

| Field | Text |
| :--- | :--- |
| **Description** | MSVC+CUDA llama.cpp fork for Windows: KDA/GDN, long-context KV placement, TurboQuant/TCQ when measured, speculative draft. Lab-measured defaults — TriAttention opt-in only, not recommended. |

Written to `J:\LLM\engines\godzilla-llama.cpp\README.md`. Say if you want this committed/pushed and the GitHub release notes for **v0.3.7** aligned.
