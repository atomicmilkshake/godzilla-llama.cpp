# Centralized Documentation Map

This index categorizes all documentation and notes within this repository to help agents find the correct context quickly.

---

## 🚀 1. Core Feature Guides & Speculative Decoding
- [beellama-features.md](../docs/beellama-features.md) — Comprehensive feature matrix comparing upstream `llama.cpp` with the BeeLlama fork (details on DFlash, DDTree, CopySpec, TurboQuant, and the Loop Guard).
- [speculative.md](../docs/speculative.md) — Architectural overview of speculative decoding implementations.
- [beellama-args.md](../docs/beellama-args.md) — Complete argument reference for BeeLlama CLI and server configurations.
- [quickstart-qwen36-dflash.md](../docs/quickstart-qwen36-dflash.md) — Step-by-step guide for setting up Qwen 3.6 with DFlash speculation on a single GPU.
- [quickstart-gemma-4-31b-dflash.md](../docs/quickstart-gemma-4-31b-dflash.md) — Quickstart for running Gemma 2/4 models with DFlash.

## ⚡ 2. Quantization, Cache, & Hardware Offload
- [QUANT-GOD.md](../docs/QUANT-GOD.md) — Technical details of the custom quantizers (TurboQuant) and Cache types (`turbo2`, `turbo3`, `turbo4`, and TCQ formats).
- [TRIATTENTION.md](../docs/TRIATTENTION.md) — Technical implementation details of TriAttention.
- [TRIATTENTION-API.md](../docs/TRIATTENTION-API.md) — C/C++ APIs for interfacing with TriAttention.
- [multi-gpu.md](../docs/multi-gpu.md) — Rules, limits, and memory layout conventions for multi-GPU hardware setups.

## 🛠️ 3. Platform Setup & Build Instructions
- **[AGENT-BUILD-WORKFLOW.md](../docs/AGENT-BUILD-WORKFLOW.md) — LAB agents: reliable Windows rebuild (one ninja, detached, stage release-bin, MTP fix).** Start with `python scripts/agent_bootstrap_godzilla.py`.
- **[WINDOWS-BUILD-TOOLCHAIN.md](../docs/WINDOWS-BUILD-TOOLCHAIN.md) — LAB UCRT/VS/CUDA pins** (`S:\WADK102`, never invent paths).
- [build.md](../docs/build.md) — General compilation guide for Linux, Windows, macOS (CUDA, CPU, Metal).
- [LOCAL-SETUP.example.md](../docs/LOCAL-SETUP.example.md) — Guide for setting up developer environment configurations.
- [install.md](../docs/install.md) — Brief overview of installation workflows.
- [docker.md](../docs/docker.md) — Running and building docker containers for llama.cpp.
- [android.md](../docs/android.md) — Android-specific compilation and deployment steps.
- [build-riscv64-spacemit.md](../docs/build-riscv64-spacemit.md) — Detailed build details for Spacemit RISC-V.
- [build-s390x.md](../docs/build-s390x.md) — IBM s390x mainframe compilation instructions.
- Scripts: `scripts/rebuild_incremental.cmd`, `scripts/rebuild_detached.cmd`, `rebuild_king.cmd`, `scripts/env-godzilla-msvc.cmd`, `scripts/stage-release-bin.ps1`.

## 🤖 4. Interfaces, Schemas, & API Integration
- [function-calling.md](../docs/function-calling.md) — Guide on JSON schemas, grammars, and function-calling parameters.
- [llguidance.md](../docs/llguidance.md) — Integration guide for structured generation with the LLGuidance library.
- [multimodal.md](../docs/multimodal.md) — Processing multimodal input pipelines (e.g. LLaVA, CLIP) alongside speculative features.
- [preset.md](../docs/preset.md) — Description and configuration specification of INI preset files.
- [CADRE-INTEGRATION.md](../docs/CADRE-INTEGRATION.md) — Details on integrating the CADRE speculative decoding framework.

## ⚙️ 5. Deployment, Workflows, & Operations
- [ops.md](../docs/ops.md) — Production operations guide, monitoring patterns, and deployment configurations.
- [godzilla-upstream-sync-process.md](../docs/godzilla-upstream-sync-process.md) — Git workflow and upstream synchronization process for maintaining the fork.
- [autoparser.md](../docs/autoparser.md) — Automated CLI and server argument parsing docs.

## 🔬 6. Research & Performance Notes
- [ubatch-vram-deflate.md](../notes/ubatch-vram-deflate.md) — Internal research/notes on VRAM deflation using micro-batch size adjustments.
