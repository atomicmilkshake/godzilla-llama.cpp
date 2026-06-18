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

Variants: `baseline-8k`, `turbo3-turbo4-8k`, `turbo3-turbo4-tri-8k` on engine `godzilla`.