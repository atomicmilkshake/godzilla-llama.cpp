# Godzilla upstream sync process

**Repo:** `<GODZILLA_ROOT>`  
**Primary integration branch:** `godzilla` (one and only one branch on the godzilla-llama.cpp repo)  
**Canonical remote:** `origin` → https://github.com/atomicmilkshake/godzilla-llama.cpp.git  
**Workspace journal:** `<operator-private-journal>` (append after every sync session)

This document is the repeatable workflow for checking upstreams, triaging diffs, applying safe ports, running regression gates, and recording results. Related integration plans: [godzilla-llama-cpp-plan.md](godzilla-llama-cpp-plan.md), [bitnet-godzilla-integration-plan.md](bitnet-godzilla-integration-plan.md).

---

## 1. Upstream map

| Remote | URL / path | Tracking branch | Role |
|--------|------------|-----------------|------|
| **`upstream`** / **`beellama-upstream`** | https://github.com/Anbeeld/beellama.cpp.git · `<beellama-upstream-clone>` | `main` | **Primary lineage** — TurboQuant/TCQ KV, DFlash/MTP, adaptive speculative decoding, BeeLlama CLI/server args, reasoning-loop guard |
| **`llama-org`** | https://github.com/ggml-org/llama.cpp.git | `master` | **Reference upstream** — ggml core, CUDA backends, models, generic server; **cherry-pick or manual port only** (no wholesale merge) |
| **`bitnet-upstream`** | https://github.com/microsoft/BitNet.git | `main` | **Vendor slice source** — CPU I2_S/TL kernels copied into `vendor/bitnet/` (not full repo merge) |
| **`origin`** | https://github.com/atomicmilkshake/godzilla-llama.cpp.git | `godzilla` | **Canonical published fork** — push target after gates pass |
| `buun-source` | `<buun-upstream-clone>` | `master` | TriAttention + buun turbo-quant shim lineage (integration reference) |
| `tq3-source` | https://github.com/turbo-tan/llama.cpp-tq3.git | `main` | TurboQuant TQ3 CUDA reference (overlaps BeeLlama/buun) |

### Sync priority order

1. **BeeLlama** (`upstream/main`) → merge into `main` when behind.
2. **llama.cpp** (`llama-org/master`) → security/bugfix cherry-picks or targeted manual ports.
3. **BitNet** → refresh `vendor/bitnet/` pin per [vendor/bitnet/VENDOR.md](../godzilla-llama.cpp/vendor/bitnet/VENDOR.md).
4. **buun** → TriAttention-only fixes with explicit checklist.
5. **Push** `origin/godzilla` when all gates pass.

### One-time remote setup

```powershell
cd <GODZILLA_ROOT>
git remote add upstream         https://github.com/Anbeeld/beellama.cpp.git
git remote add llama-org        https://github.com/ggml-org/llama.cpp.git
git remote add bitnet-upstream  https://github.com/microsoft/BitNet.git
git remote add beellama-upstream <beellama-upstream-clone>
git remote add buun-source      <buun-upstream-clone>
git remote add tq3-source       https://github.com/turbo-tan/llama.cpp-tq3.git
git remote set-url origin       https://github.com/atomicmilkshake/godzilla-llama.cpp.git
```

---

## 2. Godzilla-only inventory — never blind-overwrite

These paths and features are **godzilla-specific** or carry fork-local semantics. Upstream merges must preserve them or resolve conflicts explicitly. Do **not** accept upstream wholesale replacements.

### TriAttention (KV pruning)

| Path | Notes |
|------|-------|
| `src/llama-triattention.cpp`, `src/llama-triattention.h` | Scoring, pruning, `.triattention` calibration loader |
| `src/llama-triattention-gpu-stub.cpp` | CPU-only BitNet build stubs |
| `ggml/src/ggml-cuda/triattention-score.cu`, `.cuh` | CUDA scoring kernel |
| `tests/test-triattention-*.cpp` | Regression suite |
| `docs/TRIATTENTION.md`, `docs/TRIATTENTION-API.md` | Operator docs |
| `scripts/build-triattention-tests.ps1`, `scripts/ensure-triattention.ps1`, `scripts/resolve-triattention-hf.py` | Build/calibration helpers |

### TurboQuant / TCQ KV cache

| Path | Notes |
|------|-------|
| `ggml` quant types **42–55** (TurboQuant/TCQ) | Enum layout — migration requires checklist |
| `ggml/src/ggml-turbo-quant.c`, turbo CUDA dequant paths | buun/BeeLlama integration |
| `ggml/src/ggml-cuda/set-rows.cu`, `fattn.cu` (buun deltas) | Norm correction, asymmetric dequant |
| CLI: `--cache-type-k`, `--cache-type-v` turbo* values | See `docs/PROFILES.md` |

### KVarN

| Path | Notes |
|------|-------|
| `src/llama-kvarn.*`, `src/llama-kv-cache-kvarn.*` | KVarN manager |
| `ggml/src/ggml-cuda/kvarn.cu` | CUDA backend |
| `tests/test-kvarn.cpp` | Unit tests |
| CLI: `--kvarn2` … `--kvarn8` | BeeLlama-preview port |

### Copilot / VSCode streaming

| Path | Notes |
|------|-------|
| `tools/server/server-task.cpp`, `server-task.h` | Content coalesce buffer, reasoning promote flags |
| `tests/test-server-copilot-coalesce.cpp` | SSE delta coalescing regression |
| CLI: `--reasoning-promote-to-content` / `--no-reasoning-promote-to-content` | Agent-mode compatibility |

### BitNet vendor (Microsoft I2_S)

| Path | Notes |
|------|-------|
| `vendor/bitnet/` | Entire pinned slice — see [VENDOR.md](../godzilla-llama.cpp/vendor/bitnet/VENDOR.md) |
| `src/models/bitnet.cpp` | Godzilla graph (`LLM_FFN_RELU_SQR` for b1.58) |
| `GGML_BITNET_*` CMake, types **56–59** | Behind flags; OFF on default CUDA `build/` |
| `docs/BITNET.md`, `scripts/build_bitnet_cpu.ps1`, `scripts/fetch-bitnet-model.ps1` | Build + parity docs |

### DFlash / MTP / BeeLlama speculative stack

| Path | Notes |
|------|-------|
| `src/models/dflash_draft.cpp`, `src/dflash-profile.h` | DFlash draft models |
| `tools/server/server-adaptive-dm.h`, `server-context.cpp` (spec paths) | Adaptive draft control |
| `tests/test-dflash-*.cpp`, `tests/test-adaptive-dm.cpp` | Spec plumbing |
| `docs/quickstart-qwen36-dflash.md`, `docs/quickstart-gemma-4-31b-dflash.md` | Operator guides |

### BeeLlama CLI / args surface

| Path | Notes |
|------|-------|
| `common/arg.cpp`, `common/common.h` | TriAttention, KVarN, reasoning, DFlash flags |
| `docs/beellama-args.md`, `docs/beellama-features.md` | CLI reference (extend, do not replace with upstream llama.cpp docs) |
| `src/llama-context.cpp` | Recurrent expand/shrink + `llama_triattention_init` hooks |

### Immutable without migration plan

- TurboQuant enum block (types 42–55) and BitNet types (56–59): see `vendor/bitnet/CHERRY_PICK_CHECKLIST.md`.
- Copilot coalesce behavior in `server-task.cpp` — never take llama.cpp `server-task` wholesale.

---

## 3. Step-by-step workflow

### A — Preflight

1. Read `<operator-private-journal>` tail; confirm branch `godzilla`.
2. `git status` — stash or commit WIP: `git stash push -m "pre-upstream-sync"`.
3. Note current HEAD SHA as rollback anchor.

### B — Fetch remotes

```powershell
cd <GODZILLA_ROOT>
git fetch upstream beellama-upstream llama-org bitnet-upstream buun-source tq3-source origin
```

### C — Merge-base and divergence inventory

```powershell
$HEAD = git rev-parse HEAD

# BeeLlama (primary)
$MB_BL = git merge-base $HEAD upstream/main
Write-Host "BeeLlama merge-base: $MB_BL"
git rev-list --count HEAD..upstream/main    # behind
git rev-list --count upstream/main..HEAD    # ahead

# llama.cpp (reference)
$MB_LC = git merge-base $HEAD llama-org/master
Write-Host "llama.cpp merge-base: $MB_LC"
git rev-list --count HEAD..llama-org/master
git rev-list --count llama-org/master..HEAD

# BitNet pin
git rev-parse bitnet-upstream/main
Select-String -Path vendor/bitnet/VENDOR.md -Pattern "Pinned commit"
```

### D — Triage commits

Group upstream commits since merge-base by risk:

```powershell
$MB = git merge-base HEAD llama-org/master

git log --oneline $MB..llama-org/master --grep="fix|security|CVE" -i --no-merges
git log --oneline $MB..llama-org/master -- tools/server --no-merges
git log --oneline $MB..llama-org/master -- ggml/ --no-merges
git log --oneline $MB..llama-org/master -- src/models --no-merges
```

| Category | Action |
|----------|--------|
| **security** | High priority; manual port if cherry-pick hits Copilot/TriAttention |
| **bugfix** (ggml, CUDA) | Cherry-pick if clean; else manual port |
| **model support** | Cherry-pick if isolated; skip if touches godzilla quant enums |
| **server** | Cherry-pick isolated files only; **never** wholesale `server-task.cpp` |
| **docs** | Safe for non-godzilla topics |
| **UI** (`tools/ui`) | Low priority; often diverged — skip or manual |

**Dry-run cherry-pick:**

```powershell
git cherry-pick --no-commit <sha>
# inspect conflicts; run gates before committing
git cherry-pick --abort
```

### E — Apply updates

| Source | Method |
|--------|--------|
| BeeLlama behind > 0 | `git checkout main; git merge upstream/main` |
| llama.cpp | Cherry-pick or manual file port (one logical change per commit) |
| BitNet | Vendor pin refresh (§6) — not git merge of full repo |
| buun | TriAttention fixes per buun checklist |

### F — Test gates (§4)

Run **before and after** any apply. Do not push until all required gates pass.

### G — Journal + push

1. Append `<operator-private-journal>`: inventory table, applied SHAs, deferred list, gate results, rollback SHA.
2. `git push origin godzilla` when operator approves and gates are green.

---

## 4. Test gates

Run from `<GODZILLA_ROOT>` unless noted.

### Gate 0 — CUDA build (after ggml/server/CUDA changes)

Stop any running `llama-server` first (Windows DLL lock).

```powershell
pwsh -File <GODZILLA_ROOT>\scripts\build_cuda.ps1 -Target llama-server
```

Optional: rebuild test binaries before ctest:

```powershell
cmake --build <GODZILLA_ROOT>\build -j 8 `
  --target test-triattention-gpu-parity test-server-copilot-coalesce
```

### Gate 1 — Unit regression (required every sync)

Default CUDA `build/` with **BitNet OFF** (`GGML_BITNET_*` unset):

```powershell
cd <GODZILLA_ROOT>\build
ctest -R "triattention|copilot-coalesce" --output-on-failure
# Expect: 9/9 PASS
```

When BitNet vendor or CPU hooks changed, also run:

```powershell
ctest -R "triattention|copilot-coalesce|bitnet" --output-on-failure
# bitnet test requires build-bitnet-cpu (see Gate 2)
```

### Gate 2 — BitNet I2_S (when `vendor/bitnet/` or BitNet ggml hooks touched)

```powershell
pwsh -File <GODZILLA_ROOT>\scripts\build_bitnet_cpu.ps1 -UseWsl -Target llama-completion
cd <GODZILLA_ROOT>\build-bitnet-cpu
ctest -R test-bitnet-i2s-quant --output-on-failure
```

**Greedy parity vs Microsoft reference** (WSL; exact token match required before deprecating `:8091`):

```bash
MODEL=$MODELS_DIR/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf
MS=$BITNET_REF_ROOT/build/bin/llama-cli
GZ=$WSL_GODZILLA_ROOT/build-bitnet-cpu/bin/llama-completion
$MS -m "$MODEL" -p "Hello" -n 16 -ngl 0 --temp 0 --no-warmup --no-display-prompt -t 4
$GZ -m "$MODEL" -p "Hello" -n 16 -ngl 0 --temp 0 --fit off --no-warmup --no-display-prompt --no-conversation --single-turn -t 4
```

Use `llama-completion --no-conversation --single-turn`, not chat-mode `llama-cli`. BitNet-b1.58 FFN is **ReLU²** (`LLM_FFN_RELU_SQR`).

Re-run Gate 1 on default CUDA `build/` with BitNet OFF after any BitNet work.

### Gate 3 — Server launch smoke (required before release / after server changes)

```powershell
pwsh -File <GODZILLA_ROOT>\scripts\benchmarks\run-launch-smoke.ps1 `
  -Binary "<GODZILLA_ROOT>\build\bin\llama-server.exe" `
  -Model "$MODELS_DIR/VibeThinker-3B.i1-Q4_K_M.gguf" `
  -TriStats "$TRIATTENTION_CALIB_DIR/vibethinker-3b.triattention" `
  -Port 8095
```

Script exercises `/health`, `/v1/models`, chat completion, SSE stream, and `/v1/responses`. Output JSON under `logs/benchmarks/launch_smoke_*.json`.

### Gate 4 — Production spot check (optional, pre-push)

```powershell
# If llama-server already on :8090
Invoke-WebRequest -Uri "http://127.0.0.1:8090/v1/models" -UseBasicParsing   # expect 200
```

---

## 5. BitNet vendor pin

Full procedure: **[godzilla-llama.cpp/vendor/bitnet/VENDOR.md](../godzilla-llama.cpp/vendor/bitnet/VENDOR.md)**

Summary:

1. `git fetch bitnet-upstream`
2. Compare `git rev-parse bitnet-upstream/main` vs pinned SHA in `VENDOR.md`
3. If changed, diff vendor slice only (`src/ggml-bitnet-*.cpp`, `include/`, `preset_kernels/`, `utils/`)
4. Copy updated files into `vendor/bitnet/` per `VENDOR.md` table
5. Update pinned commit + date in `VENDOR.md`
6. Port ggml hooks per `vendor/bitnet/CHERRY_PICK_CHECKLIST.md`
7. Run Gates 1–2; CUDA build must stay green with `GGML_BITNET_*=OFF`

**Current pin (2026-06-28):** `01eb415772c342d9f20dc42772f1583ae1e5b102`

---

## 6. Rollback

### Undo last local commit (not pushed)

```powershell
git reset --hard HEAD~1
```

### Return to known-good SHA (sync session failed)

```powershell
git reset --hard <known-good-sha>   # e.g. pre-sync HEAD from journal
```

### Revert a pushed commit (safe for shared branches)

```powershell
git revert <sha>
git push origin godzilla
```

### Branch isolation (large risky port)

```powershell
git checkout -b sync/llama-cpp-<date> main
# apply ports + gates on branch; merge --no-ff when green
```

### Restore stashed WIP

```powershell
git stash list
git stash pop
```

---

## 7. Windows / WSL command reference

### Windows (PowerShell) — full pre-sync inventory

```powershell
cd <GODZILLA_ROOT>
git fetch upstream beellama-upstream llama-org bitnet-upstream origin
$HEAD = git rev-parse HEAD
$MB = git merge-base $HEAD upstream/main
Write-Host "HEAD=$HEAD  BeeLlama MB=$MB"
git log --oneline -5 HEAD..upstream/main
git log --oneline -5 HEAD..llama-org/master
pwsh -File scripts\build_cuda.ps1 -Target llama-server
cd build
ctest -R "triattention|copilot-coalesce" --output-on-failure
cd ..
pwsh -File scripts\benchmarks\run-launch-smoke.ps1 -Port 8095
```

### WSL (bash) — fetch + ctest + BitNet parity

```bash
cd $WSL_GODZILLA_ROOT
git fetch upstream llama-org bitnet-upstream origin
MB=$(git merge-base HEAD llama-org/master)
git log --oneline ${MB}..llama-org/master --grep='security|CVE' -i --no-merges | head -20
cd build && ctest -R 'triattention|copilot-coalesce' --output-on-failure
pwsh.exe -File $WSL_GODZILLA_ROOT/scripts/build_bitnet_cpu.ps1 -UseWsl
```

### Cherry-pick workflow (either shell)

```powershell
git checkout main
git cherry-pick -x <upstream-sha>
# resolve conflicts preserving §2 inventory
git add -A && git cherry-pick --continue
cd build && ctest -R "triattention|copilot-coalesce" --output-on-failure
```

---

## 8. Frequency and triggers

| Trigger | Action |
|---------|--------|
| **Before tagging a release** or pushing `godzilla` to `origin` | Full workflow §3 + Gates 0–3 |
| **BeeLlama announces a release** or `git rev-list --count HEAD..upstream/main` > 0 | BeeLlama merge + gates |
| **llama.cpp security advisory** or CVE affecting ggml/server | Triage §3D; cherry-pick security commits within 1 week |
| **Monthly maintenance** (even if behind = 0) | Fetch + inventory + Gate 1; log "no-op" in journal |
| **After BitNet upstream tag** | Check `bitnet-upstream/main` vs pin (§5) |
| **After buun TriAttention fix** | Selective port + Gate 1 |
| **Before merging feature branches** (`bitnet-god`, `spec-god`, etc.) | Gates per branch checklist (e.g. `docs/BITNET.md` merge checklist) |
| **Production incident** on `:8090` | Rollback §6 first; sync only after stable |

---

## 9. Related docs

- [godzilla-llama-cpp-plan.md](godzilla-llama-cpp-plan.md) — phased roadmap
- [bitnet-godzilla-integration-plan.md](bitnet-godzilla-integration-plan.md) — BitNet hybrid D→A plan
- [godzilla-llama.cpp/docs/BITNET.md](../godzilla-llama.cpp/docs/BITNET.md) — BitNet parity + merge checklist
- [godzilla-llama.cpp/docs/TRIATTENTION.md](../godzilla-llama.cpp/docs/TRIATTENTION.md) — TriAttention CLI/API
- [vendor/bitnet/VENDOR.md](../godzilla-llama.cpp/vendor/bitnet/VENDOR.md) — BitNet pin record
- [vendor/bitnet/CHERRY_PICK_CHECKLIST.md](../godzilla-llama.cpp/vendor/bitnet/CHERRY_PICK_CHECKLIST.md) — Eddie-Wang → godzilla port map

---

## Appendix — 2026-06-28 sync session (reference)

Inventory at `kv-god` @ `4e81393dd` (post cherry-picks; BitNet merged @ `4be135460`).

| Upstream | Behind godzilla | Notes |
|----------|-----------------|-------|
| BeeLlama `upstream/main` | 0 | At merge-base `85e22ea0b` |
| llama.cpp `llama-org/master` | 335 | Selective cherry-pick only |
| BitNet `bitnet-upstream/main` | 0 vs pin | Pin `01eb41577` |
| buun `buun-source/master` | 62 | TriAttention source |

Applied llama.cpp ports: `c8458d96d`, `f5e4b8bf9`, `7c352a69c`, `232e0d78e`, `4e81393dd` (security #24373 manual). Gates: `ctest -R "triattention|copilot-coalesce"` **9/9 PASS**.

---

## Parallel audit supplements (2026-06-28)

Subagent run IDs (Cursor): main sync `6426b57a`, BeeLlama `e157c39b`, llama.cpp `cbed3115`, BitNet vendor `2a977581`, sync doc writer `25ac5d33`. Only the BeeLlama track produced a full standalone report in-session; BitNet and llama.cpp workers did not emit final transcripts but follow-on commits landed on `kv-god`.

### BeeLlama track (`e157c39b`) — GREEN, fully current

| Metric | Value |
|--------|-------|
| Merge-base `kv-god` ∩ `upstream/main` | `85e22ea0b` (= BeeLlama tip) |
| Behind BeeLlama | **0** |
| Ahead of BeeLlama | **41** (strict superset) |
| BeeLlama commits to port | **0** |

**Godzilla-only footprint (since merge-base):** ~166 paths across TriAttention, KVarN/TurboQuant KV, BitNet vendor, Copilot coalesce, bench harness, and five llama-org cherry-picks BeeLlama does not yet carry.

| Area | Representative paths | Notes |
|------|---------------------|-------|
| TriAttention | `src/llama-triattention*`, `ggml-cuda/triattention-score.*`, `tests/test-triattention-*` | Never blind-merge from llama.cpp server/ggml bulk |
| KVarN / KV | `src/llama-kvarn*`, `src/llama-kv-cache-kvarn*`, `ggml-cuda/kvarn.*` | High conflict if BeeLlama KV moves |
| TurboQuant / buun | `ggml-turbo-quant.c`, `turbo-quant*.cuh`, buun fattn deltas | Enum types 42–55 |
| BitNet | `vendor/bitnet/**`, `src/models/bitnet.cpp` | ReLU² FFN; types 56–59 |
| Copilot | `tools/server/server-task.cpp`, `tests/test-server-copilot-coalesce.cpp` | Do not take upstream `server-task` wholesale |
| DFlash / MTP | (none in `upstream/main..kv-god` diff) | **Inherited** from BeeLlama — not a godzilla-only fork line |

**Hot zones when BeeLlama advances:** `src/llama-kv-cache*.cpp`, `src/llama-context.cpp`, `src/llama-graph.cpp`, `ggml-cuda/fattn*`, `ggml.c` / `ggml-quants.*`, `tools/server/server*.cpp`, `common/arg.cpp`, `include/llama.h`.

### llama.cpp track (`cbed3115`) — selective ports (post main sync)

After main sync @ `a47992312`, three additional low-touch cherry-picks were applied on `kv-god`:

| Commit | Subject | Touch |
|--------|---------|-------|
| `fd12cc2ee` | ggml CUDA binary-op integer overflows (#24706) | `ggml/src/ggml-cuda/binbcast.cu` |
| `86f282625` | `LLM_KV` for `quantization_version` / `file_type` (#24802) | `src/llama-quant.cpp` |
| `34786e6a5` | `rope_parameters` handling in converters (#24833) | `conversion/*.py` |

Still **335 commits behind** `llama-org/master` (merge-base unchanged). **Still defer:** wholesale merge; mtmd #25013 (`clip.cpp` conflict); server-task / SSE / router refactors vs Copilot coalesce; `--reasoning-preserve` #25105 (needs reasoning/Cancelled with BeeLlama args).

**Triage labels for backlog:** `security` (done: #24373), `ggml-cuda` (cpy/binbcast), `ggml-cpu-arm`, `server-isolated`, `conversion-only`, `model-arch-conflict`, `server-task-forbidden`.
**Tranche 2 verification (follow-up):** ctest -R "triattention|copilot-coalesce" on CUDA `build/` → **9/9 PASS** before publish. origin/kv-god @ `5d90361b1` (tranche 2 SHAs + in-repo process doc); parallel-audit supplement below mirrors `docs/godotzilla-upstream-sync-process.md`.

**Additional defer (backlog):** `3fc4e1052` (#20793 sched async H→D) — bench before port; BeeLlama bulk merge (0 delta); buun/tq3 blind merges; BitNet GPU `torch.load` (outside vendor slice).


### BitNet vendor track (`2a977581`) — pin current, no bump

| Check | Result |
|-------|--------|
| Pin in `vendor/bitnet/VENDOR.md` | `01eb415772c342d9f20dc42772f1583ae1e5b102` |
| `bitnet-upstream/main` / local `$BITNET_REF_ROOT` @ `main` | **Same SHA** — 0 commits since pin |
| Vendor bump | **Not recommended** this session; no MS delta; re-run Gates 1–2 only after MS moves `main` |

**I2_S smoke (WSL / `build-bitnet-cpu`):**

```powershell
pwsh -File <GODZILLA_ROOT>\scripts\build_bitnet_cpu.ps1 -UseWsl
cd <GODZILLA_ROOT>\build-bitnet-cpu
ctest -R test-bitnet-i2s-quant --output-on-failure
```

Greedy parity vs Microsoft reference: see §4 Gate 2 (`llama-completion --no-conversation --single-turn`, ReLU² FFN).

**ik_llama.cpp (`<ik-llama-clone>`) — adopt vs avoid**

- **Use as reference** for `quant-god` weight-quant ideas (`src/llama-quantize.cpp`, iqk paths) — not a merge source for BitNet inference.
- **Do not** port `iqk_mul_mat` / iqk BitNet hooks into godzilla wholesale; godzilla BitNet CPU path is **`vendor/bitnet/` + `GGML_BITNET_I2_S` in `ggml-cpu.c`** per `CHERRY_PICK_CHECKLIST.md`.
- MS GPU / PyTorch stack changes in full `microsoft/BitNet` remain **out of scope** for the vendor slice.

### Sync doc writer (`25ac5d33`)

Canonical process doc authored by main sync worker (`6426b57a`) at `docs/godotzilla-upstream-sync-process.md`; README pointer on `kv-god` @ `a47992312`. In-repo copy for operators: `godzilla-llama.cpp/docs/godotzilla-upstream-sync-process.md` (mirror of workspace doc).

