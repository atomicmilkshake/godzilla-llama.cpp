from pathlib import Path

p = Path(__file__).resolve().parents[1] / "CHANGELOG.md"
t = p.read_text(encoding="utf-8")
idx = t.find("## Unreleased")
idx2 = t.find("## Unreleased", idx + 1)
if idx2 > 0:
    idx3 = t.find("\n## v", idx2)
    if idx3 < 0:
        idx3 = len(t)
    # keep first Unreleased block only
    t = t[:idx2] + t[idx3 + 1 :]  # drop leading newline of next section once
    # fix if we ate a newline badly
    if not t.startswith("# Changelog"):
        pass
    p.write_text(t, encoding="utf-8")
    print("removed second Unreleased")
else:
    print("only one Unreleased")
print(p.read_text(encoding="utf-8")[:900])
