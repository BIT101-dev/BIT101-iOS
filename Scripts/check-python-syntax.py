#!/usr/bin/env python3
"""Compile repository Python and embedded Zsh Python delegates."""

from pathlib import Path, PurePosixPath
from python_shell import (
    command_words,
    python_command_words,
    inline_python_command,
    python_reads_descriptor,
    ansi_literal,
    quoted_command,
    command_argument,
    visit_python_shell,
)

import argparse
import ast
import re
import runpy
import shlex
import subprocess
import sys
from validation_inputs import (
    repository_script_paths,
    python_import_dependencies,
    python_execution_modules,
    is_worker_generated,
)

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("root", nargs="?", type=Path, default=Path("."))
parser.add_argument("--staged", action="store_true", help="validate the complete Git index")
parser.add_argument(
    "--changed", action="store_true", help="validate changed staged scripts and their import graph"
)
parser.add_argument(
    "--self-test", action="store_true", help="run parser and import regression cases"
)
args = parser.parse_args()
root = args.root.resolve()
if args.changed and not args.staged:
    parser.error("--changed requires --staged")
syntax_targets = None
if args.staged:
    index_files = runpy.run_path(str(Path(__file__).with_name("check-file-lengths.py")))[
        "index_files"
    ]

    def included_script(name):
        path = PurePosixPath(name)
        return (
            path.parts[0] in {"Scripts", "Cloudflare", ".githooks"}
            and not is_worker_generated(path)
            and (path.suffix in {".py", ".sh"} or path.parts[0] == ".githooks" and not path.suffix)
        )

    def changed_syntax_targets(names: set[str]) -> set[str]:
        return {name for name in names if included_script(name)}

    if args.changed:
        changed = set(
            filter(
                None,
                subprocess.check_output(
                    ["git", "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRD"],
                    cwd=root,
                )
                .decode()
                .split("\0"),
            )
        )
        deleted = set(
            filter(
                None,
                subprocess.check_output(
                    ["git", "diff", "--cached", "--name-only", "-z", "--diff-filter=D"], cwd=root
                )
                .decode()
                .split("\0"),
            )
        )
        if not any(name.endswith(".py") for name in deleted) and not changed.intersection(
            {
                "Scripts/check-python-syntax.py",
                "Scripts/check-file-lengths.py",
                "Scripts/validation_inputs.py",
                ".githooks/pre-commit",
            }
        ):
            syntax_targets = changed_syntax_targets(changed)
            if not syntax_targets and not args.self_test:
                raise SystemExit(0)
    needs_import_graph = syntax_targets is None or bool(syntax_targets)

    def included_source(name):
        return included_script(name) and (
            syntax_targets is None
            or name in syntax_targets
            or needs_import_graph
            and name.startswith("Scripts/")
            and name.endswith(".py")
        )

    script_sources = {
        name: data.decode("utf-8")
        for name, data in index_files(root, include=included_source).items()
        if included_source(name)
    }
else:
    script_sources = {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
        for path in repository_script_paths(root, {".py", ".sh"})
    }

RUFF_ARGUMENTS = [
    "ruff",
    "check",
    "--isolated",
    "--no-cache",
    "--select",
    "F403,F405,F811,F821,F841",
    "--output-format",
    "concise",
]


def run_ruff(arguments, source=None):
    return subprocess.run(
        [*RUFF_ARGUMENTS, *arguments], input=source, capture_output=True, text=True
    )


def checked_python(source, path, *, lint=True, imports=None):
    compile(source, str(path), "exec")
    if imports is not None:
        if missing := missing_imports({**imports, "__embedded__": source}, only="__embedded__"):
            raise SyntaxError(f"{path}:\n" + "\n".join(missing))
    if Path(path).name == "validation_provenance.py" and any(
        isinstance(node, ast.Import)
        and any(alias.name in {"hashlib", "hmac"} for alias in node.names)
        or isinstance(node, ast.ImportFrom)
        and node.module in {"hashlib", "hmac"}
        for node in ast.walk(ast.parse(source))
    ):
        raise SyntaxError(f"{path}: 一致性验收沿直接内容比较和原生身份执行。")
    if lint:
        filename = str(path) if str(path).endswith(".py") else str(path) + ".py"
        result = run_ruff(["--stdin-filename", filename, "-"], source)
        if result.returncode:
            raise SyntaxError(f"{path}:\n{result.stdout or result.stderr}")


def compile_embedded_python(source, path, *, imports=None):
    def check(body, start, end, inline):
        checked_python(body, path, imports=imports)

    visit_python_shell(source, path, check)


if args.self_test:
    for code in ("import hashlib", "from hashlib import sha256 as identity", "import hmac"):
        try:
            checked_python(code, Path("Scripts/validation_provenance.py"))
        except SyntaxError:
            pass
        else:
            raise AssertionError("一致性验收沿内容比较执行")
    for opening in [
        "<<PY",
        "<< 'PY'",
        '<<"PY"',
        "<<'PY'",
        "<<-PY",
        "<<'PY' >/dev/null",
        "<<'PY' | cat",
        "<<'PY' 2>&1",
        "<<'EOF'",
        '<<"END_SCRIPT"',
        "<<'PY-CODE'",
        r"<<\EOF",
        '<<"PY CODE"',
        "<<E'OF'",
    ]:
        label = command_argument(opening, re.match(r"<<-?\s*", opening).end())[0].decode("utf-8")
        prefix = "\t" if opening == "<<-PY" else ""
        compile_embedded_python(
            f"python3 - {opening}\n{prefix}pass\n{prefix}{label}\n", "heredoc-self-test"
        )
        try:
            compile_embedded_python(
                f"python3 - {opening}\n{prefix}if True\n{prefix}{label}\n", "heredoc-self-test"
            )
        except SyntaxError:
            pass
        else:
            raise AssertionError(f"Python heredoc 语法审计遗漏：{opening}")

    compile_embedded_python("cat <<'EOF'\nif True\nEOF\n", "shell-text-self-test")
    for command in (
        "echo python3",
        "python3 -c 'pass'",
        "python3 -Bcpass",
        "python3 script.py",
        "python3 -m package",
    ):
        compile_embedded_python(command + " <<'EOF'\nif True\nEOF\n", "python-stdin-data-self-test")
    for command in ("python3", "python3 -B -", '"/fixture/Python Tools/python3" -', "python3 -- -"):
        try:
            compile_embedded_python(
                command + " <<'EOF'\nif True\nEOF\n", "python-stdin-code-self-test"
            )
        except SyntaxError:
            pass
        else:
            raise AssertionError("Python 标准输入代码需要参与语法审计")
    for source in (
        "python3 /dev/fd/3 3<<'CODE'\n{code}\nCODE\n",
        "3<<'CODE' python3 /dev/fd/3\n{code}\nCODE\n",
        "python3 -B -- /dev/fd/4 argument 4<<-'TEXT'\n\t{code}\n\tTEXT\n",
        "python3 /proc/self/fd/4 4<<'TEXT'\n{code}\nTEXT\n",
        "python3 /dev/stdin <<'CODE'\n{code}\nCODE\n",
        "python3 /dev/fd/0 <<'CODE'\n{code}\nCODE\n",
        "python3 /dev/fd/3 <<'DATA' 3<<'CODE'\nif True\nDATA\n{code}\nCODE\n",
        "python3 /dev/fd/3 3<<'CODE' 4<<'DATA'\n{code}\nCODE\nif True\nDATA\n",
    ):
        compile_embedded_python(source.format(code="pass"), "descriptor-code-self-test")
        try:
            compile_embedded_python(source.format(code="if True"), "descriptor-code-self-test")
        except SyntaxError:
            pass
        else:
            raise AssertionError("Python 文件描述符正文需要按实际脚本路径参与语法审计")
    for command in (
        "python3 /dev/fd/3 4<<'CODE'",
        "python3 - 3<<'CODE'",
        "python3 -c 'pass' 3<<'CODE'",
        "python3 script.py 3<<'CODE'",
        "cat 3<<'CODE'",
        "python3 /dev/fd/3 argument3<<'CODE'",
    ):
        compile_embedded_python(command + "\nif True\nCODE\n", "descriptor-data-self-test")
    optimized = subprocess.run(
        [sys.executable, "-O", "-B", str(Path(__file__).resolve()), str(root)],
        capture_output=True,
        text=True,
    )
    if optimized.returncode == 0 or "Python 默认优化级别" not in optimized.stderr:
        raise AssertionError("独立 Python 语法审计需要核对断言执行环境")
    for command, bodies in [
        ("cat <<'TEXT' | python3 - <<'EOF'", "if True\nTEXT\n{python}\nEOF\n"),
        ("python3 - <<'EOF' | cat <<'TEXT'", "{python}\nEOF\nif True\nTEXT\n"),
        ("cat <<'TEXT'; python3 - <<-EOF", "plain text\nTEXT\n\t{python}\n\tEOF\n"),
        ("cat <<'TEXT' | \\\npython3 - <<'EOF'", "plain text\nTEXT\n{python}\nEOF\n"),
        ("python3 - <<'FIRST' | python3 - <<'SECOND'", "pass\nFIRST\n{python}\nSECOND\n"),
    ]:
        compile_embedded_python(
            command + "\n" + bodies.format(python="pass"), "multiple-heredoc-self-test"
        )
        try:
            compile_embedded_python(
                command + "\n" + bodies.format(python="if True"), "multiple-heredoc-self-test"
            )
        except SyntaxError:
            pass
        else:
            raise AssertionError("多重 heredoc 的各 Python 正文需要参与语法检查")
    for source in (
        "# python3 <<'PY'\n",
        "echo value # python3 <<'PY'\n",
        'echo "python3 <<PY"\n',
        "cat <<'EOF'\n# python3 <<'PY'\nEOF\n",
    ):
        compile_embedded_python(source, "shell-lexical-self-test")
    for source in (
        "python3 - \\\n <<'EOF'\nif True\nEOF\n",
        "value=\"$(python3 - <<'EOF'\nif True\nEOF\n)\"\n",
    ):
        try:
            compile_embedded_python(source, "shell-continuation-self-test")
        except SyntaxError:
            pass
        else:
            raise AssertionError("Python heredoc 语法审计需要覆盖续行及命令替换")

    for source in (
        "2>/dev/null python3 -c '{code}'",
        ">/dev/null python3 -c '{code}'",
        "python3 2>/dev/null -c '{code}'",
        "<<'EOF' python3 -\n{code}\nEOF\n",
        "2>/dev/null <<'EOF' python3 -\n{code}\nEOF\n",
        "value=`python3 -c '{code}'`",
        "value=\"`python3 -c '{code}'`\"",
        "value=`python3 -c {code}`",
    ):
        compile_embedded_python(source.format(code="pass"), "redirect-substitution-self-test")
        try:
            compile_embedded_python(
                source.format(code="if True"), "redirect-substitution-self-test"
            )
        except SyntaxError:
            pass
        else:
            raise AssertionError("前置重定向及反引号命令替换需要参与 Python 语法审计")
    for source in (
        "2>/dev/null echo python3 -c 'if True'",
        "<<'EOF' cat\nif True\nEOF\n",
        "echo '`python3 -c if True`'",
        'echo "\\`python3 -c if True\\`"',
    ):
        compile_embedded_python(source, "redirect-substitution-text-self-test")

    for prefix in (
        "python3 -c ",
        "python3 -Bc ",
        "python3 -OOuc ",
        "/usr/bin/python3 -B -c ",
        '"python3" -c ',
        "'python3' -c ",
        "$'python3' -c ",
        '"/fixture/Python Tools/python3" -c ',
        'value="$(python3 -c ',
        "cat | python3 -c ",
        "if python3 -c ",
        "while python3 -c ",
        "until python3 -c ",
        "{ python3 -c ",
        "time -p python3 -c ",
        "BIT101_FLAG=1 python3 -c ",
        'BIT101_FLAG="two words" python3 -c ',
        "env BIT101_FLAG=1 python3 -c ",
        "command env -i BIT101_FLAG=1 python3 -B -c ",
        'exec /usr/bin/env -u "BIT101_FLAG" python3 -X dev -c ',
    ):
        suffix = ')"' if prefix.startswith("value=") else ""
        for quote in ("'", '"', "$'"):
            closing = quote[-1]
            compile_embedded_python(
                prefix + quote + "pass" + closing + suffix, "inline-python-self-test"
            )
            try:
                compile_embedded_python(
                    prefix + quote + "if True" + closing + suffix, "inline-python-self-test"
                )
            except SyntaxError:
                pass
            else:
                raise AssertionError("Python -c 字面量需要参与语法审计")
    compile_embedded_python('python3 -c "print(\\"literal\\")"', "inline-escape-self-test")
    for argument, expected in ((r"$'\q'", b"q"), (r"$'\c?\cA'", b"c?cA"), (r"$'a\0b'", b"a")):
        assert command_argument(argument, 0)[0] == expected
    for argument in (
        "'for ''item in []: pass'",
        "'for 'item' in []: pass'",
        "p'ass'",
        "$'for item in []:\\n    pass'",
        "$'print(\\'literal\\')'",
        "$'\\x70\\141\\u0073\\U00000073'",
        "'pa'$'ss'",
        "'pass' 'if True'",
        "pass",
        "\\\n    'pass'",
        "p\\ass",
    ):
        compile_embedded_python("python3 -Bc " + argument, "inline-argument-self-test")
    for argument in (
        "'if ''True'",
        "$'if True\\n    pass'",
        "if' True'",
        "$'\\x69f True'",
        "if\\ True",
        "\\\n  'if True'",
    ):
        try:
            compile_embedded_python("python3 -c " + argument, "inline-argument-self-test")
        except SyntaxError:
            pass
        else:
            raise AssertionError("Python -c 完整字面参数需要参与语法审计")
    for source in (
        "echo python3 -c 'if True'",
        "# python3 -c 'if True'",
        "echo \"python3 -c 'if True'\"",
        'python3 -c "$script"',
        "cat <<'EOF'\npython3 -c 'if True'\nEOF\n",
        "env BIT101_FLAG=1 echo python3 -c 'if True'",
        "python3 script.py -c 'if True'",
        "printf '%s' $'\\xff'",
    ):
        compile_embedded_python(source, "inline-shell-text-self-test")

    checked_python("from datetime import timezone\nprint(timezone.utc)", "defined-name-self-test")
    for source in (
        'python3 -c "print(timezone.utc)"',
        "python3 - <<'PY'\nprint(timezone.utc)\nPY\n",
    ):
        try:
            compile_embedded_python(source, "undefined-name-self-test")
        except SyntaxError as error:
            assert "F821" in str(error)
        else:
            raise AssertionError("嵌入 Python 的未定义名称需要参与审计")
    try:
        checked_python("def normalize(): return timezone.utc", "undefined-name-self-test")
    except SyntaxError as error:
        assert "F821" in str(error)
    else:
        raise AssertionError("独立 Python 的未定义名称需要参与审计")

    for source in (
        "from code_quality_rules import *",
        "from code_quality_rules import *\nundefined_detector_name()",
    ):
        try:
            checked_python(source, "explicit-import-self-test")
        except SyntaxError as error:
            assert "F403" in str(error)
            if "undefined_detector_name" in source:
                assert "F405" in str(error)
        else:
            raise AssertionError("Python 名称审计需要显式导入及确定的名称来源")


def missing_imports(sources, *, only=None):
    declared = (root / "Scripts/style-requirements.txt").read_text().splitlines()
    external = sys.stdlib_module_names | {"openpyxl"} | {
        requirement.split("==", 1)[0].replace("-", "_")
        for requirement in declared if requirement.strip() and not requirement.startswith("#")
    }
    errors = []
    for name, source in sources.items():
        if only is not None and name != only:
            continue
        directory = name.rpartition(".")[0]
        resolved = python_execution_modules(sources, directory)
        namespaces = {
            ".".join(module.split(".")[:length])
            for module in resolved
            for length in range(1, len(module.split(".")) + 1)
        }
        package = name if any(other.startswith(name + ".") for other in sources) else directory
        for node in ast.walk(ast.parse(source)):
            modules = []
            if isinstance(node, ast.Import):
                modules = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                base = (
                    ".".join(package.split(".")[: len(package.split(".")) - node.level + 1])
                    if node.level
                    else ""
                )
                module = ".".join(filter(None, (base, node.module)))
                if module:
                    modules = [module]
            for module in modules:
                if module.split(".")[0] not in external and module not in namespaces:
                    errors.append(
                        f"{name}:{node.lineno}: Python 模块需要存在于脚本库存或声明的依赖中：{module}"
                    )
    return errors


sources = {
    ".".join(
        path.with_suffix("").parts[:-1] if path.stem == "__init__" else path.with_suffix("").parts
    ): source
    for name, source in script_sources.items()
    if name.startswith("Scripts/") and name.endswith(".py")
    for path in [PurePosixPath(name).relative_to("Scripts")]
}

python_paths = []
for name, source in script_sources.items():
    if syntax_targets is not None and name not in syntax_targets:
        continue
    if name.endswith(".py"):
        checked_python(source, root / name, lint=args.staged)
        if not args.staged:
            python_paths.append(str(root / name))
    else:
        compile_embedded_python(source, root / name, imports=sources)
if python_paths:
    result = run_ruff(["--", *python_paths])
    if result.returncode:
        raise SyntaxError(result.stdout or result.stderr)


def import_cycles(sources, directory=""):
    resolved = python_execution_modules({name: name for name in sources}, directory)
    dependencies = python_import_dependencies(
        {name: sources[canonical] for name, canonical in resolved.items()}
    )
    graph = {name: set() for name in resolved.values()}
    for name, imports in dependencies.items():
        graph[resolved[name]].update(resolved[dependency] for dependency in imports)
    active, completed, cycles = [], set(), set()

    def visit(name):
        if name in active:
            cycle = active[active.index(name) :]
            rotations = [tuple(cycle[index:] + cycle[:index]) for index in range(len(cycle))]
            cycles.add(min(rotations))
        elif name not in completed:
            active.append(name)
            for dependency in sorted(graph[name]):
                visit(dependency)
            active.pop()
            completed.add(name)

    for name in sorted(graph):
        visit(name)
    return sorted(cycles)


if args.self_test:
    assert missing_imports({"entry": "from missing_helper import value"})
    assert missing_imports({"pkg.entry": "import pkg.missing", "pkg.other": "pass"})
    assert not missing_imports(
        {
            "entry": "import json; from openpyxl import load_workbook; from helper import value",
            "helper": "value = 1",
        }
    )
    assert not missing_imports(
        {"pkg.entry": "from .helper import value; import helper", "pkg.helper": "value = 1"}
    )
    assert import_cycles(
        {"a": "from b import value", "b": "import c", "c": "from a import value"}
    ) == [("a", "b", "c")]
    assert import_cycles({"a": "def deferred():\n    import b", "b": "from a import value"}) == [
        ("a", "b")
    ]
    assert import_cycles({"a": "from b import value", "b": "import json"}) == []
    assert import_cycles({"a": "import a"}) == [("a",)]
    assert import_cycles({"nested.a": "from .b import value", "nested.b": "import nested.a"}) == [
        ("nested.a", "nested.b")
    ]
    assert import_cycles({"nested.a": "from nested import b", "nested.b": "import a"}) == []
    assert import_cycles({"nested.a": "from nested import b", "nested.b": "from . import a"}) == [
        ("nested.a", "nested.b")
    ]
    assert import_cycles({"nested": "from . import a", "nested.a": "import nested"}) == [
        ("nested", "nested.a")
    ]
    assert import_cycles({"pkg.a": "import json", "pkg.json": "import pkg.a"}) == []
    assert import_cycles({"a": "import pkg.b", "pkg.b": "import a", "pkg.a": "pass"}) == [
        ("a", "pkg.b")
    ]
    assert import_cycles({"pkg.a": "from json import loads", "pkg.json": "import pkg.a"}) == []
    assert import_cycles(
        {"a": "from pkg import b", "pkg.b": "from a import value", "pkg.a": "pass"}
    ) == [("a", "pkg.b")]
    assert import_cycles({"pkg.entry": "import helper", "pkg.helper": "import entry"}, "pkg") == [
        ("pkg.entry", "pkg.helper")
    ]
    assert import_cycles(
        {"helper": "pass", "pkg.entry": "import helper", "pkg.helper": "import entry"}, "pkg"
    ) == [("pkg.entry", "pkg.helper")]
    assert import_cycles({"pkg.entry": "import helper", "pkg.helper": "import json"}, "pkg") == []

if missing := missing_imports(sources):
    raise ValueError("\n".join(missing))
cycles = sorted(
    {
        cycle
        for directory in {"", *(name.rpartition(".")[0] for name in sources)}
        for cycle in import_cycles(sources, directory)
    }
)
if cycles:
    raise ValueError(
        "维护脚本依赖需要单向组织：" + "；".join(" → ".join((*cycle, cycle[0])) for cycle in cycles)
    )
