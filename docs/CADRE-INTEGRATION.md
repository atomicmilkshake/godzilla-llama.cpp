# Cadre integration with godzilla-llama.cpp

**Consumer:** Cadre eval harness and managed `llama-server` on port **8090**.  
**Engine:** `<GODZILLA_REPO_ROOT>` branch **`main`**.

---

## Quick start

```powershell
# Rebuild godzilla (MSVC + CUDA via vcvars)
<CADRE_ROOT>\scripts\rebuild-godzilla.bat

cd <CADRE_ROOT>
python -m cadre server start
python -m cadre eval humaneval --mode coder --limit 5 --no-live
```

Success: all problems complete without `openai.APIConnectionError` / `httpx.ConnectError` to `:8090`.

Stability regression (coder + think tank):

```powershell
python <CADRE_ROOT>\scripts\benchmark_modes.py 5
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
| `<CADRE_ROOT>\src\cadre\server\manager.py` | `erase_slot()`, `ensure_running()` |
| `<CADRE_ROOT>\src\cadre\eval\humaneval.py` | Call both between each HumanEval problem |

### Verification

Post-fix: solo coder **5/5 pass@1**, zero connection errors (wall ~1273 s for 5 problems). Artifacts: `<CADRE_ROOT>\data\eval\humaneval_<TIMESTAMP>`.

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
| Stability report | `<DIAGNOSTICS_ROOT>\cadre-godzilla-stability-report-<DATE>.md` |
| Repro JSON | `<DIAGNOSTICS_ROOT>\godzilla-stability-repro-<DATE>.json` |
| Verify log | `<DIAGNOSTICS_ROOT>\godzilla-stability-verify-<DATE>.log` |
| Cadre settings | `<CADRE_ROOT>\config\settings.yaml` |
