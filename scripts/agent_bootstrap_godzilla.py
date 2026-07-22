#!/usr/bin/env python3
"""
Agent bootstrap for Godzilla lab builds.

Prints: toolchain pins, env readiness, single-ninja safety, build/release
freshness, MTP fix presence, and the exact next command.

Usage:
  python scripts/agent_bootstrap_godzilla.py
  python scripts/agent_bootstrap_godzilla.py --wait-build
  python scripts/agent_bootstrap_godzilla.py --json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WDK_DEFAULT = Path(os.getenv("WDK_ROOT", r"C:\Program Files (x86)\Windows Kits\10"))
CUDA_DEFAULT = Path(os.getenv("CUDA_PATH", r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2"))
DOC = ROOT / "docs" / "AGENT-BUILD-WORKFLOW.md"
TOOLCHAIN = ROOT / "docs" / "WINDOWS-BUILD-TOOLCHAIN.md"


def _run(args: list[str], timeout: int = 30) -> tuple[int, str]:
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 99, str(e)


def _task_count(image: str) -> int:
    code, out = _run(["tasklist", "/FI", f"IMAGENAME eq {image}"])
    if code != 0:
        return 0
    return out.lower().count(image.lower())


def _age_s(p: Path) -> float | None:
    if not p.exists():
        return None
    return time.time() - p.stat().st_mtime


def _fmt_age(sec: float | None) -> str:
    if sec is None:
        return "MISSING"
    if sec < 120:
        return f"{sec:.0f}s ago"
    if sec < 3600:
        return f"{sec/60:.0f}m ago"
    if sec < 86400:
        return f"{sec/3600:.1f}h ago"
    return f"{sec/86400:.1f}d ago"


def _file_has(path: Path, needle: str) -> bool:
    if not path.exists():
        return False
    try:
        return needle in path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def collect() -> dict:
    wdk = Path(os.environ.get("WDK_ROOT", WDK_DEFAULT))
    cuda = Path(os.environ.get("CUDA_PATH", CUDA_DEFAULT))
    ucrtd = wdk / "Lib" / "10.0.26100.0" / "ucrt" / "x64" / "ucrtd.lib"
    nvcc = cuda / "bin" / "nvcc.exe"
    cublaslt = cuda / "bin" / "x64" / "cublasLt64_13.dll"

    qwen35 = ROOT / "src" / "models" / "qwen35.cpp"
    qwen35moe = ROOT / "src" / "models" / "qwen35moe.cpp"
    ctx = ROOT / "src" / "llama-context.cpp"

    mtp_qwen = _file_has(qwen35, "hparams.n_layer_nextn = hparams.nextn_predict_layers")
    mtp_moe = _file_has(qwen35moe, "hparams.n_layer_nextn = hparams.nextn_predict_layers")
    mtp_ctx = _file_has(ctx, "nextn_predict_layers == 0")

    objs = {
        "qwen35.obj": ROOT
        / "build-king"
        / "src"
        / "CMakeFiles"
        / "llama.dir"
        / "models"
        / "qwen35.cpp.obj",
        "llama-context.obj": ROOT
        / "build-king"
        / "src"
        / "CMakeFiles"
        / "llama.dir"
        / "llama-context.cpp.obj",
        "llama.dll": ROOT / "build-king" / "bin" / "llama.dll",
        "release llama.dll": ROOT / "release-bin" / "llama.dll",
        "release server": ROOT / "release-bin" / "llama-server.exe",
    }

    ninja_n = _task_count("ninja.exe")
    nvcc_n = _task_count("nvcc.exe")

    cache = ROOT / "build-king" / "CMakeCache.txt"
    logs = {
        "incremental": ROOT / "build_king_incremental.log",
        "detached": ROOT / "build_king_detached.log",
        "king": ROOT / "build_king_rebuild.log",
    }
    log_status = {}
    for name, lp in logs.items():
        if not lp.exists():
            log_status[name] = "absent"
            continue
        t = lp.read_text(encoding="utf-8", errors="replace")
        if "BUILD_OK" in t:
            log_status[name] = "BUILD_OK"
        elif "BUILD_FAIL" in t or "STAGE_FAIL" in t or "ENV_FAIL" in t:
            log_status[name] = "FAIL"
        else:
            log_status[name] = f"in_progress/partial ({lp.stat().st_size} B)"

    # source vs obj staleness for patched files
    stale = []
    for src, obj in (
        (qwen35, objs["qwen35.obj"]),
        (ctx, objs["llama-context.obj"]),
    ):
        if src.exists() and obj.exists() and src.stat().st_mtime > obj.stat().st_mtime + 1:
            stale.append(src.name)

    info = {
        "root": str(ROOT),
        "docs": {
            "workflow": str(DOC),
            "toolchain": str(TOOLCHAIN),
        },
        "pins": {
            "WDK_ROOT": str(wdk),
            "UCRT": "10.0.26100.0",
            "CUDA": str(cuda),
            "arch": "86",
            "VS": "18",
        },
        "env_ready": {
            "ucrtd.lib": ucrtd.exists(),
            "nvcc": nvcc.exists(),
            "cublasLt_x64": cublaslt.exists(),
            "cmake_cache": cache.exists(),
            "env_script": (ROOT / "scripts" / "env-godzilla-msvc.cmd").exists(),
        },
        "concurrency": {
            "ninja.exe": ninja_n,
            "nvcc.exe": nvcc_n,
            "safe_to_start_build": ninja_n == 0 and nvcc_n == 0,
        },
        "mtp_fix_in_sources": {
            "qwen35.cpp": mtp_qwen,
            "qwen35moe.cpp": mtp_moe,
            "llama-context.cpp": mtp_ctx,
            "all_present": mtp_qwen and mtp_moe and mtp_ctx,
        },
        "artifact_ages": {k: _fmt_age(_age_s(p)) for k, p in objs.items()},
        "sources_newer_than_objs": stale,
        "logs": log_status,
    }

    # recommend action
    if ninja_n or nvcc_n:
        action = "WAIT — build already running. Poll: python scripts/agent_bootstrap_godzilla.py --wait-build"
    elif stale or not info["mtp_fix_in_sources"]["all_present"]:
        if not info["mtp_fix_in_sources"]["all_present"]:
            action = "SOURCES missing MTP fix strings — re-apply patch from docs/AGENT-BUILD-WORKFLOW.md then rebuild_incremental.cmd"
        elif not cache.exists():
            action = "No build-king cache → run rebuild_king.cmd (long)"
        else:
            action = "Patched sources newer than objs → scripts\\rebuild_incremental.cmd (or rebuild_detached.cmd if long)"
    elif not (ROOT / "release-bin" / "llama-server.exe").exists():
        action = "No release-bin server → scripts\\rebuild_incremental.cmd or rebuild_king.cmd"
    else:
        action = "release-bin present; if MTP still fails at runtime, rebuild so objs pick up source fix"

    info["recommended_action"] = action
    info["commands"] = {
        "bootstrap": f"python {ROOT / 'scripts' / 'agent_bootstrap_godzilla.py'}",
        "incremental": str(ROOT / "scripts" / "rebuild_incremental.cmd"),
        "detached": str(ROOT / "scripts" / "rebuild_detached.cmd"),
        "clean_full": str(ROOT / "rebuild_king.cmd"),
        "stage_only": f'pwsh -NoProfile -File "{ROOT / "scripts" / "stage-release-bin.ps1"}" -RepoRoot "{ROOT}" -BuildBin "{ROOT / "build-king" / "bin"}"',
    }
    return info


def print_human(info: dict) -> None:
    print("=" * 72)
    print("GODZILLA AGENT BOOTSTRAP")
    print("=" * 72)
    print(f"Root:     {info['root']}")
    print(f"Workflow: {info['docs']['workflow']}")
    print(f"Toolchain:{info['docs']['toolchain']}")
    print()
    print("Pins:", json.dumps(info["pins"]))
    print("Env: ", json.dumps(info["env_ready"]))
    print("Jobs:", json.dumps(info["concurrency"]))
    print("MTP source fix:", json.dumps(info["mtp_fix_in_sources"]))
    print()
    print("Artifact ages:")
    for k, v in info["artifact_ages"].items():
        print(f"  {k:22} {v}")
    if info["sources_newer_than_objs"]:
        print("STALE (src > obj):", ", ".join(info["sources_newer_than_objs"]))
    print("Logs:", json.dumps(info["logs"]))
    print()
    print(">>> RECOMMENDED:", info["recommended_action"])
    print()
    print("Commands:")
    for k, v in info["commands"].items():
        print(f"  {k:12} {v}")
    print("=" * 72)


def wait_build(timeout_s: int = 3600) -> int:
    """Poll until no ninja/nvcc and a log shows BUILD_OK/FAIL."""
    start = time.time()
    logs = [
        ROOT / "build_king_detached.log",
        ROOT / "build_king_incremental.log",
        ROOT / "build_king_rebuild.log",
        ROOT / "build_king_mtp_fix_final.log",
    ]
    while time.time() - start < timeout_s:
        ninja = _task_count("ninja.exe")
        nvcc = _task_count("nvcc.exe")
        statuses = []
        for lp in logs:
            if not lp.exists():
                continue
            t = lp.read_text(encoding="utf-8", errors="replace")
            progs = re.findall(r"\[(\d+)/(\d+)\]", t)
            prog = f"{progs[-1][0]}/{progs[-1][1]}" if progs else "?"
            if "BUILD_OK" in t:
                statuses.append(f"{lp.name}:BUILD_OK@{prog}")
            elif any(x in t for x in ("BUILD_FAIL", "STAGE_FAIL", "ENV_FAIL")):
                statuses.append(f"{lp.name}:FAIL@{prog}")
            else:
                statuses.append(f"{lp.name}:run@{prog} ({lp.stat().st_size}B)")
        print(
            f"+{time.time()-start:.0f}s ninja={ninja} nvcc={nvcc} | "
            + (" ; ".join(statuses) if statuses else "no logs"),
            flush=True,
        )
        if any(s.endswith("BUILD_OK") or ":BUILD_OK@" in s for s in statuses):
            if ninja == 0 and nvcc == 0:
                print("DONE: BUILD_OK")
                return 0
        if any(":FAIL@" in s for s in statuses) and ninja == 0 and nvcc == 0:
            print("DONE: FAIL")
            return 1
        if ninja == 0 and nvcc == 0 and time.time() - start > 90:
            # idle with no success marker
            print("IDLE with no BUILD_OK — see docs/AGENT-BUILD-WORKFLOW.md")
            return 2
        time.sleep(20)
    print("TIMEOUT waiting for build")
    return 3


def main() -> int:
    ap = argparse.ArgumentParser(description="Godzilla agent bootstrap")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--wait-build", action="store_true")
    ap.add_argument("--wait-timeout", type=int, default=3600)
    args = ap.parse_args()
    if args.wait_build:
        return wait_build(args.wait_timeout)
    info = collect()
    if args.json:
        print(json.dumps(info, indent=2))
    else:
        print_human(info)
    # non-zero if action required and concurrent unsafe or mtp missing from objs when sources have fix
    if not info["concurrency"]["safe_to_start_build"]:
        return 10
    if info["sources_newer_than_objs"]:
        return 11
    if not info["mtp_fix_in_sources"]["all_present"]:
        return 12
    return 0


if __name__ == "__main__":
    sys.exit(main())
