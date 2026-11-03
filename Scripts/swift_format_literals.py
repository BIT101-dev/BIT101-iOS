"""Wrap Swift literal source at token boundaries with line continuations."""
from __future__ import annotations

import re
import json


def plain_atoms(text: str, pounds: str):
    escape = re.escape('\\' + pounds)
    pattern = escape + r'(?:u\{[0-9a-fA-F]+\}|.)|.'
    return re.findall(pattern, text, flags=re.DOTALL)


def split_content(atoms, indent, continuation):
    lines = []
    line = []
    limit = 100 - len(indent) - len(continuation)
    for atom in atoms:
        if line and sum(map(len, line)) + len(atom) > limit:
            spaces = [index + 1 for index, value in enumerate(line) if value == ' ']
            cut = spaces[-1] if spaces else len(line)
            lines.append(indent + ''.join(line[:cut]) + continuation)
            line = line[cut:]
        line.append(atom)
    lines.append(indent + ''.join(line))
    return '\n'.join(lines)


def format_literal(data: bytes, literal: dict) -> str:
    start, end = literal['start'], literal['end']
    raw = data[start:end].decode()
    pounds, quote = literal['pounds'], literal['quote']
    prefix = data[:start].decode().rsplit('\n', 1)[-1]
    value = literal.get('value')
    base_indent = prefix[:len(prefix) - len(prefix.lstrip())]
    if quote == '"""' and value is not None and all(ord(char) >= 32 for char in value):
        compact = json.dumps(value, ensure_ascii=False)
        if len(base_indent) + len(compact) <= 100:
            return compact
    if all(len(line) <= 100 for line in raw.splitlines()[1:]):
        if len(raw.splitlines()) > 1 or len(base_indent) + len(raw) <= 100:
            return raw
    if quote == '"""':
        closing = raw.rsplit('\n', 1)[-1]
        indent = closing[:len(closing) - len(closing.lstrip())]
    else:
        indent = base_indent + '    '
    continuation = '\\' + pounds
    expression_ranges = [
        (part['start'], part['end'])
        for part in literal['parts'] if part['isExpression']
    ]
    atoms = []
    content_start = start + len(pounds) + len(quote)
    content_end = end - len(pounds) - len(quote)
    position = content_start
    for first, last in expression_ranges:
        atoms.extend(plain_atoms(data[position:first].decode(), pounds))
        atoms.append(data[first:last].decode())
        position = last
    atoms.extend(plain_atoms(data[position:content_end].decode(), pounds))
    if quote == '"""':
        return wrap_multiline(raw, atoms, indent, continuation)
    body = split_content(atoms, indent, continuation)
    return pounds + '"""\n' + body + '\n' + indent + '"""' + pounds


def wrap_multiline_text(
    text: str, indent: str, continuation: str, offset: int, allowed_offsets: set[int]
) -> str:
    remainder = text
    pieces = []
    while len(remainder) > 100:
        limit = 100 - len(continuation)
        cuts = [
            cut for cut in range(len(indent) + 1, limit + 1)
            if offset + cut in allowed_offsets
        ]
        if not cuts:
            break
        spaces = [cut for cut in cuts if remainder[cut - 1] == ' ']
        cut = max(spaces or cuts)
        pieces.append(remainder[:cut] + continuation)
        remainder = indent + remainder[cut:]
        offset += cut - len(indent)
    pieces.append(remainder)
    return '\n'.join(pieces)


def wrap_multiline(raw, atoms, indent, continuation):
    lines = raw.splitlines(keepends=True)
    changes = []
    position = len(lines[0])
    boundaries = {0}
    # Atomic expression segments keep interpolations intact.
    current = 0
    for atom in atoms:
        current += len(atom)
        boundaries.add(current)
    content_offset = raw.index('"""') + 3
    for line in lines[1:-1]:
        text = line.rstrip('\n')
        if len(text) > 100:
            offset = position - content_offset
            wrapped = wrap_multiline_text(text, indent, continuation, offset, boundaries)
            changes.append((position, position + len(text), wrapped))
        position += len(line)
    for start, end, replacement in reversed(changes):
        raw = raw[:start] + replacement + raw[end:]
    return raw


def wrap_swift_literals(source: str, facts: dict) -> str:
    data = source.encode()
    changes = []
    for literal in facts['styleLiterals']:
        rendered = format_literal(data, literal)
        current = data[literal['start']:literal['end']].decode()
        if rendered != current:
            changes.append((literal['start'], literal['end'], rendered.encode()))
    changes = [
        change for change in changes
        if not any(change[0] < other[0] and other[1] < change[1] for other in changes)
    ]
    for start, end, replacement in sorted(changes, reverse=True):
        data = data[:start] + replacement + data[end:]
    return data.decode()
