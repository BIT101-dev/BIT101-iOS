#!/usr/bin/env python3
"""Validate repository Markdown links using the current document contents."""
from __future__ import annotations
import argparse
import fcntl
import re
import subprocess
import posixpath
import unicodedata
from urllib.parse import unquote, urlsplit
import runpy
import shutil
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
file_checks = runpy.run_path(str(ROOT / "Scripts/check-file-lengths.py"))


def markdown_prose(source: str) -> str:
    lines, fence = [], None
    for line in re.sub(r"<!--.*?-->", "", source, flags=re.DOTALL).splitlines():
        match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if match:
            marker = match[1]
            if fence is None: fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence): fence = None
            lines.append("")
        else: lines.append(line if fence is None else "")
    return "\n".join(lines)


def markdown_link_prose(source: str) -> str:
    return re.sub(r'(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)', lambda match: ' ' * len(match[0]),
        markdown_prose(source), flags=re.DOTALL)


def heading_anchors(source: str) -> set[str]:
    anchors, counts = set(), {}
    lines = markdown_prose(source).splitlines()
    for index, line in enumerate(lines):
        atx = re.match(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+\s*)?$", line)
        setext = index + 1 < len(lines) and re.fullmatch(r" {0,3}(?:=+|-+)\s*", lines[index + 1])
        if not atx and not (setext and line.strip()): continue
        label = atx[1] if atx else line.strip()
        label = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", label)
        label = re.sub(r"<[^>]+>|[`*~]", "", label).lower()
        slug = ''.join(char for char in label if unicodedata.category(char)[0] in {'L', 'N', 'M'} or char in ' _-').replace(' ', '-')
        duplicate = counts.get(slug, 0)
        counts[slug] = duplicate + 1
        anchors.add(slug + (f'-{duplicate}' if duplicate else ''))
    anchors.update(re.findall(r'<(?:a|[^>]+)\s[^>]*(?:id|name)=["\']([^"\']+)', markdown_link_prose(source)))
    return anchors


def link_targets(source: str) -> tuple[list[str], list[str]]:
    source = markdown_link_prose(source)
    definitions = {}
    def reference(value): return ' '.join(value.split()).casefold()
    def destination(value):
        value = value.lstrip()
        if value.startswith('<'): return value[1:value.index('>')] if '>' in value else value
        return re.split(r'\s+["\']', value, maxsplit=1)[0].strip()
    definition_pattern = r'^ {0,3}\[([^]\n]+)\]:\s*(.+)$'
    for match in re.finditer(definition_pattern, source, re.MULTILINE):
        definitions.setdefault(reference(match[1]), destination(match[2]))
    source = re.sub(definition_pattern, '', source, flags=re.MULTILINE)
    targets, errors = [], []
    cursor = 0
    while cursor < len(source):
        start = source.find('[', cursor)
        if start < 0: break
        if start > 0 and source[start - 1] == '\\': cursor = start + 1; continue
        depth, end = 1, start + 1
        while end < len(source) and depth:
            if source[end] == '\\': end += 2; continue
            if source[end] == '[': depth += 1
            elif source[end] == ']': depth -= 1
            end += 1
        if depth: break
        label = source[start + 1:end - 1]
        cursor = end
        if source[end:end + 1] == '(':
            depth, close = 1, end + 1
            while close < len(source) and depth:
                if source[close] == '\\': close += 2; continue
                if source[close] == '(': depth += 1
                elif source[close] == ')': depth -= 1
                close += 1
            if depth: continue
            targets.append(destination(source[end + 1:close - 1]))
            cursor = close
        elif source[end:end + 1] == '[':
            close = source.find(']', end + 1)
            if close < 0: continue
            key = reference(source[end + 1:close] or label)
            if key in definitions: targets.append(definitions[key])
            else: errors.append(f'引用式链接需要定义：{key}')
            cursor = close + 1
        elif reference(label) in definitions: targets.append(definitions[reference(label)])
    return targets, errors


def document_findings(name: str, documents: dict[str, str], filenames: set[str]) -> list[str]:
    targets, errors = link_targets(documents[name])
    directories = {str(parent) for filename in filenames for parent in PurePosixPath(filename).parents}
    for target in targets:
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc: continue
        destination = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(parsed.path))) if parsed.path else name
        if destination not in filenames | directories:
            errors.append(f'文档链接需要有效文件或目录：{target}')
            continue
        document = posixpath.normpath(posixpath.join(destination, 'README.md')) if destination in directories else destination
        if parsed.fragment and document in documents and unquote(parsed.fragment) not in heading_anchors(documents[document]):
            errors.append(f'文档链接需要有效标题锚点：{target}')
    return [f'{name}: {error}' for error in errors]


def findings(staged: bool = False, root: Path = ROOT) -> list[str]:
    contents = file_checks["index_files"](root, include=lambda name: name.endswith('.md')) if staged else None
    if contents is None:
        names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root, text=True).split("\0")
        contents = {name: (root / name).read_bytes() if name.endswith('.md') else b''
            for name in names if name and (root / name).is_file()}
    documents = {name: data.decode() for name, data in contents.items() if name.endswith('.md') and 'Fixtures' not in Path(name).parts}
    return [error for name in sorted(documents) for error in document_findings(name, documents, set(contents))]


def link_self_test() -> None:
    documents = {'README.md': '# Guide\n## Usage\n## Usage\n## 中文标题\n[use](#usage) [dup](#usage-1) [中文](#中文标题)\n[ref][details] [details][] [details]\n[details]: <docs/Help.md#setup> "title"\n`[ignored](missing)`\n```swift\n[ignored](missing)\n```',
        'docs/Help.md': 'Setup\n=====\n[back](../README.md#guide)\n'}
    assert document_findings('README.md', documents, set(documents)) == []
    assert document_findings('docs/Help.md', documents, set(documents)) == []
    for source in ('[module](Modules/)', '[docs](docs/)', '[root](./#guide)'):
        changed = dict(documents, **{'README.md': '# Guide\n' + source})
        assert not document_findings('README.md', changed, set(documents) | {'Modules/Example/Sources/View.swift'})
    for source in ('[bad](Missing/)', '[bad](../Modules/)', '[bad](./#missing)'):
        changed = dict(documents, **{'README.md': source})
        assert document_findings('README.md', changed, set(documents) | {'Modules/Example/Sources/View.swift'})
    for source in ('[bad](#missing)', '[bad](docs/Help.md#missing)', '[bad][missing]', '[bad](missing.md)', '[bad][details]\n[details]: docs/Help.md#missing'):
        assert document_findings('README.md', dict(documents, **{'README.md': source}), set(documents))
    assert link_targets('[nested [label]](file(with).md)')[0] == ['file(with).md']
    for length in range(1, 5):
        prefix = '正文 ' + '`' * length + ' [broken](Missing.md) '
        assert link_targets(prefix + '`' * (length + 1))[0] == ['Missing.md']
        assert document_findings('README.md', dict(documents, **{'README.md': prefix + '`' * (length + 1)}), set(documents))
        assert link_targets(prefix + '`' * length) == ([], [])
    for label in ('route', 'ROUTE', ' route '):
        source = f'[link][route]\n\n[route]: Missing.md\n[{label}]: README.md'
        assert link_targets(source) == (['Missing.md'], [])
        assert document_findings('README.md', dict(documents, **{'README.md': source}), set(documents))
        source = source.replace('Missing.md', 'docs/Help.md', 1).replace(']: README.md', ']: Missing.md')
        assert link_targets(source) == (['docs/Help.md'], [])
        assert not document_findings('README.md', dict(documents, **{'README.md': source}), set(documents))

    for wrapper in ('```html\n%s\n```', '~~~html\n%s\n~~~', '`%s`', '<!--%s-->'):
        source = '[anchor](#gone)\n' + wrapper % '<a id="gone"></a>'
        assert document_findings('README.md', {'README.md': source}, {'README.md'})
    source = '[anchor](#gone)\n<a id="gone"></a>'
    assert not document_findings('README.md', {'README.md': source}, {'README.md'})
    assert 'guide-code' in heading_anchors('# Guide `code`')


def staged_self_test() -> None:
    lock_path = ROOT / ".build/static-audit/staged-content-self-test.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        staged_content_fixture()


def staged_content_fixture() -> None:
    fixture = ROOT / ".build/static-audit/staged-content-self-test"
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True)
    try:
        subprocess.run(["git", "init", "-q", str(fixture)], check=True, capture_output=True)
        (fixture / "source.swift").write_text("line\n" * 1001)
        (fixture / "README.md").write_text("[link](missing.swift)\n")
        (fixture / "image.png").write_bytes(b'\x89PNG\x00' * 1000)
        subprocess.run(["git", "add", "."], cwd=fixture, check=True, capture_output=True)
        (fixture / "source.swift").write_text("line\n")
        (fixture / "README.md").write_text("[link](source.swift)\n")
        contents = file_checks["index_files"](fixture)
        assert contents['image.png'] == b''
        documents = file_checks["index_files"](fixture, include=lambda name: name.endswith('.md'))
        assert documents['source.swift'] == documents['image.png'] == b'' and documents['README.md']
        assert file_checks["length_findings"]({name: data.decode() for name, data in contents.items()})
        assert findings(staged=True, root=fixture) and findings(root=fixture) == []
        subprocess.run(["git", "add", "."], cwd=fixture, check=True, capture_output=True)
        (fixture / "source.swift").unlink()
        (fixture / "README.md").write_text("[link](missing.swift)\n")
        assert findings(staged=True, root=fixture) == [] and findings(root=fixture)
        subprocess.run(["git", "rm", "--cached", "-q", "source.swift"], cwd=fixture, check=True, capture_output=True)
        assert findings(staged=True, root=fixture)
        scripts = fixture / 'Scripts'
        scripts.mkdir()
        checker = ROOT / 'Scripts/check-python-syntax.py'
        for name, invalid, valid in [('fixture.py', 'if True\n', 'pass\n'),
                ('fixture.sh', "python3 -c 'if True'\n", "python3 -c 'pass'\n")]:
            source = scripts / name
            def validate(staged):
                return subprocess.run([sys.executable, str(checker), str(fixture), *(['--staged'] if staged else [])],
                    capture_output=True, text=True).returncode
            source.write_text(invalid)
            subprocess.run(['git', 'add', str(source)], cwd=fixture, check=True, capture_output=True)
            source.write_text(valid)
            assert validate(True) != 0 and validate(False) == 0
            subprocess.run(['git', 'add', str(source)], cwd=fixture, check=True, capture_output=True)
            source.write_text(invalid)
            assert validate(True) == 0 and validate(False) != 0
            source.unlink()
            assert validate(True) == 0
    finally:
        shutil.rmtree(fixture)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="validate links against the complete Git index")
    parser.add_argument("--self-test", action="store_true", help="run link and staged-content regression cases")
    args = parser.parse_args()
    if args.self_test:
        staged_self_test()
        link_self_test()
    errors = findings(staged=args.staged)
    if errors:
        print("\n".join(errors))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
