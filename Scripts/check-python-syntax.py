#!/usr/bin/env python3
"""Compile repository Python and embedded shell Python delegates."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def compile_embedded_python(source, path):
    headers = re.compile(r"<<(?P<tabs>-)?[ \t]*(?P<quote>['\"]?)(?P<label>[A-Za-z_]\w*)(?P=quote)(?=[ \t\n;|&<>]|$)")
    for header in headers.finditer(source):
        opening = source[source.rfind("\n", 0, header.start()) + 1:header.start()]
        if not header["label"].startswith("PY") and not re.search(r"(?:^|[\s(;|&])(?:[^\s'\"]*/)?python(?:\d+(?:\.\d+)*)?(?=\s|$)", opening):
            continue
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

for opening in ["<<PY", "<< 'PY'", '<<"PY"', "<<'PY'", "<<-PY", "<<'PY' >/dev/null", "<<'PY' | cat", "<<'PY' 2>&1", "<<'EOF'", '<<"END_SCRIPT"']:
    label = "EOF" if "EOF" in opening else "END_SCRIPT" if "END_SCRIPT" in opening else "PY"
    prefix = "\t" if opening == "<<-PY" else ""
    compile_embedded_python(f"python3 - {opening}\n{prefix}pass\n{prefix}{label}\n", "heredoc-self-test")
    try:
        compile_embedded_python(f"python3 - {opening}\n{prefix}if True\n{prefix}{label}\n", "heredoc-self-test")
    except SyntaxError:
        pass
    else:
        raise AssertionError(f"Python heredoc 语法审计遗漏：{opening}")

compile_embedded_python("cat <<'EOF'\nif True\nEOF\n", "shell-text-self-test")

for path in sorted((root / "Scripts").glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
scripts = [*(root / "Scripts").glob("*.sh"), *(root / "Cloudflare/EmergencyUpdateWorker/Scripts").glob("*.sh")]
for path in sorted(scripts):
    compile_embedded_python(path.read_text(encoding="utf-8"), path)
