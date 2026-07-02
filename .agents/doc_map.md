# Centralized Documentation Map

This index categorizes all documentation and notes within this repository to help agents find the correct context quickly.

---

## 🚀 1. Core Feature Guides & Speculative Decoding
- [beellama-features.md](file:///J:/LLM/godzilla-llama.cpp/docs/beellama-features.md) — Comprehensive feature matrix comparing upstream `llama.cpp` with the BeeLlama fork (details on DFlash, DDTree, CopySpec, TurboQuant, and the Loop Guard).
- [speculative.md](file:///J:/LLM/godzilla-llama.cpp/docs/speculative.md) — Architectural overview of speculative decoding implementations.
- [beellama-args.md](file:///J:/LLM/godzilla-llama.cpp/docs/beellama-args.md) — Complete argument reference for BeeLlama CLI and server configurations.
- [quickstart-qwen36-dflash.md](file:///J:/LLM/godzilla-llama.cpp/docs/quickstart-qwen36-dflash.md) — Step-by-step guide for setting up Qwen 3.6 with DFlash speculation on a single GPU.
- [quickstart-gemma-4-31b-dflash.md](file:///J:/LLM/godzilla-llama.cpp/docs/quickstart-gemma-4-31b-dflash.md) — Quickstart for running Gemma 2/4 models with DFlash.

## ⚡ 2. Quantization, Cache, & Hardware Offload
- [QUANT-GOD.md](file:///J:/LLM/godzilla-llama.cpp/docs/QUANT-GOD.md) — Technical details of the custom quantizers (TurboQuant) and Cache types (`turbo2`, `turbo3`, `turbo4`, and TCQ formats).
- [TRIATTENTION.md](file:///J:/LLM/godzilla-llama.cpp/docs/TRIATTENTION.md) — Technical implementation details of TriAttention.
- [TRIATTENTION-API.md](file:///J:/LLM/godzilla-llama.cpp/docs/TRIATTENTION-API.md) — C/C++ APIs for interfacing with TriAttention.
- [multi-gpu.md](file:///J:/LLM/godzilla-llama.cpp/docs/multi-gpu.md) — Rules, limits, and memory layout conventions for multi-GPU hardware setups.

## 🛠️ 3. Platform Setup & Build Instructions
- [build.md](file:///J:/LLM/godzilla-llama.cpp/docs/build.md) — General compilation guide for Linux, Windows, macOS (CUDA, CPU, Metal).
- [LOCAL-SETUP.example.md](file:///J:/LLM/godzilla-llama.cpp/docs/LOCAL-SETUP.example.md) — Guide for setting up developer environment configurations.
- [install.md](file:///J:/LLM/godzilla-llama.cpp/docs/install.md) — Brief overview of installation workflows.
- [docker.md](file:///J:/LLM/godzilla-llama.cpp/docs/docker.md) — Running and building docker containers for llama.cpp.
- [android.md](file:///J:/LLM/godzilla-llama.cpp/docs/android.md) — Android-specific compilation and deployment steps.
- [build-riscv64-spacemit.md](file:///J:/LLM/godzilla-llama.cpp/docs/build-riscv64-spacemit.md) — Detailed build details for Spacemit RISC-V.
- [build-s390x.md](file:///J:/LLM/godzilla-llama.cpp/docs/build-s390x.md) — IBM s390x mainframe compilation instructions.

## 🤖 4. Interfaces, Schemas, & API Integration
- [function-calling.md](file:///J:/LLM/godzilla-llama.cpp/docs/function-calling.md) — Guide on JSON schemas, grammars, and function-calling parameters.
- [llguidance.md](file:///J:/LLM/godzilla-llama.cpp/docs/llguidance.md) — Integration guide for structured generation with the LLGuidance library.
- [multimodal.md](file:///J:/LLM/godzilla-llama.cpp/docs/multimodal.md) — Processing multimodal input pipelines (e.g. LLaVA, CLIP) alongside speculative features.
- [preset.md](file:///J:/LLM/godzilla-llama.cpp/docs/preset.md) — Description and configuration specification of INI preset files.
- [CADRE-INTEGRATION.md](file:///J:/LLM/godzilla-llama.cpp/docs/CADRE-INTEGRATION.md) — Details on integrating the CADRE speculative decoding framework.

## ⚙️ 5. Deployment, Workflows, & Operations
- [ops.md](file:///J:/LLM/godzilla-llama.cpp/docs/ops.md) — Production operations guide, monitoring patterns, and deployment configurations.
- [godzilla-upstream-sync-process.md](file:///J:/LLM/godzilla-llama.cpp/docs/godzilla-upstream-sync-process.md) — Git workflow and upstream synchronization process for maintaining the fork.
- [autoparser.md](file:///J:/LLM/godzilla-llama.cpp/docs/autoparser.md) — Automated CLI and server argument parsing docs.

## 🔬 6. Research & Performance Notes
- [ubatch-vram-deflate.md](file:///J:/LLM/godzilla-llama.cpp/notes/ubatch-vram-deflate.md) — Internal research/notes on VRAM deflation using micro-batch size adjustments.
