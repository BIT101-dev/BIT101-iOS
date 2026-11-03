"""Validate syntax-preserving literal and command formatting."""

import ast

from code_format_literals import wrap_literals
from code_format_shell import wrap_command, wrap_shell
from code_style_rules import embedded_findings, python_findings, tree_findings
from swift_format_literals import wrap_swift_literals
from swift_source_index import swift_syntax_index_sources


def python_format_test():
    fixtures = [
        "value = " + repr("中文 and spaces " * 20),
        "value = " + repr(b"bytes with escapes \\n" * 20),
        'value = f"' + "prefix " * 20 + '{name!r:>12}"',
    ]
    for source in fixtures:
        formatted = wrap_literals(source)
        assert ast.dump(ast.parse(source)) == ast.dump(ast.parse(formatted))
        assert max(map(len, formatted.splitlines())) <= 100


def shell_format_test():
    command = "  run " + "argument " * 25
    formatted = wrap_shell(command)
    assert all(line.strip() != "\\" for line in formatted.splitlines())
    assert max(map(len, formatted.splitlines())) <= 100
    assert tree_findings("file.sh", formatted, "shell") == []
    token = "  " + "x" * 110
    assert wrap_command(token, []) == token
    literal = "printf '%s' '" + "x" * 110 + "'\n"
    assert wrap_shell(literal).replace(" \\\n  ", " ") == literal
    script = "python3 - <<'PY'\n"
    body = "\n".join("    " * i + "if ready:" for i in range(5))
    script += body + "\n" + "    " * 5 + "pass\nPY\n"
    assert embedded_findings("file.sh", script)
    zsh = 'values=("${(@f)result}")\nfor value in "${values[@]}"; do true; done\n'
    assert tree_findings("file.sh", zsh, "shell") == []


def swift_format_test():
    expressions = [
        '"' + "plain text " * 20 + '"',
        '#"' + "raw \\ text " * 20 + '"#',
        '"' + "prefix " * 20 + "\\(ready ? first : second)" + " suffix" * 20 + '"',
    ]
    sources = {
        f"fixture{index}.swift": "let value = " + text for index, text in enumerate(expressions)
    }
    facts = swift_syntax_index_sources(sources)
    formatted = {name: wrap_swift_literals(source, facts[name]) for name, source in sources.items()}
    after = swift_syntax_index_sources(formatted)
    for name, original in facts.items():
        assert not after[name]["hasParseErrors"]
        assert [item.get("value") for item in original["styleLiterals"]] == [
            item.get("value") for item in after[name]["styleLiterals"]
        ]
    assert "\\(ready ? first : second)" in formatted["fixture2.swift"]


def self_test():
    python_format_test()
    shell_format_test()
    swift_format_test()
    source = "value = " + "a if ready else " * 5 + "last"
    assert python_findings("file.py", source)
