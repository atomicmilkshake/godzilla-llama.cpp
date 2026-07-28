#!/usr/bin/env python3
"""Bulk-resolve godzilla ← upstream/main merge conflicts.

Policy (docs/godzilla-upstream-sync-process.md):
  - Prefer BeeLlama (theirs) for shared engine code
  - Prefer Godzilla (ours) for branding/docs inventory
  - Accept upstream deletions (UD) unless godzilla-only (none of UD list is triattention)
"""
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

OURS = {
    "README.md",
    "AGENTS.md",
    "CHANGELOG.md",
    "SECURITY.md",
}


def run(cmd: list[str]) -> int:
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        print("FAIL", " ".join(cmd[:8]), (r.stderr or r.stdout)[:400])
    return r.returncode


def main() -> int:
    status = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)
    uu, aa, ud = [], [], []
    for line in status.splitlines():
        code, path = line[:2], line[3:].strip()
        if " -> " in path:
            path = path.split(" -> ")[-1]
        if code == "UU":
            uu.append(path)
        elif code == "AA":
            aa.append(path)
        elif code == "UD":
            ud.append(path)

    print(f"UU={len(uu)} AA={len(aa)} UD={len(ud)}")

    for path in ud:
        print("rm UD", path)
        run(["git", "rm", "-f", path])

    for path in uu + aa:
        if path in OURS:
            print("ours", path)
            run(["git", "checkout", "--ours", "--", path])
        else:
            print("theirs", path)
            run(["git", "checkout", "--theirs", "--", path])
        run(["git", "add", "--", path])

    run(["git", "add", "-u"])
    left = subprocess.check_output(
        ["git", "diff", "--name-only", "--diff-filter=U"], cwd=ROOT, text=True
    ).strip()
    print("remaining conflicts:", left or "NONE")
    return 0 if not left else 1


if __name__ == "__main__":
    raise SystemExit(main())
