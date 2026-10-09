#!/usr/bin/env python3
"""Compile repository Python and embedded shell Python delegates."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def compile_embedded_python(source, path):
    headers = re.compile(r"<<(?P<tabs>-)?[ \t]*(?P<quote>['\"]?)(?P<label>PY\w*)(?P=quote)(?=[ \t\n;|&<>]|$)")
    for header in headers.finditer(source):
        body = []
        opening_end = source.find("\n", header.end())
        if opening_end < 0: raise SyntaxError(f"{path}: Python heredoc 正文缺失")
        for line in source[opening_end + 1:].splitlines(keepends=True):
            line = line.lstrip("\t") if header["tabs"] else line
            if line.rstrip("\r\n") == header["label"]:
                break
            body.append(line)
        else:
            raise SyntaxError(f"{path}: Python heredoc 结束标记缺失")
        compile("".join(body), str(path), "exec")

for opening in ["<<PY", "<< 'PY'", '<<"PY"', "<<'PY'", "<<-PY", "<<'PY' >/dev/null", "<<'PY' | cat", "<<'PY' 2>&1"]:
    prefix = "\t" if opening == "<<-PY" else ""
    compile_embedded_python(f"python3 - {opening}\n{prefix}pass\n{prefix}PY\n", "heredoc-self-test")
    try:
        compile_embedded_python(f"python3 - {opening}\n{prefix}if True\n{prefix}PY\n", "heredoc-self-test")
    except SyntaxError:
        pass
    else:
        raise AssertionError(f"Python heredoc 语法审计遗漏：{opening}")

for path in sorted((root / "Scripts").glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
scripts = [*(root / "Scripts").glob("*.sh"), *(root / "Cloudflare/EmergencyUpdateWorker/Scripts").glob("*.sh")]
for path in sorted(scripts):
    compile_embedded_python(path.read_text(encoding="utf-8"), path)
