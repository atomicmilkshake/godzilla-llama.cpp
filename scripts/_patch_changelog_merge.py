from pathlib import Path

p = Path(__file__).resolve().parents[1] / "CHANGELOG.md"
t = p.read_text(encoding="utf-8")
note = """## Unreleased

- **Full BeeLlama lineage merge (2026-07-28):** merged `upstream/main` (Anbeeld/beellama.cpp) into `godzilla` (~467 commits). Conflict policy: BeeLlama for shared engine code; Godzilla branding for README/AGENTS/CHANGELOG/SECURITY. Stock `ggml-org/llama.cpp` remains cherry-pick only (no shared merge-base with this fork).
- **MTP `--fit` offload fix retained** after merge (upstream #26177 / b10152): `common/fit.cpp` counts `n_layer + n_layer_nextn`.

"""
if "Full BeeLlama lineage merge" not in t:
    if t.startswith("# Changelog"):
        t = t.replace("# Changelog\n", "# Changelog\n\n" + note, 1)
    else:
        t = note + t
    # remove older duplicate Unreleased MTP-only bullet if still present as second block
    p.write_text(t, encoding="utf-8")
    print("updated")
else:
    print("already present")
print(p.read_text(encoding="utf-8")[:900])
