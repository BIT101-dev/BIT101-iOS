#!/usr/bin/env python3
"""Validate repository Markdown links using the current document contents."""
from __future__ import annotations
import argparse
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def findings() -> list[str]:
    names = subprocess.check_output([
        "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md",
    ], cwd=ROOT, text=True).split("\0")
    errors = []
    for name in sorted(set(names) - {""}):
        path = ROOT / name
        if "Fixtures" in path.parts or not path.is_file():
            continue
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", path.read_text()):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            if not (path.parent / target.split("#", 1)[0]).resolve().is_file():
                errors.append(f"{name}: 文档链接需要有效文件：{target}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="display every finding")
    parser.parse_args()
    errors = findings()
    if errors:
        print("\n".join(errors))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
