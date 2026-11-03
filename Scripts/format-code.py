#!/usr/bin/env python3
"""Format maintained code using the repository's 100-character line width."""

from __future__ import annotations

import argparse
import ast
import shlex
import subprocess
from pathlib import Path

from python_shell import visit_python_shell
from code_format_literals import wrap_literals
from code_format_shell import wrap_shell
from validation_inputs import repository_input_names

ROOT = Path(__file__).resolve().parents[1]


def format_python(source: str, name: str) -> str:
    original = source
    source = wrap_literals(source)
    result = subprocess.run(
        [
            "ruff",
            "format",
            "--isolated",
            "--no-cache",
            "--line-length",
            "100",
            "--stdin-filename",
            name + ".py",
            "-",
        ],
        input=source,
        text=True,
        capture_output=True,
        check=True,
    ).stdout
    if ast.dump(ast.parse(original)) != ast.dump(ast.parse(result)):
        raise ValueError(f"{name}: 格式化改变了 Python 语法树")
    return result


def format_shell(source: str, name: str) -> str:
    changes = []

    def collect(body, start, end, inline):
        formatted = format_python(body, name)
        if inline:
            formatted = shlex.quote(formatted.rstrip("\n"))
        changes.append((start, end, formatted))

    visit_python_shell(source, name, collect)
    for start, end, body in reversed(changes):
        source = source[:start] + body + source[end:]
    return wrap_shell(source)


def format_swift(paths: list[str]) -> None:
    if not paths:
        return
    tool = subprocess.check_output(["xcrun", "--find", "swift-format"], text=True).strip()
    subprocess.run(
        [tool, "format", "--configuration", str(ROOT / ".swift-format"), "-i", *paths],
        cwd=ROOT,
        check=True,
    )
    from swift_source_index import swift_syntax_index_sources
    from swift_format_literals import wrap_swift_literals

    sources = {name: (ROOT / name).read_text() for name in paths}
    facts = swift_syntax_index_sources(sources)
    changed = {
        name: wrapped for name, source in sources.items()
        if (wrapped := wrap_swift_literals(source, facts[name])) != source
    }
    verified = swift_syntax_index_sources(changed) if changed else {}
    for name, source in changed.items():
        before = [literal.get('value') for literal in facts[name]['styleLiterals']]
        after = [literal.get('value') for literal in verified[name]['styleLiterals']]
        if before != after or verified[name]['hasParseErrors']:
            raise ValueError(f'{name}: 字符串排版改变了字面值或语法')
        (ROOT / name).write_text(source)


def format_js(paths: list[str]) -> None:
    if not paths:
        return
    subprocess.run(
        ["prettier", "--write", "--print-width", "100", *paths],
        cwd=ROOT,
        check=True,
        stdout=subprocess.DEVNULL,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    names = args.paths or sorted(repository_input_names(ROOT))
    groups = {suffix: [] for suffix in (".swift", ".py", ".sh", ".js")}
    for name in names:
        if (suffix := Path(name).suffix) in groups:
            groups[suffix].append(name)
    format_swift(groups[".swift"])
    format_js(groups[".js"])
    for suffix in (".py", ".sh"):
        formatter = format_python if suffix == ".py" else format_shell
        for name in groups[suffix]:
            path = ROOT / name
            source = path.read_text()
            formatted = formatter(source, name)
            if source != formatted:
                path.write_text(formatted)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
