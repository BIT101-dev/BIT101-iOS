"""Decode manual media evidence with the Apple platform format implementations."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
from validation_environment import environment_context
from validation_policy import MAXIMUM_ATTACHMENT_BYTES, MAXIMUM_DECODED_MEDIA_BYTES, MAXIMUM_VIDEO_SECONDS, MAXIMUM_VIDEO_FRAMES, MAXIMUM_PDF_PAGES, MEDIA_PROBE_TIMEOUT_SECONDS

ROOT = Path(__file__).resolve().parents[1]
RESULTS: dict[str, bool] = {}


def run_probe(data: bytes, *, self_test: bool = False) -> bool:
    cache = ROOT / '.build/static-audit'
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'evidence-media-probe.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = ROOT / 'Scripts/ManualEvidenceProbe.swift'
        context = environment_context('audit')
        compiler = Path(context['compiler']['path']).with_name('swiftc')
        module_cache = ROOT / '.build/compiler-cache/ModuleCache.noindex'
        module_cache.mkdir(parents=True, exist_ok=True)
        signature = hashlib.sha256(source.read_bytes() + json.dumps(context, sort_keys=True).encode()).hexdigest()
        inputs = cache / 'evidence-media-probe-inputs.json'
        executable = cache / 'evidence-media-probe'
        if not executable.exists() or not inputs.exists() or inputs.read_text() != signature:
            with (module_cache.parent / 'cache.lock').open('a') as compilation_lock:
                fcntl.flock(compilation_lock, fcntl.LOCK_EX)
                result = subprocess.run([str(compiler), '-parse-as-library', '-warnings-as-errors',
                    '-target', f'{os.uname().machine}-apple-macosx14.0', '-sdk', context['sdks']['MacOSX']['path'],
                    '-module-cache-path', str(module_cache), str(source), '-o', str(executable)],
                    capture_output=True, text=True, env=dict(os.environ, CLANG_MODULE_CACHE_PATH=str(module_cache)))
            if result.returncode:
                executable.unlink(missing_ok=True)
                raise RuntimeError(result.stderr.strip() or '人工附件解码工具编译失败')
            inputs.write_text(signature)
        arguments = [str(value) for value in (MAXIMUM_ATTACHMENT_BYTES, MAXIMUM_DECODED_MEDIA_BYTES,
            MAXIMUM_VIDEO_SECONDS, MAXIMUM_VIDEO_FRAMES, MAXIMUM_PDF_PAGES)]
        return decode_probe(executable, arguments, data, self_test=self_test)


def decode_probe(executable: Path, arguments: list[str], data: bytes, *, self_test: bool = False) -> bool:
    try:
        result = subprocess.run([str(executable), *arguments] + (['--self-test'] if self_test else []),
            input=data, capture_output=True, timeout=MEDIA_PROBE_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired: return False
    finally: executable.with_name('evidence-media.mp4').unlink(missing_ok=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace').strip() or '人工附件解码工具执行失败')
    return json.loads(result.stdout) is True


def media_complete(data: bytes) -> bool:
    if not data or len(data) > MAXIMUM_ATTACHMENT_BYTES: return False
    digest = hashlib.sha256(data).hexdigest()
    if digest not in RESULTS:
        RESULTS[digest] = run_probe(data)
    return RESULTS[digest]
