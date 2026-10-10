#!/usr/bin/env python3
"""Compile repository Python and embedded shell Python delegates."""
from pathlib import Path
import re
import shlex
import sys

root = Path(sys.argv[1])

def command_words(prefix):
    lexer = shlex.shlex(prefix, posix=True, punctuation_chars=';|&()')
    lexer.whitespace_split = True
    lexer.commenters = ''
    try: words = list(lexer)
    except ValueError: return []
    boundaries = [index for index, word in enumerate(words) if set(word) <= set(';|&()')]
    return words[boundaries[-1] + 1:] if boundaries else words


def inline_python_command(prefix):
    words = command_words(prefix)
    while words:
        if re.match(r'^[A-Za-z_]\w*=', words[0]) or words[0] in {'command', 'exec', 'if', 'elif', 'then', 'do', '!'}:
            words.pop(0)
        elif Path(words[0]).name == 'env':
            words.pop(0)
            while words and words[0].startswith('-'):
                option = words.pop(0)
                if option in {'-u', '--unset', '-C', '--chdir'}:
                    if not words: return False
                    words.pop(0)
                elif option == '--': break
                elif option not in {'-i', '--ignore-environment'} and not option.startswith(('--unset=', '--chdir=')): return False
        else: break
    if not words or not re.fullmatch(r'(?:[^\s\'\"]*/)?python(?:\d+(?:\.\d+)*)?', words.pop(0)): return False
    while words:
        option = words.pop(0)
        if option == '-c': return not words
        if option in {'-W', '-X'}:
            if not words: return False
            words.pop(0)
        elif not option.startswith('-') or option in {'-', '--', '-m'}: return False
    return False


def quoted_command(source, position):
    quote, body, literal = source[position], [], True
    position += 1
    while position < len(source):
        character = source[position]
        if character == quote: return ''.join(body), position + 1, literal
        if quote == '"' and character == '\\' and position + 1 < len(source):
            following = source[position + 1]
            if following in '$`"\\\n':
                if following != '\n': body.append(following)
                position += 2
                continue
        if quote == '"' and character in '$`': literal = False
        body.append(character)
        position += 1
    raise SyntaxError('Python -c 引号需要完整闭合')


def compile_embedded_python(source, path):
    headers = re.compile(r"<<(?P<tabs>-)?[ \t]*(?P<quote>['\"]?)(?P<label>[A-Za-z_]\w*)(?P=quote)(?=[ \t\n;|&<>]|$)")
    interpreter = re.compile(r"(?:^|[\s(;|&])(?:[^\s'\"]*/)?python(?:\d+(?:\.\d+)*)?(?=\s|$)")
    visible = [" "] * len(source)
    contexts = [("command", 0)]
    pending = []
    position = line_start = 0
    while position < len(source):
        character = source[position]
        context, context_start = contexts[-1]
        if character == "\\" and context != "'":
            position += 2
            continue
        if context in {"'", '"'}:
            if character == context: contexts.pop()
            elif context == '"' and source.startswith("$(", position):
                contexts.append(("command", position + 2)); position += 1
            position += 1
            continue
        if character == "#" and (position == 0 or source[position - 1] in " \t\n;|&()"):
            newline = source.find("\n", position)
            position = len(source) if newline < 0 else newline
            continue
        if character in "'\"":
            if inline_python_command(''.join(visible[max(line_start, context_start):position])):
                body, position, literal = quoted_command(source, position)
                if literal: compile(body, str(path), 'exec')
                line_start = source.rfind('\n', 0, position) + 1
                continue
            visible[position] = '_'
            contexts.append((character, position)); position += 1
            continue
        if character == "(": contexts.append(("command", position + 1))
        elif character == ")" and len(contexts) > 1: contexts.pop()
        if character == '\n' and pending:
            position += 1
            for header, is_python in pending:
                body = []
                for line in source[position:].splitlines(keepends=True):
                    position += len(line)
                    line = line.lstrip('\t') if header['tabs'] else line
                    if line.rstrip('\r\n') == header['label']: break
                    body.append(line)
                else: raise SyntaxError(f'{path}: heredoc 结束标记缺失')
                if is_python: compile(''.join(body), str(path), 'exec')
            pending.clear()
            line_start = position
            continue
        header = headers.match(source, position)
        if header is None:
            visible[position] = character
            if character == "\n": line_start = position + 1
            position += 1
            continue
        opening = ' '.join(command_words(''.join(visible[max(line_start, context_start):position])))
        pending.append((header, header['label'].startswith('PY') or interpreter.search(opening) is not None))
        position = header.end()
    if pending: raise SyntaxError(f'{path}: heredoc 正文缺失')

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
for command, bodies in [
    ("cat <<'TEXT' | python3 - <<'EOF'", 'if True\nTEXT\n{python}\nEOF\n'),
    ("python3 - <<'EOF' | cat <<'TEXT'", '{python}\nEOF\nif True\nTEXT\n'),
    ("cat <<'TEXT'; python3 - <<-EOF", 'plain text\nTEXT\n\t{python}\n\tEOF\n'),
    ("cat <<'TEXT' | \\\npython3 - <<'EOF'", 'plain text\nTEXT\n{python}\nEOF\n'),
    ("python3 - <<'FIRST' | python3 - <<'SECOND'", 'pass\nFIRST\n{python}\nSECOND\n'),
]:
    compile_embedded_python(command + '\n' + bodies.format(python='pass'), 'multiple-heredoc-self-test')
    try: compile_embedded_python(command + '\n' + bodies.format(python='if True'), 'multiple-heredoc-self-test')
    except SyntaxError: pass
    else: raise AssertionError('多重 heredoc 的各 Python 正文需要参与语法检查')
for source in ("# python3 <<'PY'\n", "echo value # python3 <<'PY'\n", 'echo "python3 <<PY"\n',
               "cat <<'EOF'\n# python3 <<'PY'\nEOF\n"):
    compile_embedded_python(source, "shell-lexical-self-test")
for source in ("python3 - \\\n <<'EOF'\nif True\nEOF\n", 'value="$(python3 - <<\'EOF\'\nif True\nEOF\n)"\n'):
    try: compile_embedded_python(source, "shell-continuation-self-test")
    except SyntaxError: pass
    else: raise AssertionError("Python heredoc 语法审计需要覆盖续行及命令替换")

for prefix in ('python3 -c ', '/usr/bin/python3 -B -c ', 'value="$(python3 -c ', 'cat | python3 -c ', 'if python3 -c ',
               'BIT101_FLAG=1 python3 -c ', 'BIT101_FLAG="two words" python3 -c ', 'env BIT101_FLAG=1 python3 -c ',
               'command env -i BIT101_FLAG=1 python3 -B -c ', 'exec /usr/bin/env -u "BIT101_FLAG" python3 -X dev -c '):
    suffix = ')"' if prefix.startswith('value=') else ''
    for quote in ("'", '"'):
        compile_embedded_python(prefix + quote + 'pass' + quote + suffix, 'inline-python-self-test')
        try: compile_embedded_python(prefix + quote + 'if True' + quote + suffix, 'inline-python-self-test')
        except SyntaxError: pass
        else: raise AssertionError('Python -c 字面量需要参与语法审计')
compile_embedded_python('python3 -c "print(\\\"literal\\\")"', 'inline-escape-self-test')
for source in ('echo python3 -c \'if True\'', '# python3 -c \'if True\'', 'echo "python3 -c \'if True\'"',
               'python3 -c "$script"', 'cat <<\'EOF\'\npython3 -c \'if True\'\nEOF\n',
               "env BIT101_FLAG=1 echo python3 -c 'if True'", "python3 script.py -c 'if True'"):
    compile_embedded_python(source, 'inline-shell-text-self-test')

for path in sorted((root / "Scripts").glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
scripts = [*(root / "Scripts").glob("*.sh"), *(root / "Cloudflare/EmergencyUpdateWorker/Scripts").glob("*.sh")]
for path in sorted(scripts):
    compile_embedded_python(path.read_text(encoding="utf-8"), path)
