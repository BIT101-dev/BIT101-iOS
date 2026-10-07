#!/usr/bin/env python3
"""Enforce the repository's 1000-line limit on maintained text files."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 1000


def length_findings(contents: dict[str, str]) -> list[str]:
    return [f"{name}: {len(source.splitlines())} 行，文件上限为 {LIMIT} 行"
            for name, source in contents.items() if len(source.splitlines()) > LIMIT]


def main() -> int:
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).decode().split("\0")
    contents = {}
    for name in sorted(set(paths) - {""}):
        path = ROOT / name
        if path.is_file():
            try:
                contents[name] = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
    assert length_findings({"source.swift": "line\n" * LIMIT}) == []
    assert len(length_findings({"document.md": "line\n" * (LIMIT + 1)})) == 1
    findings = length_findings(contents)
    if findings:
        print("\n".join(findings))
    return int(bool(findings))


if __name__ == "__main__":
    raise SystemExit(main())
