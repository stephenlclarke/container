#!/usr/bin/env python3
"""Update a Homebrew formula to point at a branch release asset."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--formula", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--formula-class", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--asset", required=True)
    return parser.parse_args()


def replace_once(pattern: str, replacement: str, text: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected exactly one match for pattern: {pattern}")
    return updated


def main() -> None:
    args = parse_args()
    text = args.formula.read_text(encoding="utf-8") if args.formula.exists() else args.template.read_text(encoding="utf-8")
    text = replace_once(r"^class \w+ < Formula$", f"class {args.formula_class} < Formula", text)
    text = replace_once(r'^  url ".+"$', f'  url "{args.url}"', text)
    text = replace_once(r"^  sha256 .+$", f'  sha256 "{args.sha256}"', text)
    text = replace_once(r'^  version ".+"$', f'  version "{args.version}"', text)
    text = replace_once(
        r"This formula installs the .+ prebuilt (?:release|package) asset:\n        .+\.tar\.gz",
        f"This formula installs the {args.label} prebuilt package asset:\n        {args.asset}",
        text,
    )
    args.formula.parent.mkdir(parents=True, exist_ok=True)
    args.formula.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
