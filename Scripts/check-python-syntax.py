#!/usr/bin/env python3
"""Compile repository Python and embedded Zsh Python delegates."""
from pathlib import Path, PurePosixPath
import argparse
import ast
import re
import runpy
import shlex
import subprocess
import sys
from validation_inputs import repository_script_paths, python_import_dependencies, python_execution_modules, is_worker_generated

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', nargs='?', type=Path, default=Path('.'))
parser.add_argument('--staged', action='store_true', help='validate the complete Git index')
parser.add_argument('--changed', action='store_true', help='validate changed staged scripts and their import graph')
parser.add_argument('--self-test', action='store_true', help='run parser and import regression cases')
args = parser.parse_args()
root = args.root.resolve()
if args.changed and not args.staged: parser.error('--changed requires --staged')
syntax_targets = None
if args.staged:
    index_files = runpy.run_path(str(Path(__file__).with_name('check-file-lengths.py')))['index_files']
    def included_script(name):
        path = PurePosixPath(name)
        return path.parts[0] in {'Scripts', 'Cloudflare', '.githooks'} and not is_worker_generated(path) \
            and (path.suffix in {'.py', '.sh'} or path.parts[0] == '.githooks' and not path.suffix)
    if args.changed:
        changed = set(filter(None, subprocess.check_output(['git', 'diff', '--cached', '--name-only', '-z',
            '--diff-filter=ACMR'], cwd=root).decode().split('\0')))
        if not changed.intersection({'Scripts/check-python-syntax.py', 'Scripts/check-file-lengths.py',
                'Scripts/validation_inputs.py', '.githooks/pre-commit'}):
            syntax_targets = {name for name in changed if included_script(name)}
            if not syntax_targets and not args.self_test: raise SystemExit(0)
    needs_import_graph = syntax_targets is None or any(name.endswith('.py') for name in syntax_targets)
    def included_source(name):
        return included_script(name) and (syntax_targets is None or name in syntax_targets
            or needs_import_graph and name.startswith('Scripts/') and name.endswith('.py'))
    script_sources = {name: data.decode('utf-8') for name, data in index_files(root, include=included_source).items()
        if included_source(name)}
else:
    script_sources = {path.relative_to(root).as_posix(): path.read_text(encoding='utf-8')
        for path in repository_script_paths(root, {'.py', '.sh'})}

def checked_python(source, path):
    compile(source, str(path), 'exec')
    if Path(path).name == 'validation_provenance.py' and any(
            isinstance(node, ast.Import) and any(alias.name in {'hashlib', 'hmac'} for alias in node.names)
            or isinstance(node, ast.ImportFrom) and node.module in {'hashlib', 'hmac'}
            for node in ast.walk(ast.parse(source))):
        raise SyntaxError(f'{path}: 一致性验收沿直接内容比较和原生身份执行。')
    filename = str(path) if str(path).endswith('.py') else str(path) + '.py'
    result = subprocess.run(['ruff', 'check', '--isolated', '--no-cache', '--select', 'F403,F405,F811,F821,F841',
        '--output-format', 'concise', '--stdin-filename', filename, '-'], input=source, capture_output=True, text=True)
    if result.returncode: raise SyntaxError(f'{path}:\n{result.stdout or result.stderr}')

def command_words(prefix, *, first=False):
    lexer = shlex.shlex(prefix, posix=True, punctuation_chars=';|&()')
    lexer.whitespace_split = True
    lexer.commenters = ''
    try: words = list(lexer)
    except ValueError: return []
    boundaries = [index for index, word in enumerate(words) if set(word) <= set(';|&()')]
    if first: return words[:boundaries[0]] if boundaries else words
    return words[boundaries[-1] + 1:] if boundaries else words


def python_command_words(prefix, suffix=''):
    words = command_words(prefix) + command_words(suffix, first=True)
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


def python_reads_descriptor(prefix, suffix='', descriptor='0'):
    words = python_command_words(prefix, suffix)
    if words is None: return False
    while words:
        option = words.pop(0)
        if option == '--': option = words.pop(0) if words else '-'
        if option == '-': return descriptor == '0'
        if re.match(r'-[bBdEiIOPqRsSuvVx]*[cm]', option): return False
        if option in {'-W', '-X'}:
            if not words: return False
            words.pop(0)
        elif not option.startswith('-'):
            return option in {f'/dev/fd/{descriptor}', f'/proc/self/fd/{descriptor}'} \
                or descriptor == '0' and option == '/dev/stdin'
    return descriptor == '0'


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
    while position < len(source) and source[position] not in ' \t\r\n;|&()<>`':
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
    headers = re.compile(r"(?<!<)(?:(?<![^\s;|&()])(?P<descriptor>\d+))?<<(?!<)(?P<tabs>-)?[ \t]*")
    redirects = re.compile(r'(?:\d+)?(?:&>>?|[<>]&|<>|>>?|<)(?!<)[ \t]*')
    visible = [" "] * len(source)
    contexts = [("command", 0)]
    pending = []
    position = line_start = 0
    while position < len(source):
        character = source[position]
        context, context_start = contexts[-1]
        if context in {'command', 'backtick'} and (redirect := redirects.match(source, position)):
            _, end, _ = command_argument(source, redirect.end())
            position = end
            continue
        if context in {'command', 'backtick'} and character not in ' \t\r\n;|&()<>#`' and not source.startswith('\\\n', position) \
                and inline_python_command(''.join(visible[max(line_start, context_start):position])):
            argument_start = position
            body, position, literal = command_argument(source, position)
            if literal: checked_python(body.decode('utf-8'), path)
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
            elif context == '"' and character == '`': contexts.append(('backtick', position + 1))
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
        elif character == '`':
            if context == 'backtick': contexts.pop()
            else: contexts.append(('backtick', position + 1))
            position += 1
            continue
        if character == '\n' and pending:
            position += 1
            command_end = position - 1
            for header in pending:
                suffix = ''.join(visible[header['end']:command_end])
                is_python = header['label'].startswith('PY') or python_reads_descriptor(
                    header['opening'], suffix, header['descriptor'])
                body = []
                for line in source[position:].splitlines(keepends=True):
                    position += len(line)
                    line = line.lstrip('\t') if header['tabs'] else line
                    if line.rstrip('\r\n') == header['label']: break
                    body.append(line)
                else: raise SyntaxError(f'{path}: heredoc 结束标记缺失')
                if is_python: checked_python(''.join(body), path)
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
        label, end, _ = command_argument(source, header.end())
        if not label: raise SyntaxError(f'{path}: heredoc 需要结束标记')
        delimiter = label.decode('utf-8')
        pending.append({'tabs': header['tabs'], 'label': delimiter, 'opening': opening, 'end': end,
            'descriptor': header['descriptor'] or '0'})
        position = end
    if pending: raise SyntaxError(f'{path}: heredoc 正文缺失')

if args.self_test:
    for code in ('import hashlib', 'from hashlib import sha256 as identity', 'import hmac'):
        try: checked_python(code, Path('Scripts/validation_provenance.py'))
        except SyntaxError: pass
        else: raise AssertionError('一致性验收沿内容比较执行')
    for opening in ["<<PY", "<< 'PY'", '<<"PY"', "<<'PY'", "<<-PY", "<<'PY' >/dev/null", "<<'PY' | cat", "<<'PY' 2>&1", "<<'EOF'", '<<"END_SCRIPT"', "<<'PY-CODE'", r"<<\EOF", '<<"PY CODE"', "<<E'OF'"]:
        label = command_argument(opening, re.match(r'<<-?\s*', opening).end())[0].decode('utf-8')
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
    for source in ("python3 /dev/fd/3 3<<'CODE'\n{code}\nCODE\n",
                   "3<<'CODE' python3 /dev/fd/3\n{code}\nCODE\n",
                   "python3 -B -- /dev/fd/4 argument 4<<-'TEXT'\n\t{code}\n\tTEXT\n",
                   "python3 /proc/self/fd/4 4<<'TEXT'\n{code}\nTEXT\n",
                   "python3 /dev/stdin <<'CODE'\n{code}\nCODE\n",
                   "python3 /dev/fd/0 <<'CODE'\n{code}\nCODE\n",
                   "python3 /dev/fd/3 <<'DATA' 3<<'CODE'\nif True\nDATA\n{code}\nCODE\n",
                   "python3 /dev/fd/3 3<<'CODE' 4<<'DATA'\n{code}\nCODE\nif True\nDATA\n"):
        compile_embedded_python(source.format(code='pass'), 'descriptor-code-self-test')
        try: compile_embedded_python(source.format(code='if True'), 'descriptor-code-self-test')
        except SyntaxError: pass
        else: raise AssertionError('Python 文件描述符正文需要按实际脚本路径参与语法审计')
    for command in ("python3 /dev/fd/3 4<<'CODE'", "python3 - 3<<'CODE'", "python3 -c 'pass' 3<<'CODE'",
                    "python3 script.py 3<<'CODE'", "cat 3<<'CODE'", "python3 /dev/fd/3 argument3<<'CODE'"):
        compile_embedded_python(command + '\nif True\nCODE\n', 'descriptor-data-self-test')
    optimized = subprocess.run([sys.executable, '-O', '-B', str(Path(__file__).resolve()), str(root)],
        capture_output=True, text=True)
    if optimized.returncode == 0 or 'Python 默认优化级别' not in optimized.stderr:
        raise AssertionError('独立 Python 语法审计需要核对断言执行环境')
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

    for source in ("2>/dev/null python3 -c '{code}'", ">/dev/null python3 -c '{code}'",
                   "python3 2>/dev/null -c '{code}'", "<<'EOF' python3 -\n{code}\nEOF\n",
                   "2>/dev/null <<'EOF' python3 -\n{code}\nEOF\n", "value=`python3 -c '{code}'`",
                   'value="`python3 -c \'{code}\'`"', "value=`python3 -c {code}`"):
        compile_embedded_python(source.format(code='pass'), 'redirect-substitution-self-test')
        try: compile_embedded_python(source.format(code='if True'), 'redirect-substitution-self-test')
        except SyntaxError: pass
        else: raise AssertionError('前置重定向及反引号命令替换需要参与 Python 语法审计')
    for source in ("2>/dev/null echo python3 -c 'if True'", "<<'EOF' cat\nif True\nEOF\n",
                   "echo '`python3 -c if True`'", 'echo "\\`python3 -c if True\\`"'):
        compile_embedded_python(source, 'redirect-substitution-text-self-test')

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

    checked_python('from datetime import timezone\nprint(timezone.utc)', 'defined-name-self-test')
    for source in ('python3 -c "print(timezone.utc)"', "python3 - <<'PY'\nprint(timezone.utc)\nPY\n"):
        try: compile_embedded_python(source, 'undefined-name-self-test')
        except SyntaxError as error: assert 'F821' in str(error)
        else: raise AssertionError('嵌入 Python 的未定义名称需要参与审计')
    try: checked_python('def normalize(): return timezone.utc', 'undefined-name-self-test')
    except SyntaxError as error: assert 'F821' in str(error)
    else: raise AssertionError('独立 Python 的未定义名称需要参与审计')

    for source in ('from code_quality_rules import *', 'from code_quality_rules import *\nundefined_detector_name()'):
        try: checked_python(source, 'explicit-import-self-test')
        except SyntaxError as error:
            assert 'F403' in str(error)
            if 'undefined_detector_name' in source: assert 'F405' in str(error)
        else: raise AssertionError('Python 名称审计需要显式导入及确定的名称来源')

for name, source in script_sources.items():
    if syntax_targets is not None and name not in syntax_targets: continue
    if name.endswith('.py'): checked_python(source, root / name)
    else: compile_embedded_python(source, root / name)


def import_cycles(sources, directory=''):
    resolved = python_execution_modules({name: name for name in sources}, directory)
    dependencies = python_import_dependencies({name: sources[canonical] for name, canonical in resolved.items()})
    graph = {name: set() for name in resolved.values()}
    for name, imports in dependencies.items():
        graph[resolved[name]].update(resolved[dependency] for dependency in imports)
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


if args.self_test:
    assert import_cycles({'a': 'from b import value', 'b': 'import c', 'c': 'from a import value'}) == [('a', 'b', 'c')]
    assert import_cycles({'a': 'def deferred():\n    import b', 'b': 'from a import value'}) == [('a', 'b')]
    assert import_cycles({'a': 'from b import value', 'b': 'import json'}) == []
    assert import_cycles({'a': 'import a'}) == [('a',)]
    assert import_cycles({'nested.a': 'from .b import value', 'nested.b': 'import nested.a'}) == [('nested.a', 'nested.b')]
    assert import_cycles({'nested.a': 'from nested import b', 'nested.b': 'import a'}) == []
    assert import_cycles({'nested.a': 'from nested import b', 'nested.b': 'from . import a'}) == [('nested.a', 'nested.b')]
    assert import_cycles({'nested': 'from . import a', 'nested.a': 'import nested'}) == [('nested', 'nested.a')]
    assert import_cycles({'pkg.a': 'import json', 'pkg.json': 'import pkg.a'}) == []
    assert import_cycles({'a': 'import pkg.b', 'pkg.b': 'import a', 'pkg.a': 'pass'}) == [('a', 'pkg.b')]
    assert import_cycles({'pkg.a': 'from json import loads', 'pkg.json': 'import pkg.a'}) == []
    assert import_cycles({'a': 'from pkg import b', 'pkg.b': 'from a import value', 'pkg.a': 'pass'}) == [('a', 'pkg.b')]
    assert import_cycles({'pkg.entry': 'import helper', 'pkg.helper': 'import entry'}, 'pkg') == [('pkg.entry', 'pkg.helper')]
    assert import_cycles({'helper': 'pass', 'pkg.entry': 'import helper', 'pkg.helper': 'import entry'}, 'pkg') == [('pkg.entry', 'pkg.helper')]
    assert import_cycles({'pkg.entry': 'import helper', 'pkg.helper': 'import json'}, 'pkg') == []
sources = {'.'.join(path.with_suffix('').parts[:-1] if path.stem == '__init__'
                   else path.with_suffix('').parts): source
           for name, source in script_sources.items() if name.startswith('Scripts/') and name.endswith('.py')
           for path in [PurePosixPath(name).relative_to('Scripts')]}
cycles = sorted({cycle for directory in {'', *(name.rpartition('.')[0] for name in sources)}
                 for cycle in import_cycles(sources, directory)})
if cycles:
    raise ValueError('维护脚本依赖需要单向组织：' + '；'.join(' → '.join((*cycle, cycle[0])) for cycle in cycles))
