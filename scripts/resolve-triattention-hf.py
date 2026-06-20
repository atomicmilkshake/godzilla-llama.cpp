#!/usr/bin/env python3
"""Resolve a HuggingFace model id for TriAttention calibration from a GGUF path."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Filename / metadata token -> HF repo (extend as presets are added)
KNOWN_HF_MODELS: list[tuple[tuple[str, ...], str]] = [
    (("vibethinker-3b", "vibethinker3b"), "WeiboAI/VibeThinker-3B"),
    (("qwen3.5-4b", "qwen3-4b", "qwopus3.5-4b", "qwopus", "qwen35-4b-coder"), "Qwen/Qwen3-4B-Instruct-2507"),
    (("qwen3.5-4b-coder", "qwen35-4b-coder", "4b-coder"), "Qwen/Qwen3.5-4B"),
    (("qwen3.5-9b", "qwen35-9b"), "Qwen/Qwen3.5-9B"),
    (("qwen3.6-27b",), "Qwen/Qwen3.6-27B-Instruct"),
    (("qwen3-coder-30b", "coder-30b-a3b"), "Qwen/Qwen3-Coder-30B-A3B-Instruct"),
    (("gemma-4-26b", "gemma4-26b", "26b-a4b"), "google/gemma-4-26b-it"),
    (("gemma-4-e4b", "gemma4-e4b"), "google/gemma-4-e4b-it"),
    (("gemma-4-e2b", "gemma4-e2b"), "google/gemma-4-e2b-it"),
    (("gemma4-coding", "gemma-4-coding", "fable5-composer"), "google/gemma-4-12b-it"),
    (("lfm2.5", "lfm25", "lfm2-5", "lfm2.5-8b", "lfm2moe"), "LiquidAI/LFM2.5-8B-A1B"),
    (("huihui", "huihui-qwen"), "Qwen/Qwen3.5-9B"),
    (("negentropy", "opus-4.7"), "Qwen/Qwen3.5-9B"),
    (("fablevibes", "14b-a3b", "qwen3.6-14b"), "tvall43/Qwen3.6-14B-A3B-FableVibes"),
    (("huihui-gemma", "huihui-gemma-4"), "google/gemma-4-12b-it"),
]


def _norm(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def _hf_from_url(url: str) -> str | None:
    url = url.strip()
    if not url:
        return None
    m = re.search(r"huggingface\.co/(?:datasets/)?([^/\s#?]+/[^/\s#?]+)", url, re.I)
    if m:
        return m.group(1)
    if "/" in url and " " not in url and not url.startswith("http"):
        return url
    return None


def _read_gguf_metadata(gguf_path: Path) -> dict[str, str]:
    repo_root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo_root / "gguf-py"))
    import gguf  # noqa: WPS433

    reader = gguf.GGUFReader(str(gguf_path))
    out: dict[str, str] = {}
    for field in reader.fields.values():
        if field.types[0] != gguf.GGUFValueType.STRING:
            continue
        key = str(field.name)
        try:
            out[key] = str(field.parts[field.data[-1]], encoding="utf-8")
        except Exception:
            pass
    return out


def resolve_hf_model(gguf_path: Path) -> str:
    stem = _norm(gguf_path.stem)
    text = stem

    meta: dict[str, str] = {}
    try:
        meta = _read_gguf_metadata(gguf_path)
    except Exception as exc:
        print(f"warn: could not read GGUF metadata: {exc}", file=sys.stderr)

    for key in (
        "general.source.url",
        "general.source.repo_url",
        "general.repo_url",
        "general.url",
        "general.basename",
        "general.name",
    ):
        val = meta.get(key, "")
        if val:
            text += " " + _norm(val)
            hf = _hf_from_url(val)
            if hf:
                return hf

    for tokens, hf in KNOWN_HF_MODELS:
        if any(tok in stem or tok in text for tok in tokens):
            return hf

    raise SystemExit(
        f"Could not resolve HuggingFace model for {gguf_path}. "
        "Pass -HfModel explicitly or add a KNOWN_HF_MODELS entry."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gguf", type=Path, help="Path to .gguf model file")
    args = parser.parse_args()
    if not args.gguf.is_file():
        raise SystemExit(f"GGUF not found: {args.gguf}")
    print(resolve_hf_model(args.gguf.resolve()))


if __name__ == "__main__":
    main()