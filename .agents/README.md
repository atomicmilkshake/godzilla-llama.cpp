# Local Agent Hub (gitignored)

This directory is **local-only**. It is listed in `.gitignore` and must never be committed or pushed.

## Purpose

- **Continuity** — dev journal and session notes so agents do not start cold.
- **Navigation** — centralized map of all repo documentation.
- **Bootstrap** — mandatory session-start checklist in `AGENTS.md`.

## Files

| File | Role |
|------|------|
| `AGENTS.md` | Workspace rules: bootstrap steps, journal format, enforcement |
| `journal.md` | Append-only dev journal (required at session end) |
| `doc_map.md` | Categorized index of `docs/` and `notes/` |
| `context_dumps.md` | Pointer to archived agent conversations outside the repo |

## Session workflow

1. **Start** — read `journal.md` (latest entry first), then `doc_map.md` if you need docs, then root `AGENTS.md` for build/architecture.
2. **Work** — treat the codebase and journal as source of truth over stale chat memory.
3. **End** — append a structured entry to `journal.md` before your final response.

## IDE hooks

- **Gemini / Antigravity**: `.gemini/settings.json` loads root `AGENTS.md` (also gitignored).
- **Cursor / Copilot / Grok**: root `AGENTS.md` includes the bootstrap alert at the top.