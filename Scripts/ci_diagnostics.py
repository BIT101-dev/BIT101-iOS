#!/usr/bin/env python3
"""Select complete diagnostics or a bounded text excerpt for cancelled CI jobs."""
import os
from pathlib import Path
import re
from command_output import FailureSummary

ROOT = Path(__file__).resolve().parents[1]
REPORT = '.build/extended-automation/ci-diagnostics.txt'
BYTE_LIMIT = 1024 * 1024


def diagnostic_path_list(steps: list, upload: dict) -> str:
    reference = re.fullmatch(r'\$\{\{ steps\.([\w-]+)\.outputs\.paths \}\}', upload.get('with', {}).get('path', ''))
    if reference is None: return ''
    producers = [step for step in steps if step.get('id') == reference[1]]
    if len(producers) != 1: return ''
    producer = producers[0]
    if producer.get('run') != 'python3 Scripts/ci_diagnostics.py' \
            or producer.get('if') != upload.get('if') or steps.index(producer) >= steps.index(upload) \
            or producer.get('env', {}).get('BIT101_CI_CANCELLED') != "${{ job.status == 'cancelled' }}" \
            or producer.get('continue-on-error', False) is not False:
        return ''
    return producer.get('env', {}).get('BIT101_DIAGNOSTIC_PATHS', '')


def cancellation_excerpt(paths: str, *, root: Path = ROOT) -> str:
    parts = ['CI 任务已取消，以下保留已有文本诊断。\n']
    remaining = BYTE_LIMIT - len(parts[0].encode())
    for pattern in paths.splitlines():
        if not pattern.strip(): continue
        if Path(pattern).is_absolute() or '..' in Path(pattern).parts: raise ValueError('诊断路径需要位于仓库内。')
        for path in sorted(root.glob(pattern)):
            if path == root / REPORT or not path.is_file() or path.suffix not in {'.log', '.txt', '.json', '.jsonl'} \
                    or not path.resolve().is_relative_to(root.resolve()): continue
            summary = FailureSummary()
            with path.open('rb') as stream:
                stream.seek(max(0, path.stat().st_size - BYTE_LIMIT))
                for line in stream.read(BYTE_LIMIT).decode(errors='replace').splitlines(keepends=True): summary.add(line)
            excerpt = '\n' + path.relative_to(root).as_posix() + '\n' + ''.join(summary.lines())
            payload = excerpt.encode()[:remaining]
            parts.append(payload.decode(errors='ignore'))
            remaining -= len(payload)
            if remaining <= 0: return ''.join(parts)
    return ''.join(parts)


def main() -> None:
    paths = os.environ['BIT101_DIAGNOSTIC_PATHS']
    report = ROOT / REPORT
    if os.environ['BIT101_CI_CANCELLED'] == 'true':
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(cancellation_excerpt(paths, root=ROOT))
        paths = REPORT
    else: report.unlink(missing_ok=True)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        output.write('paths<<BIT101_DIAGNOSTIC_PATHS\n' + paths.rstrip() + '\nBIT101_DIAGNOSTIC_PATHS\n')


if __name__ == '__main__': main()
