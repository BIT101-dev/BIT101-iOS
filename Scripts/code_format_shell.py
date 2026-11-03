"""Wrap shell commands at whitespace outside literal tokens."""

from __future__ import annotations

from tree_sitter import Language, Parser
import tree_sitter_bash

from code_style_rules import shell_tokens


def protected_columns(source: str) -> dict[int, list[tuple[int, int]]]:
    parser = Parser(Language(tree_sitter_bash.language()))
    tree = parser.parse(shell_tokens(source).encode())
    lines = source.splitlines()
    protected = {}
    literals = {
        "raw_string",
        "string_content",
        "comment",
        "heredoc_body",
        "expansion",
        "simple_expansion",
        "arithmetic_expansion",
    }
    pending = [tree.root_node]
    while pending:
        node = pending.pop()
        if node.type not in literals:
            pending.extend(node.named_children)
            continue
        for row in range(node.start_point.row, node.end_point.row + 1):
            if row >= len(lines):
                continue
            data = lines[row].encode()
            start = node.start_point.column if row == node.start_point.row else 0
            end = node.end_point.column if row == node.end_point.row else len(data)
            first = len(data[:start].decode(errors="ignore"))
            last = len(data[:end].decode(errors="ignore"))
            protected.setdefault(row, []).append((first, last))
    return protected


def wrap_command(line: str, protected: list[tuple[int, int]]) -> str:
    if len(line) <= 100:
        return line
    indentation = line[: len(line) - len(line.lstrip())] + "  "
    lines = []
    start = 0
    prefix = ""
    while len(prefix) + len(line) - start > 100:
        end = start + 98 - len(prefix)
        candidates = [
            index
            for index in range(start + 1, min(end + 1, len(line)))
            if line[index].isspace()
            and line[start:index].strip()
            and not any(first <= index < last for first, last in protected)
        ]
        if not candidates:
            break
        cut = max(candidates)
        lines.append(prefix + line[start:cut].rstrip() + " \\")
        start = cut + 1
        prefix = indentation
    lines.append(prefix + line[start:])
    return "\n".join(lines)


def wrap_shell(source: str) -> str:
    columns = protected_columns(source)
    return (
        "\n".join(
            wrap_command(line, columns.get(index, []))
            for index, line in enumerate(source.splitlines())
        )
        + "\n"
    )
