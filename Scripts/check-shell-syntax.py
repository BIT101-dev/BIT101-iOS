#!/usr/bin/env python3
"""Parse shell files with their declared interpreter."""
import subprocess
from pathlib import Path
from validation_inputs import repository_script_paths

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

ROOT = Path(__file__).resolve().parents[1]


def interpreter(source: str) -> str:
    header = source.splitlines()[0]
    declared = {"#!/bin/sh": "/bin/sh", "#!/bin/zsh": "/bin/zsh", "#!/bin/bash": "/bin/bash"}
    return declared[header]


def main() -> int:
    source = "#!/bin/sh\nforeach value (one two)\n  echo $value\nend\n"
    assert subprocess.run([interpreter(source), "-n"], input=source, text=True, capture_output=True).returncode
    errors = []
    for path in repository_script_paths(ROOT, {'.sh'}):
        try:
            result = subprocess.run([interpreter(path.read_text()), "-n", str(path)], capture_output=True, text=True)
            if result.returncode: errors.append(result.stderr.strip())
        except (KeyError, IndexError):
            errors.append(f"{path.relative_to(ROOT)}: shell 文件需要声明支持的解释器")
    if errors: print("\n".join(errors))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
