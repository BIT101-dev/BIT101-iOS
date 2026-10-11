#!/usr/bin/env python3
"""Compile repository Python and embedded Zsh Python delegates."""
from pathlib import Path
import ast
import re
import shlex
import sys
from validation_inputs import repository_script_paths

root = Path(sys.argv[1])

def command_words(prefix):
    lexer = shlex.shlex(prefix, posix=True, punctuation_chars=';|&()')
    lexer.whitespace_split = True
    lexer.commenters = ''
    try: words = list(lexer)
    except ValueError: return []
    boundaries = [index for index, word in enumerate(words) if set(word) <= set(';|&()')]
    return words[boundaries[-1] + 1:] if boundaries else words


def python_command_words(prefix):
    words = command_words(prefix)
    while words:
        if re.match(r'^[A-Za-z_]\w*=', words[0]) or words[0] in {'command', 'exec', 'if', 'elif', 'then', 'do', 'while', 'until', '{', '!'}:
            words.pop(0)
        elif words[0] == 'time':
            words.pop(0)
            if words and words[0] == '-p': words.pop(0)
        elif Path(words[0]).name == 'env':
            words.pop(0)
            while words and words[0].startswith('-'):
                option = words.pop(0)
                if option in {'-u', '--unset', '-C', '--chdir'}:
                    if not words: return None
                    words.pop(0)
                elif option == '--': break
                elif option not in {'-i', '--ignore-environment'} and not option.startswith(('--unset=', '--chdir=')): return None
        else: break
    if not words or not re.fullmatch(r'python(?:\d+(?:\.\d+)*)?', Path(words.pop(0)).name): return None
    return words


def inline_python_command(prefix):
    words = python_command_words(prefix)
    if words is None: return False
    while words:
        option = words.pop(0)
        if option == '-c' or re.fullmatch(r'-[bBdEiIOPqRsSuvVx]*c', option): return not words
        if option in {'-W', '-X'}:
            if not words: return False
            words.pop(0)
        elif not option.startswith('-') or option in {'-', '--', '-m'}: return False
    return False


def stdin_python_command(prefix):
    words = python_command_words(prefix)
    if words is None: return False
    while words:
        option = words.pop(0)
        if option == '-': return True
        if option == '--': return not words or words[0] == '-'
        if re.match(r'-[bBdEiIOPqRsSuvVx]*[cm]', option): return False
        if option in {'-W', '-X'}:
            if not words: return False
            words.pop(0)
        elif not option.startswith('-'): return False
    return True


def ansi_literal(body):
    escapes = {'a': b'\a', 'b': b'\b', 'e': b'\x1b', 'E': b'\x1b', 'f': b'\f',
        'n': b'\n', 'r': b'\r', 't': b'\t', 'v': b'\v', '\\': b'\\', "'": b"'", '"': b'"', '?': b'?'}
    pattern = re.compile(r'''\\(?:([abEefnrtv\\'"?])|x([\da-fA-F]{1,2})|u([\da-fA-F]{1,4})|U([\da-fA-F]{1,8})|([0-7]{1,3})|(.))''', re.DOTALL)
    result, position = bytearray(), 0
    for match in pattern.finditer(body):
        result.extend(body[position:match.start()].encode())
        escape, hexadecimal, short_unicode, long_unicode, octal, other = match.groups()
        if escape: result.extend(escapes[escape])
        elif hexadecimal: result.append(int(hexadecimal, 16))
        elif short_unicode or long_unicode: result.extend(chr(int(short_unicode or long_unicode, 16)).encode())
        elif octal: result.append(int(octal, 8) & 255)
        else: result.extend(other.encode())
        position = match.end()
    result.extend(body[position:].encode())
    return bytes(result).split(b'\0', 1)[0]


def quoted_command(source, position, *, ansi=False):
    quote, body, literal = source[position], [], True
    position += 1
    while position < len(source):
        character = source[position]
        if character == quote:
            value = ''.join(body)
            return ansi_literal(value) if ansi else value.encode(), position + 1, literal
        if ansi and character == '\\' and position + 1 < len(source):
            body.extend(source[position:position + 2]); position += 2
            continue
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


def command_argument(source, position):
    body, literal = bytearray(), True
    while position < len(source) and source[position] not in ' \t\r\n;|&()<>':
        ansi = source.startswith("$'", position)
        if ansi or source[position] in "'\"":
            value, position, segment_literal = quoted_command(source, position + int(ansi), ansi=ansi)
            body.extend(value); literal &= segment_literal
        elif source[position] == '\\' and position + 1 < len(source):
            if source[position + 1] != '\n': body.extend(source[position + 1].encode())
            position += 2
        else:
            if source[position] in '$`*?[': literal = False
            body.extend(source[position].encode()); position += 1
    return bytes(body), position, literal


def compile_embedded_python(source, path):
    headers = re.compile(r"<<(?P<tabs>-)?[ \t]*(?P<quote>['\"]?)(?P<label>[A-Za-z_]\w*)(?P=quote)(?=[ \t\n;|&<>]|$)")
    visible = [" "] * len(source)
    contexts = [("command", 0)]
    pending = []
    position = line_start = 0
    while position < len(source):
        character = source[position]
        context, context_start = contexts[-1]
        if context == 'command' and character not in ' \t\r\n;|&()<>#' and not source.startswith('\\\n', position) \
                and inline_python_command(''.join(visible[max(line_start, context_start):position])):
            argument_start = position
            body, position, literal = command_argument(source, position)
            if literal: compile(body.decode('utf-8'), str(path), 'exec')
            visible[argument_start] = '#'
            line_start = source.rfind('\n', 0, position) + 1
            continue
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
            ansi = character == "'" and position > 0 and visible[position - 1] == '$'
            argument_start = position - int(ansi)
            body, end, literal = quoted_command(source, position, ansi=ansi)
            if literal:
                visible[argument_start] = shlex.quote(body.decode('utf-8', errors='surrogateescape'))
                position = end
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
        opening = ''.join(visible[max(line_start, context_start):position])
        pending.append((header, header['label'].startswith('PY') or stdin_python_command(opening)))
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
for command in ("echo python3", "python3 -c 'pass'", "python3 -Bcpass", "python3 script.py", "python3 -m package"):
    compile_embedded_python(command + " <<'EOF'\nif True\nEOF\n", 'python-stdin-data-self-test')
for command in ('python3', 'python3 -B -', '"/fixture/Python Tools/python3" -', 'python3 -- -'):
    try: compile_embedded_python(command + " <<'EOF'\nif True\nEOF\n", 'python-stdin-code-self-test')
    except SyntaxError: pass
    else: raise AssertionError('Python 标准输入代码需要参与语法审计')
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

for prefix in ('python3 -c ', 'python3 -Bc ', 'python3 -OOuc ', '/usr/bin/python3 -B -c ', '"python3" -c ',
               "'python3' -c ", "$'python3' -c ", '"/fixture/Python Tools/python3" -c ',
               'value="$(python3 -c ', 'cat | python3 -c ', 'if python3 -c ', 'while python3 -c ',
               'until python3 -c ', '{ python3 -c ', 'time -p python3 -c ',
               'BIT101_FLAG=1 python3 -c ', 'BIT101_FLAG="two words" python3 -c ', 'env BIT101_FLAG=1 python3 -c ',
               'command env -i BIT101_FLAG=1 python3 -B -c ', 'exec /usr/bin/env -u "BIT101_FLAG" python3 -X dev -c '):
    suffix = ')"' if prefix.startswith('value=') else ''
    for quote in ("'", '"', "$'"):
        closing = quote[-1]
        compile_embedded_python(prefix + quote + 'pass' + closing + suffix, 'inline-python-self-test')
        try: compile_embedded_python(prefix + quote + 'if True' + closing + suffix, 'inline-python-self-test')
        except SyntaxError: pass
        else: raise AssertionError('Python -c 字面量需要参与语法审计')
compile_embedded_python('python3 -c "print(\\\"literal\\\")"', 'inline-escape-self-test')
for argument, expected in ((r"$'\q'", b'q'), (r"$'\c?\cA'", b'c?cA'), (r"$'a\0b'", b'a')):
    assert command_argument(argument, 0)[0] == expected
for argument in ("'for ''item in []: pass'", "'for 'item' in []: pass'", "p'ass'", "$'for item in []:\\n    pass'",
                 "$'print(\\'literal\\')'", "$'\\x70\\141\\u0073\\U00000073'", "'pa'$'ss'", "'pass' 'if True'", 'pass',
                 "\\\n    'pass'", 'p\\ass'):
    compile_embedded_python('python3 -Bc ' + argument, 'inline-argument-self-test')
for argument in ("'if ''True'", "$'if True\\n    pass'", "if' True'", "$'\\x69f True'", 'if\\ True', "\\\n  'if True'"):
    try: compile_embedded_python('python3 -c ' + argument, 'inline-argument-self-test')
    except SyntaxError: pass
    else: raise AssertionError('Python -c 完整字面参数需要参与语法审计')
for source in ('echo python3 -c \'if True\'', '# python3 -c \'if True\'', 'echo "python3 -c \'if True\'"',
               'python3 -c "$script"', 'cat <<\'EOF\'\npython3 -c \'if True\'\nEOF\n',
               "env BIT101_FLAG=1 echo python3 -c 'if True'", "python3 script.py -c 'if True'", "printf '%s' $'\\xff'"):
    compile_embedded_python(source, 'inline-shell-text-self-test')

for path in repository_script_paths(root, {'.py'}):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
for path in repository_script_paths(root, {'.sh'}):
    compile_embedded_python(path.read_text(encoding="utf-8"), path)


def import_cycles(sources):
    graph = {}
    for name, source in sources.items():
        imports = set()
        package = name if any(other.startswith(name + '.') for other in sources) else name.rpartition('.')[0]
        def add(module):
            local = package + '.' + module if package else module
            resolved = local if local in sources else module
            parts = resolved.split('.')
            imports.update(dependency for length in range(1, len(parts) + 1)
                           if (dependency := '.'.join(parts[:length])) != name or resolved == name)
        for node in ast.walk(ast.parse(source)):
            if isinstance(node, ast.ImportFrom):
                base = '.'.join(package.split('.')[:len(package.split('.')) - node.level + 1]) if node.level else ''
                module = '.'.join(filter(None, (base, node.module)))
                if module and not (node.level and module == name): add(module)
                for alias in node.names:
                    if alias.name != '*': add('.'.join(filter(None, (module, alias.name))))
            elif isinstance(node, ast.Import):
                for alias in node.names: add(alias.name)
        graph[name] = imports & sources.keys()
    active, completed, cycles = [], set(), set()
    def visit(name):
        if name in active:
            cycle = active[active.index(name):]
            rotations = [tuple(cycle[index:] + cycle[:index]) for index in range(len(cycle))]
            cycles.add(min(rotations))
        elif name not in completed:
            active.append(name)
            for dependency in sorted(graph[name]): visit(dependency)
            active.pop()
            completed.add(name)
    for name in sorted(graph): visit(name)
    return sorted(cycles)


assert import_cycles({'a': 'from b import value', 'b': 'import c', 'c': 'from a import value'}) == [('a', 'b', 'c')]
assert import_cycles({'a': 'def deferred():\n    import b', 'b': 'from a import value'}) == [('a', 'b')]
assert import_cycles({'a': 'from b import value', 'b': 'import json'}) == []
assert import_cycles({'a': 'import a'}) == [('a',)]
assert import_cycles({'nested.a': 'from .b import value', 'nested.b': 'import nested.a'}) == [('nested.a', 'nested.b')]
assert import_cycles({'nested.a': 'from nested import b', 'nested.b': 'import a'}) == [('nested.a', 'nested.b')]
assert import_cycles({'nested': 'from . import a', 'nested.a': 'import nested'}) == [('nested', 'nested.a')]
sources = {'.'.join(path.relative_to(root / 'Scripts').with_suffix('').parts[:-1] if path.stem == '__init__'
                   else path.relative_to(root / 'Scripts').with_suffix('').parts): path.read_text()
           for path in repository_script_paths(root, {'.py'})
           if path.is_relative_to(root / 'Scripts') and not path.stem.endswith('_tests')}
cycles = import_cycles(sources)
if cycles:
    raise ValueError('维护脚本依赖需要单向组织：' + '；'.join(' → '.join((*cycle, cycle[0])) for cycle in cycles))
