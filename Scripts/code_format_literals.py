"""Reflow literal spellings while preserving their Python values."""
from __future__ import annotations

import ast
import io
import tokenize


def value_chunks(value, width):
    start = 0
    while start < len(value):
        end = start + 1
        while end < len(value) and len(repr(value[start:end + 1])) <= width:
            end += 1
        yield value[start:end]
        start = end


def literal_parts(node, width):
    if isinstance(node, ast.Constant):
        return [repr(part) for part in value_chunks(node.value, width)] or [repr(node.value)]
    parts = []
    for value in node.values:
        if isinstance(value, ast.Constant):
            parts.extend(
                ast.unparse(ast.JoinedStr(values=[ast.Constant(part)]))
                for part in value_chunks(value.value, width - 3)
            )
        else:
            parts.append(ast.unparse(ast.JoinedStr(values=[value])))
    return parts or ["f''"]


class LiteralVisitor(ast.NodeVisitor):
    def __init__(self, source):
        self.source = source
        self.nodes = []

    def visit_JoinedStr(self, node):
        self.nodes.append(node)

    def visit_Constant(self, node):
        if isinstance(node.value, (str, bytes)):
            self.nodes.append(node)


def wrap_literals(source: str) -> str:
    visitor = LiteralVisitor(source)
    visitor.visit(ast.parse(source))
    lines = source.splitlines(keepends=True)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line.encode()))
    comments = [
        token for token in tokenize.generate_tokens(io.StringIO(source).readline)
        if token.type == tokenize.COMMENT
    ]
    changes = []
    for node in visitor.nodes:
        widths = [len(text.rstrip('\n')) for text in lines[node.lineno - 1:node.end_lineno]]
        prefix = lines[node.lineno - 1].encode()[:node.col_offset].decode()
        if max(widths) <= 100:
            continue
        indent = ' ' * (len(prefix) - len(prefix.lstrip()))
        parts = literal_parts(node, 85 - len(indent))
        leading = [
            comment.string for comment in comments
            if (node.lineno, node.col_offset) <= comment.start
            and comment.end <= (node.end_lineno, node.end_col_offset)
        ]
        body = '\n'.join(indent + '    ' + part for part in leading + parts)
        replacement = '(\n' + body + '\n' + indent + ')'
        start = offsets[node.lineno - 1] + node.col_offset
        end = offsets[node.end_lineno - 1] + node.end_col_offset
        changes.append((start, end, replacement.encode()))
    data = source.encode()
    for start, end, replacement in sorted(changes, reverse=True):
        data = data[:start] + replacement + data[end:]
    result = data.decode()
    if ast.dump(ast.parse(source)) != ast.dump(ast.parse(result)):
        raise ValueError('字符串排版改变了 Python 语法树')
    return result
