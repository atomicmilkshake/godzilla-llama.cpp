# Agent build workflow (Godzilla / lab) — READ FIRST

**Audience:** any coding agent touching `J:\LLM\engines\godzilla-llama.cpp`.  
**Goal:** one reliable path to a shippable `release-bin\llama-server.exe` without re-debugging UCRT, racing ninja, or shipping a partial DLL pack.

Also run:

```bat
python J:\LLM\engines\godzilla-llama.cpp\scripts\agent_bootstrap_godzilla.py
```

That prints live status (env, build tree, release-bin age, MTP fix presence) and the exact next command.

---

## Canonical paths

| Role | Path |
|------|------|
| Repo root | `J:\LLM\engines\godzilla-llama.cpp` |
| Shared MSVC+UCRT+CUDA env | `scripts\env-godzilla-msvc.cmd` |
| Toolchain truth (UCRT pin) | `docs\WINDOWS-BUILD-TOOLCHAIN.md` |
| **This workflow** | `docs\AGENT-BUILD-WORKFLOW.md` |
| One-shot clean rebuild | `rebuild_king.cmd` |
| Safe incremental rebuild | `scripts\rebuild_incremental.cmd` |
| Detached long rebuild | `scripts\rebuild_detached.cmd` |
| Stage DLLs | `scripts\stage-release-bin.ps1` |
| Runtime package | `release-bin\` (cwd when launching) |
| Product pointer | `X:\My Drive\VandelayNexus\docs\GODZILLA-BUILD.md` |
| Global agent pin | `C:\Users\owenm\.grok\Agents.md` |

**Pins (do not invent alternatives):** WDK `S:\WADK102` @ `10.0.26100.0`, CUDA **13.2**, arch **86**, VS **18**.

---

## Decision tree (what to run)

```
Need a working server binary?
│
├─ release-bin is fresh + --version OK on clean PATH?
│    └─ STOP. Use it. cwd = release-bin.
│
├─ Only C++ sources changed under src/ tools/ common/ (no ggml-cuda touch)?
│    └─ scripts\rebuild_incremental.cmd
│         (env → ninja llama-server → stage-release-bin)
│
├─ CMake flags / toolchain / full dirty tree / broken build-king?
│    └─ rebuild_king.cmd   (DELETES build-king — long CUDA rebuild)
│
└─ Build will take >10 min and agent session may die?
     └─ scripts\rebuild_detached.cmd
          (single ninja, log file, survives agent exit)
```

**Never** start a second `ninja` / `cmake --build` while another is running on `build-king`.

---

## Hard rules (lab blood lessons, 2026-07)

### 1. One ninja only

Two concurrent `ninja.exe` on `build-king` = corrupted/dirty graph, half-built CUDA objs, multi-hour thrash.

Before any build:

```bat
tasklist | findstr /i "ninja.exe nvcc.exe"
```

If either appears for this tree: wait or `taskkill /IM ninja.exe /F` + `taskkill /IM nvcc.exe /F`, then **one** rebuild.

### 2. Do not kill mid-CUDA rebuild

Killing at `[95/406]` leaves hundreds of CUDA template objs “dirty”. Next build redoes ~300+ nvcc jobs. Prefer **detached** + log poll over cancel.

### 3. Always stage after build

`build-king\bin\llama-server.exe` alone is **not** the product. After every successful link:

```bat
pwsh -NoProfile -File scripts\stage-release-bin.ps1 -RepoRoot . -BuildBin build-king\bin
```

Must include OpenSSL + CUDA from **`bin\x64`** (`cublasLt64_13.dll`). Verify:

```bat
python scripts\check-release-bin-deps.py --dir release-bin --exe llama-server.exe
```

### 4. Always use env-godzilla-msvc.cmd

Bare `vcvars64` → **`LNK1104: ucrtd.lib`**. See `WINDOWS-BUILD-TOOLCHAIN.md`. Never invent new kit paths.

### 5. Runtime cwd = release-bin

Thin `llama-server.exe` (~10 KB) loads companion DLLs from cwd. Wrong cwd → missing DLL dialogs.

### 6. “BUILD_OK” without fresh objs is a lie

After rebuild, check mtimes:

```text
build-king\src\CMakeFiles\llama.dir\models\qwen35.cpp.obj
build-king\bin\llama.dll
release-bin\llama.dll
```

If sources are newer than objs, the compile never happened (failed env, wrong dir, or ninja no-op after a race).

---

## Incremental rebuild (preferred for src-only fixes)

```bat
cd /d J:\LLM\engines\godzilla-llama.cpp
scripts\rebuild_incremental.cmd
```

What it does:

1. Asserts no other ninja/nvcc  
2. `call scripts\env-godzilla-msvc.cmd`  
3. `cmake --build build-king --target llama-server --parallel`  
4. `stage-release-bin.ps1`  
5. Appends `BUILD_OK` / `BUILD_FAIL` to `build_king_incremental.log`  
6. Prints `llama-server.exe --version` from `release-bin`

If `build-king\CMakeCache.txt` is missing → run `rebuild_king.cmd` instead.

---

## Detached rebuild (session-safe)

When CUDA is dirty or the agent may disconnect:

```bat
cd /d J:\LLM\engines\godzilla-llama.cpp
scripts\rebuild_detached.cmd
```

- Spawns a **new console process** (not attached to the agent job)  
- Log: `build_king_detached.log`  
- Poll: `python scripts\agent_bootstrap_godzilla.py --wait-build`

Do **not** start a second build while detached is running.

---

## Clean full rebuild (nuclear)

```bat
cd /d J:\LLM\engines\godzilla-llama.cpp
rebuild_king.cmd
```

Deletes `build-king`, reconfigures Ninja+CUDA arch 86, builds `llama-server`, stages `release-bin`.  
Expect **long** CUDA compile time on first/full rebuild.

---

## Known source bug: Qwen3.5/3.6 MTP gate (fixed in tree)

**Symptom:** GGUF has `qwen35.nextn_predict_layers = 1` and `blk.*.nextn.*` tensors, but server dies with:

```text
context type MTP requested but model doesn't contain MTP layers
```

**Cause:** loader sets `hparams.nextn_predict_layers` but MTP context enablement checked **`hparams.n_layer_nextn`**, which was never assigned (always 0).

**Fix (must be present in tree):**

| File | Change |
|------|--------|
| `src/models/qwen35.cpp` | after loading `nextn_predict_layers`: `hparams.n_layer_nextn = hparams.nextn_predict_layers;` |
| `src/models/qwen35moe.cpp` | same |
| `src/llama-context.cpp` | MTP reject only if **both** `n_layer_nextn == 0` **and** `nextn_predict_layers == 0` |

Bootstrap script checks these strings. After pull/edit: **incremental rebuild + stage**, then smoke:

```bat
cd /d J:\LLM\engines\godzilla-llama.cpp\release-bin
llama-server.exe -m J:\LLM\models\current\Qwythos-9B-Claude-Mythos-5-1M-MTP-Q6_K.gguf ^
  -c 2048 -ngl 99 --flash-attn on --fit off --spec-type draft-mtp --host 127.0.0.1 --port 8099 --no-warmup
```

Must **not** print “doesn't contain MTP layers”.

---

## Anti-patterns (agent edition)

| Don’t | Do instead |
|-------|------------|
| Two parallel `cmake --build` / ninja | One build; poll log |
| Kill CUDA rebuild at 40% | Detached + wait |
| Hand-copy a few DLLs into release-bin | `stage-release-bin.ps1` |
| Invent UCRT paths | `env-godzilla-msvc.cmd` only |
| Use PowerShell for multi-step build orchestration | `cmd` calling lab `.cmd` / Python bootstrap |
| Trust console “BUILD_OK” without mtime check | Compare source vs `.obj` vs `release-bin\llama.dll` |
| Serve from `build-king\bin` without full DLL pack | Always `release-bin` |

---

## Quick smoke (post-stage)

```bat
cd /d J:\LLM\engines\godzilla-llama.cpp\release-bin
set PATH=C:\Windows\System32;C:\Windows
llama-server.exe --version
python ..\scripts\check-release-bin-deps.py --dir . --exe llama-server.exe
```

---

## Related docs

1. `docs/WINDOWS-BUILD-TOOLCHAIN.md` — UCRT / VS / CUDA pins  
2. `GODZILLA_KING.md` — engine policy  
3. `X:\My Drive\VandelayNexus\docs\GODZILLA-BUILD.md` — product serve path  
4. `J:\LLM\engines\BUILD-WINDOWS.md` — engines umbrella  

Last updated: **2026-07-17** (MTP gate fix + agent workflow after concurrent-ninja burn).
