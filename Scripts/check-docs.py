#!/usr/bin/env python3
"""Validate repository Markdown links using the current document contents."""
from __future__ import annotations
import argparse
import re
import subprocess
import posixpath
import runpy
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
file_checks = runpy.run_path(str(ROOT / "Scripts/check-file-lengths.py"))


def findings(staged: bool = False, root: Path = ROOT) -> list[str]:
    contents = file_checks["index_files"](root) if staged else None
    names = subprocess.check_output([
        "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md",
    ], cwd=root, text=True).split("\0") if contents is None else [name for name in contents if name.endswith(".md")]
    errors = []
    for name in sorted(set(names) - {""}):
        path = root / name
        if "Fixtures" in path.parts or (contents is None and not path.is_file()):
            continue
        source = contents[name].decode() if contents is not None else path.read_text()
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", source):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            destination = target.split("#", 1)[0]
            exists = posixpath.normpath(str(Path(name).parent / destination)) in contents if contents is not None else (path.parent / destination).resolve().is_file()
            if not exists:
                errors.append(f"{name}: 文档链接需要有效文件：{target}")
    return errors


def staged_self_test() -> None:
    fixture = ROOT / ".build/static-audit/staged-content-self-test"
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True)
    try:
        subprocess.run(["git", "init", "-q", str(fixture)], check=True, capture_output=True)
        (fixture / "source.swift").write_text("line\n" * 1001)
        (fixture / "README.md").write_text("[link](missing.swift)\n")
        subprocess.run(["git", "add", "."], cwd=fixture, check=True, capture_output=True)
        (fixture / "source.swift").write_text("line\n")
        (fixture / "README.md").write_text("[link](source.swift)\n")
        contents = file_checks["index_files"](fixture)
        assert file_checks["length_findings"]({name: data.decode() for name, data in contents.items()})
        assert findings(staged=True, root=fixture) and findings(root=fixture) == []
        subprocess.run(["git", "add", "."], cwd=fixture, check=True, capture_output=True)
        (fixture / "source.swift").unlink()
        (fixture / "README.md").write_text("[link](missing.swift)\n")
        assert findings(staged=True, root=fixture) == [] and findings(root=fixture)
        subprocess.run(["git", "rm", "--cached", "-q", "source.swift"], cwd=fixture, check=True, capture_output=True)
        assert findings(staged=True, root=fixture)
    finally:
        shutil.rmtree(fixture)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="display every finding")
    parser.add_argument("--staged", action="store_true", help="validate links against the complete Git index")
    args = parser.parse_args()
    staged_self_test()
    errors = findings(staged=args.staged)
    if errors:
        print("\n".join(errors))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
