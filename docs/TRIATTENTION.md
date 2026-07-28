# TriAttention — status and lab policy (read this first)

## Status: not recommended · opt-in only · no auto-calibration

**Lab decision (2026-07-28):** TriAttention is **not** part of default testing, hotrod, or serve recipes.

| Rule | Detail |
|------|--------|
| Default | **OFF.** Nothing runs TriAttention unless you pass flags. |
| Enable | Explicit `--triattention-stats <path.triattention>` (and related flags only with stats). |
| Auto-calib | **No.** This engine does not invent a stats file. Offline calib is a separate manual tool if you insist. |
| Lab / Vandelay | Hard-banned in product paths (`triattention_ban`). Do not re-enable without new measured proof + explicit user order. |

## Why

Independent reimplementation and lab hotrods showed:

- Paper-faithful eviction is not a safe default (PPL hit and silent needle drops).
- Hybrid V3 still fails retrieval on hybrid architectures while PPL can look fine.
- Long retrieval needs a rescue layer; bare eviction is one-way loss.
- On this lab board, tri almost never wins vs `fa+kv-q8` / `fa+kv-ram` / draft paths; it costs calib and wall time.

The Mao et al. paper (arXiv:2604.04921) is scoped to long reasoning CoT. That is **not** a general production guarantee.

## Prefer instead

- Flash attention + solid KV types (`q8_0`, `kvarn3`, turbo when measured)
- `--kv-ram` / RAM-KV ladders for long context
- Speculative: DFlash / DSpark / native MTP when the model supports them
- Real RAG / longer native context over irreversible eviction

## If you still enable it (explicit only)

1. Manually produce a `.triattention` stats file with an offline calibrator.
2. Pass **only** when you mean it:

```bash
./llama-server \
  -m model.gguf \
  --triattention-stats /path/to/model.triattention \
  --triattention-budget 2048 \
  --triattention-window 128 \
  -fa on -c 32768 -ngl 99
```

3. Measure **NIAH / multi-fact retrieval**, not only PPL or GSM8K.
4. Tuning flags without `--triattention-stats` are rejected by the CLI (by design).

## Implementation notes

- Runtime: CLI + engine hooks in this fork (CUDA scoring paths exist).
- API detail: [TRIATTENTION-API.md](TRIATTENTION-API.md)
- **Code presence ≠ product recommendation.** Shipping the feature is not an endorsement.

## History

Earlier docs claimed large combined compression with TurboQuant. Treat those as **aspirational / paper-envelope** claims, not verified lab defaults. Lab front page and Vandelay hotrod no longer promote TriAttention.
