#!/usr/bin/env python3
"""Parse shell files with their declared interpreter."""

from concurrent.futures import ThreadPoolExecutor
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


def _check_shell_path(path: Path) -> str | None:
    try:
        result = subprocess.run(
            [interpreter(path.read_text()), "-n", str(path)], capture_output=True, text=True
        )
        return result.stderr.strip() if result.returncode else None
    except (KeyError, IndexError):
        return f"{path.relative_to(ROOT)}: shell 文件需要声明支持的解释器"


def main() -> int:
    source = "#!/bin/sh\nforeach value (one two)\n  echo $value\nend\n"
    assert subprocess.run(
        [interpreter(source), "-n"], input=source, text=True, capture_output=True
    ).returncode
    paths = repository_script_paths(ROOT, {".sh"})
    with ThreadPoolExecutor(max_workers=6) as pool:
        errors = [error for error in pool.map(_check_shell_path, paths) if error]
    if errors:
        print("\n".join(errors))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
