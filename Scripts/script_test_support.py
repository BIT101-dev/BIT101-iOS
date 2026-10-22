"""Read public shell functions and named heredocs through stable script boundaries."""
from pathlib import Path
import re
import subprocess


def shell_function(path: Path, name: str) -> str:
    return subprocess.check_output(['zsh', '-c', 'source "$1"; typeset -f "$2"',
        'script-function', str(path), name], text=True)


def heredoc_span(source: str, label: str) -> tuple[int, int]:
    opening = re.search(r"<<-?\s*(['\"]?)" + re.escape(label) + r"\1[^\n]*\n", source)
    if opening is None: raise ValueError(f'脚本需要命名代码块：{label}')
    closing = re.search(r'(?m)^[ \t]*' + re.escape(label) + r'[ \t]*(?:\n|$)', source[opening.end():])
    if closing is None: raise ValueError(f'脚本代码块需要结束标记：{label}')
    return opening.end(), opening.end() + closing.start()


def heredoc_body(source: str, label: str) -> str:
    start, end = heredoc_span(source, label)
    return source[start:end]


def with_heredoc(source: str, label: str, program: str) -> str:
    start, end = heredoc_span(source, label)
    return source[:start] + program.rstrip('\n') + '\n' + source[end:]
