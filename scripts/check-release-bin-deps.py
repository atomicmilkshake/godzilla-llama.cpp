#!/usr/bin/env python3
"""
Check that a Windows release-bin directory has a closed PE import set
for llama-server (no missing non-system DLLs beside the exe).

Exit 0 = ok, 1 = missing local deps, 2 = usage/parse error.

Used by stage-release-bin.ps1 and VandelayNexus package preflight.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# DLLs Windows always resolves from System32 / KnownDlls — not package-local.
_SYSTEM_DLL_PREFIXES = (
    "api-ms-win-",
    "ext-ms-",
    "kernel32",
    "kernelbase",
    "ntdll",
    "user32",
    "gdi32",
    "advapi32",
    "shell32",
    "ole32",
    "oleaut32",
    "ws2_32",
    "wsock32",
    "crypt32",
    "bcrypt",
    "sechost",
    "rpcrt4",
    "combase",
    "shlwapi",
    "imm32",
    "setupapi",
    "version",
    "winmm",
    "iphlpapi",
    "dnsapi",
    "mswsock",
    "ncrypt",
    "userenv",
    "wtsapi32",
    "cfgmgr32",
    "powrprof",
    "profapi",
    "ucrtbase",
)

# MSVC CRT usually installed system-wide via VC++ Redistributable.
_MSVC_SYSTEM = {
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "vcomp140.dll",
    "concrt140.dll",
    "msvcr120.dll",
    "msvcp120.dll",
}


class PEError(Exception):
    pass


def _u16(data: bytes, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def _u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def pe_import_dlls(path: Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise PEError("not MZ")
    pe = _u32(data, 0x3C)
    if data[pe : pe + 4] != b"PE\0\0":
        raise PEError("not PE")
    coff = pe + 4
    nsec = _u16(data, coff + 2)
    opt = coff + 20
    magic = _u16(data, opt)
    if magic == 0x20B:
        dd = opt + 112
        is64 = True
    elif magic == 0x10B:
        dd = opt + 96
        is64 = False
    else:
        raise PEError(f"bad optional magic {magic:#x}")
    import_rva = _u32(data, dd + 8)  # data directory index 1
    if import_rva == 0:
        return []
    opt_size = _u16(data, coff + 16)
    sec0 = opt + opt_size
    sections: list[tuple[int, int, int]] = []
    for i in range(nsec):
        o = sec0 + i * 40
        va = _u32(data, o + 12)
        vsz = max(_u32(data, o + 8), _u32(data, o + 16))
        raw = _u32(data, o + 20)
        sections.append((va, vsz, raw))

    def rva_to_off(rva: int) -> int:
        for va, sz, raw in sections:
            if va <= rva < va + sz:
                return raw + (rva - va)
        raise PEError(f"rva {rva:#x} unmapped")

    out: list[str] = []
    desc = rva_to_off(import_rva)
    while True:
        name_rva = _u32(data, desc + 12)
        oft = _u32(data, desc)
        ft = _u32(data, desc + 16)
        if name_rva == 0 and oft == 0 and ft == 0:
            break
        no = rva_to_off(name_rva)
        end = data.index(0, no)
        out.append(data[no:end].decode("ascii", errors="replace"))
        desc += 20
    return out


def is_system_dll(name: str, system32: Path) -> bool:
    low = name.lower()
    if low in _MSVC_SYSTEM:
        return True
    for p in _SYSTEM_DLL_PREFIXES:
        if low == p or low.startswith(p):
            return True
    if low.endswith(".dll") and (system32 / name).is_file():
        # Present in System32 → OS will resolve without package copy
        # (still optional to ship VC redist next to exe for airgapped machines).
        if low.startswith("api-ms-") or low in _MSVC_SYSTEM:
            return True
        # Do NOT treat CUDA/OpenSSL as system just because some machines have them
        # on PATH — only System32 count for clean-PATH packaging.
        if low in {
            n.lower()
            for n in [
                "kernel32.dll",
                "user32.dll",
                "gdi32.dll",
                "advapi32.dll",
                "shell32.dll",
                "ole32.dll",
                "oleaut32.dll",
                "ws2_32.dll",
                "crypt32.dll",
                "bcrypt.dll",
                "sechost.dll",
                "rpcrt4.dll",
                "combase.dll",
                "shlwapi.dll",
                "imm32.dll",
                "setupapi.dll",
                "version.dll",
                "winmm.dll",
                "iphlpapi.dll",
                "ntdll.dll",
                "ucrtbase.dll",
            ]
        }:
            return True
        if (system32 / name).is_file() and low.startswith(
            ("msvc", "vcruntime", "vcomp", "concrt", "ucrtbase", "api-ms-")
        ):
            return True
        if (system32 / name).is_file() and not any(
            x in low for x in ("cuda", "cublas", "cudart", "nvrtc", "libssl", "libcrypto", "ggml", "llama", "mtmd")
        ):
            # Generic OS / vendor DLL already in System32
            return True
    return False


def check_package(root: Path, entry: str) -> dict:
    root = root.resolve()
    entry_path = root / entry
    if not entry_path.is_file():
        return {"ok": False, "error": f"missing entry {entry_path}", "missing": [entry]}

    local = {p.name.lower(): p for p in root.iterdir() if p.suffix.lower() in {".dll", ".exe"}}
    system32 = Path(r"C:\Windows\System32")
    missing: list[str] = []
    checked: set[str] = set()
    queue = [entry]

    while queue:
        name = queue.pop()
        key = name.lower()
        if key in checked:
            continue
        checked.add(key)
        path = local.get(key)
        if path is None:
            if not is_system_dll(name, system32):
                missing.append(name)
            continue
        try:
            deps = pe_import_dlls(path)
        except (OSError, PEError, struct.error, ValueError) as exc:
            return {"ok": False, "error": f"parse {path.name}: {exc}", "missing": missing}
        for d in deps:
            queue.append(d)

    missing_u = sorted(set(missing), key=str.lower)
    return {
        "ok": len(missing_u) == 0,
        "root": str(root),
        "entry": entry,
        "pe_files": len(local),
        "reachable": len(checked),
        "missing": missing_u,
        "error": None if not missing_u else f"missing {len(missing_u)} non-system DLL(s)",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", type=Path, required=True)
    ap.add_argument("--exe", default="llama-server.exe")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    report = check_package(args.dir, args.exe)
    if args.json:
        import json

        print(json.dumps(report, indent=2))
    else:
        print(f"package: {report.get('root')} entry={report.get('entry')}")
        print(f"pe_files={report.get('pe_files')} reachable={report.get('reachable')}")
        if report.get("missing"):
            print("MISSING (must sit next to the exe):", file=sys.stderr)
            for m in report["missing"]:
                print(f"  {m}", file=sys.stderr)
        if report.get("error") and not report.get("missing"):
            print(report["error"], file=sys.stderr)
        print("OK" if report["ok"] else "FAIL")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
