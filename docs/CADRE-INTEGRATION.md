# Cadre integration with godzilla-llama.cpp

**Consumer:** [Cadre](file:///V:/cadre) eval harness and managed `llama-server` on port **8090**.  
**Engine:** `J:\LLM\godzilla-llama.cpp` branch **`main`**.

---

## Quick start

```powershell
# Rebuild godzilla (MSVC + CUDA via vcvars)
V:\cadre\scripts\rebuild-godzilla.bat

cd V:\cadre
python -m cadre server start
python -m cadre eval humaneval --mode coder --limit 5 --no-live
```

Success: all problems complete without `openai.APIConnectionError` / `httpx.ConnectError` to `:8090`.

Stability regression (coder + think tank):

```powershell
python V:\cadre\scripts\benchmark_modes.py 5
```

---

## Recommended server flags (Cadre `settings.yaml`)

Typical hybrid thinking model on RTX 3080 + 64 GB RAM:

```text
--allow-extended-ctx
--kv-ram
--flash-attn on
--parallel 1
--jinja
--reasoning on
--no-reasoning-promote-to-content
--reasoning-budget 8192
--rope-scaling yarn
--yarn-orig-ctx 262144
-c 524288
```

- **`--allow-extended-ctx`** — required when `-c` exceeds `n_ctx_train`; without it, slot context may clamp to training size under YaRN.
- **`--kv-ram`** — keeps large KV in system RAM; ~25 GB WS observed at 512k ctx with Q6_K 9B.
- **`--parallel 1`** — single slot reused across sequential Cadre problems; server now clears recurrent state safely between idle-slot cache saves.

---

## Stability fix (2026-07-01)

### Symptom

Solo-coder HumanEval: **HumanEval/0** PASS, **HumanEval/1** second LLM round → TCP death (`Connection error`). Think-tank on a **fresh** server completed 5/5.

### Root cause

`recurrent_expand_after_prompt_cache()` in `tools/server/server-context.cpp` called `GGML_ABORT` when hybrid Qwen3.5 SSM could not re-expand recurrent cells after prompt-cache shrink between unrelated chat sessions.

### Godzilla changes

| File | Change |
|------|--------|
| `tools/server/server-context.cpp` | On expand failure: log warning, continue in shrunk mode (no abort). `slot_save_and_clear`: recurrent shrink before cache save, expand attempt after. |
| `common/arg.cpp`, `common/common.h` | `--allow-extended-ctx` for YaRN beyond `n_ctx_train`. |

### Cadre hardening

| File | Change |
|------|--------|
| `V:\cadre\src\cadre\server\manager.py` | `erase_slot()`, `ensure_running()` |
| `V:\cadre\src\cadre\eval\humaneval.py` | Call both between each HumanEval problem |

### Verification

Post-fix: solo coder **5/5 pass@1**, zero connection errors (wall ~1273 s for 5 problems). Artifacts: `V:\cadre\data\eval\humaneval_20260701_133731`.

---

## Operational notes

1. **Managed server** — use `cadre server start` so stderr is captured on crash; external launches hide exit reason.
2. **Rebuild before eval** — after pulling `main`, run `rebuild-godzilla.bat`; stop any running `llama-server` first (Windows DLL lock).
3. **`RS-ROLLBACK-OVERFLOW` at load** — warning only with extended YaRN; not the crash trigger.
4. **Between problems** — Cadre calls slot erase + health check; godzilla must stay up across HE/0 → HE/1 transition.

---

## Related paths

| Item | Path |
|------|------|
| Stability report | `J:\LLM\diagnostics\cadre-godzilla-stability-report-2026-07-01.md` |
| Repro JSON | `J:\LLM\diagnostics\godzilla-stability-repro-20260701.json` |
| Verify log | `J:\LLM\diagnostics\godzilla-stability-verify-20260701.log` |
| Cadre settings | `V:\cadre\config\settings.yaml` |
