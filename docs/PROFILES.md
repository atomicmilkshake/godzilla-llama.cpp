# Godzilla recommended profiles

Concrete `llama-server` flag sets for RTX 3080 (10 GB) + 64 GB RAM. All profiles assume CUDA build with `-DGGML_CUDA=ON`, arch 86.

## Profile: `baseline-f16`

Maximum quality reference; highest VRAM.

```
-ngl 99 --flash-attn on -ctk f16 -ctv f16 -c 8192 --jinja
```

## Profile: `turbo-kv` (BeeLlama default sweet spot)

~4× KV compression; requires flash attention.

```
-ngl 99 --flash-attn on -ctk turbo3 -ctv turbo4 -c 8192 --jinja --no-warmup
```

Optional InnerQ calibration (spiritbuun path): set env `TURBO_INNERQ=1` during first prefill window.

When speculative decoding is enabled alongside TriAttention, Godzilla extends the recent-token
protection window by `common_speculative_n_max()` (+2 for DFlash) so draft-verify KV cells are
not pruned mid-cycle.

## Profile: `turbo-tcq`

Trellis-coded KV; better precision at ~2–3 bit effective.

```
-ngl 99 --flash-attn on -ctk turbo2_tcq -ctv turbo3_tcq -c 8192 --jinja
```

## Profile: `turbo-tri` (Godzilla crown)

TurboQuant KV + TriAttention eviction. Requires per-model `.triattention` calibration.

```
-ngl 99 --flash-attn on -ctk turbo3 -ctv turbo4 \
  --triattention-stats path/to/model.triattention \
  --triattention-budget 8192 \
  --triattention-window 128 \
  --triattention-hard-prefix 4096 \
  -c 32768 --jinja --no-warmup
```

Generate calibration:

```powershell
J:\LLM\TurboQuantExperimentation\venv-calibrate\Scripts\python.exe `
  J:\LLM\TurboQuantExperimentation\calibrate.py `
  --model WeiboAI/VibeThinker-3B --output J:\LLM\VibeThinker\vibethinker-3b.triattention `
  --device cuda --n-tokens 2048
```

## Profile: `dflash-spec` (BeeLlama)

Requires draft GGUF (`-md`). See `docs/quickstart-qwen36-dflash.md`.

```
--spec-type dflash -md path/to/draft.gguf --spec-dflash-cross-ctx 512
```

TriAttention + DFlash: use `turbo-tri` flags on target; draft KV pruning is Phase 3 work-in-progress.

## Benchmark tooling

| Script | Purpose |
|--------|---------|
| `scripts/benchmarks/run-engine-preflight.ps1` | Binary capability probe |
| `scripts/benchmarks/run-kv-matrix.ps1` | WikiText PPL across cache types (`llama-perplexity`) |
| `scripts/benchmarks/run-launch-smoke.ps1` | Server health + one chat completion |

**Note:** `llama-perplexity` does not expose TriAttention CLI; use `run-launch-smoke.ps1` or SOMS `launch_smoke` for TriAttention validation.

## SOMS matrix (VibeThinker-3B)

```powershell
pwsh -File J:\LLM\soms\scripts\run_vibethinker_godzilla_spin.ps1
```

Variants: `baseline-8k` on engine `godzilla` (turbo variants removed per KV gate failure).

**Important note (2026-06-20):** Turbo KV configs are **not viable** for this model. KV matrix on godzilla (kv_matrix_20260620_105529.txt) shows f16 baseline PPL=1313; turbo3/turbo4 = 12478 (+850%); most turbo/tcq thousands of % worse. Gate FAIL. Pre-publish sweep therefore uses baseline-8k only for any hot-rod attempt on godzilla (see run-prepublish-sweep.ps1 and journal). Kvarn8 is close to baseline. Use baseline (or suitable kvarn) + tri for this reasoning model.

## Certified hot-rod: Qwopus 9B coder (godzilla)

**Certification date:** 2026-06-19  
**Engine commit:** b579196d1 (kv-god)  
**Model:** Qwopus3.5-9B-coder-Exp-Q4_K_M.gguf (~5.2 GB)  
**Hardware:** RTX 3080 10 GB, `TURBO_INNERQ=1`

**Results (SOMS hot-rod §5):**
- Peak promotion HE (qwen harness): **34/40** (baseline-8k)
- Other strong variants: turbo3-turbo4, turbo3-turbo4-tri also 33–34/40
- Speed frontier: **97.1 tok/s** (baseline-8k)
- NIAH limit profile: **4096 pass**; **8192 HTTP 400** (harness `found=False error=HTTP 400`). 4096 is reliable for this stack.

**Baseline-8k launch args (certified peak):**
```
-ngl 99 --flash-attn on -c 8192 --parallel 1 -b 4096 -ub 128 --jinja --temp 0.2 --top-p 0.95
```
(Note: observed duplicate `-ngl 99` in some launcher output; harmless for this run.)

**Turbo + TriAttention variant (also cleared promotion):**
```
-ngl 99 --flash-attn on -c 8192 -ctk turbo3 -ctv turbo4 --no-warmup --jinja \
  --triattention-stats J:\LLM\TurboQuant-Qwopus-v3-Setup\qwopus3.5-9b-coder-exp.triattention \
  --triattention-budget 8192 --triattention-hard-prefix 4096
```

**TriAttention calibration used:** `qwopus3.5-9b-coder-exp.triattention` (auto-resolved via ensure hook).

**Recommendation:** Use baseline-8k for maximum speed/quality on this 9B. Fall back to turbo3-turbo4-tri when KV cache pressure is high. Both stacks are production-viable on the 10 GB card.

**Evidence:**
- `godzilla-llama.cpp/logs/benchmarks/prepublish_hotrod_summary.tsv` (final row)
- `soms/evidence/prepublish_godzilla_hotrod_qwopus-9b-coder_2026-06-19.jsonl` (rows 6–11)
- Phase 4/5 logs under `soms/logs/godzilla_hotrod/`

See the prepublish sweep plan and godzilla Phase 1.4 for full context.

## Certified hot-rod: Qwopus 4B coder (godzilla)

**Certification date:** 2026-06-19  
**Engine commit:** b579196d1 (kv-god)  
**Model:** Qwopus3.5-4B-coder-Q5_K_M.gguf (~2.9 GB)  

**Results (SOMS hot-rod §5):**
- Peak promotion HE (qwen harness): **29/40** (baseline-8k)
- Speed frontier: **121.1 tok/s** (baseline-8k)
- NIAH limit profile: **4096 pass**; **8192 HTTP 400** (harness prompt budget; same pattern as 9B). 4096 is reliable.

**Baseline-8k launch args:**
```
-ngl 99 --flash-attn on -c 8192 --parallel 1 -b 4096 -ub 128 --jinja --temp 0.2 --top-p 0.95
```
(Note: duplicate -ngl in launcher output.)

**Recommendation:** Baseline-8k is fast (132 tok/s) and solid on HE for 4B. NIAH is weak at 4k+; use for short-context tasks. TriAttention not wired for this small model in the run.

**Evidence:**
- `godzilla-llama.cpp/logs/benchmarks/prepublish_hotrod_summary.tsv` (4B row)
- `soms/evidence/prepublish_godzilla_hotrod_qwopus-4b-coder_2026-06-19.jsonl` (speed and limit rows)
- Manual matrix logs under `soms/logs/godzilla_hotrod/`

See the prepublish sweep plan and godzilla Phase 1.4 for full context.

## KV triage: gemma4-coding (godzilla)

**Engine commit:** b579196d1  
**Artifact:** `logs/benchmarks/kv_matrix_20260619_115543.txt`

**WikiText PPL (ctx=512):**
- f16/f16 baseline: 634.01
- turbo3/turbo4: +9.86% (quality ceiling on hybrid SWA arch — not an engine crash; TriAttention + auto-fit now fully wired for Gemma4-ISWA)
- turbo2_tcq/turbo3_tcq: +31.53%
- kvarn5/kvarn8: PASS (≤2%)
- kvarn2/3/4/6: borderline or FAIL

**Recommendation:** Use f16 or kvarn5/kvarn8 for quality-sensitive work. Turbo KV is viable for speed but expect ~10% PPL drift on this arch. TriAttention smoke pending separate server validation. (See godzilla-triattention-iswa-engine-patch-plan.md for v2 cal path.)

## KV triage: LFM2.5-8B-A1B MoE (godzilla)

**Engine commit:** b579196d1  
**Artifact:** `logs/benchmarks/kv_matrix_20260619_122059.txt`

**WikiText PPL (ctx=512):**
- f16/f16 baseline: 30.556
- **turbo3/turbo4: +1.81% PASS** (head-dim padding fix confirmed)
- turbo2_tcq/turbo3_tcq: +6.95% FAIL
- **All kvarn rows:** context-create FAIL — `n_embd_head_k=64` not 128-slice-compatible (arch limitation)

**Recommendation:** Use turbo3/turbo4 for KV compression on LFM MoE. KVarN unsupported at head_dim 64; do not expect kvarn paths to work without arch changes.

## KV triage: Huihui Opus 9B (godzilla)

**Engine commit:** b579196d1  
**Artifact:** `logs/benchmarks/kv_matrix_20260619_142408.txt` — **KV GATE PASS**

**WikiText PPL (ctx=512):**
- f16/f16 baseline: 10.1222
- turbo3/turbo4: +0.57% PASS
- turbo2_tcq/turbo3_tcq: +0.41% PASS
- kvarn3/4/6/8: ≤0.2% PASS
- kvarn2/kvarn5: intermittent CUDA crash — waived when kvarn4 within gate
- turbo4asym: unsupported in `llama-perplexity` (informational only)

**Recommendation:** Full turbo + KVarN stack production-viable. Prefer kvarn4/kvarn5 over kvarn3 if CUDA intermittency recurs.

## Certified hot-rod: Huihui Opus 9B (godzilla)

**Certification date:** 2026-06-19  
**Engine commit:** b579196d1  
**Model:** Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf (~9.5 GB Q8_0)

**Results (SOMS hot-rod §5):**
- Peak promotion HE (qwen harness): **32/40** (`baseline-8k`)
- Speed frontier: **60.3 tok/s** (`baseline-8k`)
- NIAH limit: **4096 pass**; **8192 HTTP 400** (same harness pattern as Qwopus stacks)

**Baseline-8k launch args (certified peak):**
```
-ngl 99 --flash-attn on -c 8192 --parallel 1 -b 4096 -ub 128 --jinja --temp 0.2 --top-p 0.95
```

**Evidence:**
- `prepublish_hotrod_summary.tsv` (huihui-opus-9b row)
- `soms/evidence/prepublish_godzilla_hotrod_huihui-opus-9b_2026-06-19.jsonl`

## Certified hot-rod: Negentropy Opus 9B (godzilla)

**Certification date:** 2026-06-20  
**Engine commit:** 062058afc (kv-god)  
**Model:** Negentropy-claude-opus-4.7-9B-Q4_K_M.gguf (~5.2 GB)  
**Hardware:** RTX 3080 10 GB

**Results (SOMS hot-rod §5):**
- Peak promotion HE (qwen harness): **32/40** (baseline-8k)
- Other variants tested: turbo3-turbo4 and turbo3-turbo4-tri also reached 32/40 in HE sweeps
- Speed frontier: ~80 tok/s (baseline-8k)
- NIAH limit profile: 8192 HTTP 400 (harness); 4096 reliable in prior patterns

**Baseline-8k launch args (certified peak):**
```
-ngl 99 --flash-attn on -c 8192 --parallel 1 -b 4096 -ub 128 --jinja --temp 0.2 --top-p 0.95
```

**TriAttention calibration used:** J:\LLM\TurboQuant-Qwopus-v3-Setup\negentropy-opus-9b.triattention (per roster)

**Recommendation:** Baseline-8k is the certified hot-rod path. Turbo stacks produced acceptable HE in the run but were not the peak; use only if KV pressure requires (full matrix showed small delta). TriAttention viable on baseline for quality.

**Evidence:**
- `godzilla-llama.cpp/logs/benchmarks/prepublish_hotrod_summary.tsv` (negentropy row)
- `godzilla-llama.cpp/logs/benchmarks/prepublish_sweep_newmodels_20260620.log` (multiple HE phases + final "Peak: 32/40 @ baseline-8k | Hot rod: CERTIFIED")
- `soms/evidence/prepublish_godzilla_hotrod_negentropy-opus-9b_2026-06-20.jsonl`
- `kv_matrix_20260620_110341.txt`

See the prepublish sweep plan and godzilla Phase 1.4 for full context.

## Sweep viability notes from 2026-06-20 new-wave batch (prepublish_sweep_newmodels_20260620.log + kv_matrix + TSVs; halted mid-run by operator)

**vibethinker-3b:**
- KV gate: FAIL on all turbo/tcq (e.g. turbo3/turbo4 +850% PPL vs f16=1313); kvarn8 near baseline (-0.18%).
- Hot-rod: Skipped (turbo variants incompatible); baseline-8k is only viable stack.
- Tri path: J:\LLM\VibeThinker\vibethinker-3b.triattention present.
- Action in roster/sweep: Turbo variants removed from godzilla block; Variant forced to baseline-8k.

**negentropy-opus-9b:**
- KV gate: PASS (small deltas on turbo ~0.5%).
- Hot-rod: CERTIFIED on baseline-8k (32/40 peak).
- Multiple variant HE runs completed (baseline, turbo, tri).
- Viable: baseline preferred for cert; turbo/tri acceptable per HE.

**fablevibes-14b-moe:**
- KV run started (f16 PPL ~17.81; turbo3/turbo4 ~17.93 ~+0.67% at cutoff); incomplete due to halt.
- MoE path uses -ncmoe 32.
- Tri path: J:\LLM\TurboQuant-Qwopus-v3-Setup\qwen36-14b-fablevibes.triattention
- Viability: Turbo removed from godzilla roster pending full KV confirmation <=2%; baseline-8k + ncpu32 only for now. Sweep halted before hot-rod.

**huihui-gemma-4-12b:**
- KV not reached in halted sweep log (after negentropy).
- Native Gemma4 (non-hybrid SWA per notes); no ISWA dual-head issue expected.
- Tri path set in roster.
- Viability: Baseline only wired; turbo variants removed per incompatibility principle until KV matrix confirms. May need v1 cal or re-cal.

**gemma4-coding (re-triage context):**
- Turbo quality regression confirmed (+9.86%); hybrid ISWA requires v2 .triattention per dedicated engine patch plan.
- KV PASS only on specific kvarn; not hot-rod cert path yet.
- Status: QUEUED in TSV; halted; engine fixes + v2 re-cal required before resume.

All wiring respects the "only use features that pass KV gate for that model" principle. Full 4-model sweep not completed; hot-rod certs limited to negentropy + prior 3. Update TSVs/PROFILES/roster/journal after resume.

See prepublish sweep plan for gates and godzilla-comprehensive-fix-plan.md for harness/TSV status (BENCH-01 etc still open).

## Certified models summary table (from prepublish_hotrod_summary.tsv cleaned 2026-06-20)

| Model | Peak HE | Speed | NIAH | Cert | Commit |
|-------|---------|-------|------|------|--------|
| qwopus-9b-coder | 34/40 | PASS | 4096 | CERTIFIED | b579196d1 |
| qwopus-4b-coder | 29/40 | PASS (~121-132 t/s) | 4096 | CERTIFIED | b579196d1 |
| huihui-opus-9b | 32/40 | PASS (~60 t/s) | 4096 | CERTIFIED | b579196d1 |
| negentropy-opus-9b | 32/40 | PASS (~80 t/s) | mixed/HTTP400 | CERTIFIED | 062058afc |

See the prepublish sweep plan and godzilla Phase 1.4 for full context.