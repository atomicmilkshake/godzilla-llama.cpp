# Godzilla Integration Plan — King of the Monsters

Verified recon 2026-07-16. Goal: aggregate every cutting-edge optimization from the
llama.cpp-class forks under `J:\LLM\engines` into the godzilla tree.

## Base state (verified)
- godzilla HEAD is **59 commits behind** `llama-org/master` (merge-base 2026-07-08).
- `GGML_TYPE` enum: slots **0..61 used**, `GGML_TYPE_COUNT = 62`. Next free = **62**.
- Already integrated: TurboQuant turbo2/3/4 + TCQ (42-46,55), TQ3_1S/TQ4_1S weight (47,48),
  BitNet I2_S/I8_S/TL1/TL2 (56-59), ik IQ2_BN/Q8_K64 (60,61), Q1_0 (41), Q2_0/Q2_1 (53,54),
  Q3_0/Q3_1 (51,52), Q6_0/Q6_1 (49,50), DFlash, MTP, DeepSeek-3.2 indexer (deepseek32.cpp),
  GLM-DSA arch (glm-dsa.cpp), adaptive_p sampler, adaptive-DM controllers, TriAttention.

## Remotes wired
origin, llama-org, upstream/beellama-upstream, buun-source, tq3-source, bitnet-upstream,
autowheel (AutoWHEELx2/llama.cpp--mmproj-swap-layers-ByGemini-3.5-pro).
Not-yet-added: ik_llama, prism, atomic, johndpope, alesha (all cloned locally under engines/).

## Execution order (each item = own branch, build-verified before merge to godzilla)

### Tier 1 — clean, self-contained, no enum conflict
1. **mmproj layer-swap** (AutoWHEELx2) — 589 lines, new files `common/llama_mmproj_pool.{cpp,h}`
   + hooks in clip/mtmd/server-context/ggml-backend/arg. VRAM valve for vision projectors.
2. **K-cache mean-centering** `--kv-mean-center` (prism) — softmax-invariant Q4_0 K quality win.
   Files: `tools/kv-mean-center/`, guards in llama-kv-cache/context/graph. Measured KLD 0.00144->0.00111.
3. **spec-tuner** (ik) — epsilon-greedy MAB online spec-decode tuner. `common/spec-tuner.{h,cpp}`.
4. **variance-based checkpoint eviction** (ik) — smarter-than-LRU prompt-cache eviction. server-context.

### Tier 2 — medium, new ggml op
5. **fused GGML_OP_LIGHTNING_INDEXER** (mainline #24231 via autowheel) — replaces composed-op
   indexer in deepseek32.cpp with a fused kernel. New op enum + CPU/CUDA impl.

### Tier 3 — enum surgery + big subsystems (one branch each, converter + GGUF migration)
6. **PlanarQuant + IsoQuant rotor family** (johndpope) — 4 new KV types at FRESH slots 62-65
   (NOT johndpope's colliding 41-47). Files ggml-planar-quant.c, ggml-iso-quant.c, cpy-planar-iso.cu.
7. **FlashMLA + IQK GEMM/FA + _K/_KT/_R4 quants** (ik_llama) — import ggml/src/iqk/ subtree,
   iqk_mmvq CUDA, MLA Pascal routing. Largest port. Enum renumber required.
8. **DSV4 sparse-FA + constant-shape CUDA-graph decode + MoE MMQ tiling** (alesha) — env-gated
   DSV4_* deltas; take model + kv-cache-dsa + ggml-op deltas together.
9. **DSpark block-diffusion drafter** (prism) — new arch + multi-layer hidden-state capture API.
   Evaluate vs existing DFlash (same EAGLE family) before landing to avoid duplication.

### Tier 4 — new eval path (from scratch, not a merge)
10. **AirLLM-style streaming layer loader** — lazy per-block GGUF load + evicting scheduler +
    disk->pinned->GPU double-buffer prefetch. Memory-win-not-speed-win, disk-bandwidth-bound.

## Known hard conflicts (verified)
- johndpope renumbers TURBO2/3/4 (41/42/43) and reuses 44-47 for Planar/Iso — collides with
  godzilla's TCQ/weight slots. MUST reassign to 62+ and ship a converter.
- ik's IQK engine is an alternate CPU compute backend; piecemeal port not possible — import subtree.
- prism Q2_0=42 vs godzilla Q2_0=53 — already have Q2_0, skip prism's; keep godzilla numbering.

## Build
CUDA sm_86, VS18, CUDA 13.2, WADK S:\WADK102. One-shot: `rebuild_king.cmd`. Full build is slow;
prefer targeted per-TU compile checks during dev, full rebuild before declaring a tier done.
