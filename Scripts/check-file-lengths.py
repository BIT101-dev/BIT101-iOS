#!/usr/bin/env python3
"""Enforce the repository's 1000-line limit on maintained text files."""
from pathlib import Path
import subprocess
import argparse

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 1000


def length_findings(contents: dict[str, str]) -> list[str]:
    return [f"{name}: {len(source.splitlines())} 行，文件上限为 {LIMIT} 行"
            for name, source in contents.items() if len(source.splitlines()) > LIMIT]


def index_files(root: Path = ROOT) -> dict[str, bytes]:
    entries = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=root).split(b"\0")
    objects = []
    for entry in filter(None, entries):
        metadata, name = entry.split(b"\t", 1)
        _, object_id, stage = metadata.split()
        if stage != b"0":
            raise ValueError("暂存区需要完成合并冲突处理。")
        objects.append((name.decode(), object_id))
    if not objects:
        return {}
    batch = subprocess.check_output(["git", "cat-file", "--batch"],
                                    input=b"\n".join(object_id for _, object_id in objects) + b"\n", cwd=root)
    contents = {}
    offset = 0
    for name, _ in objects:
        header_end = batch.index(b"\n", offset)
        size = int(batch[offset:header_end].split()[2])
        offset = header_end + 1
        contents[name] = batch[offset:offset + size]
        offset += size + 1
    return contents


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="validate the complete Git index")
    args = parser.parse_args()
    contents = {}
    if args.staged:
        for name, data in index_files().items():
            try:
                contents[name] = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
    else:
        contents = working_contents()
    assert length_findings({"source.swift": "line\n" * LIMIT}) == []
    assert len(length_findings({"document.md": "line\n" * (LIMIT + 1)})) == 1
    findings = length_findings(contents)
    if findings:
        print("\n".join(findings))
    return int(bool(findings))


def working_contents() -> dict[str, str]:
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
    return contents


if __name__ == "__main__":
    raise SystemExit(main())
