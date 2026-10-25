"""Exercise bounded development artifacts through their public Python APIs."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from contextlib import closing, nullcontext, redirect_stdout, redirect_stderr
from io import StringIO
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


def development_workflow_self_test() -> None:
    fixture = ROOT / '.build/static-audit/development-workflow-self-test'
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True)
    try:
        cache_and_ui_products(fixture)
        incremental_archives(fixture)
        focused_result_retention(fixture)
        full_result_batches(fixture)
        shared_source_facts(fixture)
        audit_self_test_selection()
        result_readers(fixture)
        archive_prune_then_fetch(fixture)
        cache_cleanup_after_failure()
        audit_failure_summary(fixture)
        changed_staged_scripts(fixture)
        immediate_audit_output(fixture)
        ci_diagnostic_selection(fixture)
        readiness_diagnostics(fixture)
        mac_process_identity(fixture)
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


def shared_source_facts(fixture: Path) -> None:
    import fcntl
    import sqlite3
    from copy import deepcopy
    import swift_source_index as subject
    cache = fixture / 'source-facts.sqlite'
    path = ROOT / 'Modules/CommunityCore/Sources/CommunityTextLimits.swift'
    source = path.read_text()
    with patch.dict(os.environ, BIT101_SOURCE_FACTS_CACHE=str(cache)), \
            patch.object(subject, '_run_swift_syntax_index', wraps=subject._run_swift_syntax_index) as parse:
        first = subject.swift_syntax_index_sources({str(path): source})[str(path)]
        expected = deepcopy(first)
        original_scope = list(first['invocations'][0]['scope'])
        first['calls'][0]['scope'].append('ChangedCall')
        assert first['invocations'][0]['scope'] == original_scope
        first['declarations'].append(first['declarations'][0])
        assert subject.swift_syntax_index_sources({str(path): source})[str(path)] == expected
        first = expected
        with closing(sqlite3.connect(cache)) as database:
            stored = database.execute('SELECT content FROM facts WHERE path = ?', (str(path),)).fetchone()[0]
        assert all(type(position) is int for position in json.loads(stored)['calls']) and '$source' in stored
        with closing(sqlite3.connect(cache)) as database, database:
            database.execute('INSERT INTO facts VALUES (?, ?)', ('unrequested.swift', 'invalid JSON'))
        relative = str(path.relative_to(ROOT))
        assert subject.swift_syntax_index_sources({relative: source})[relative] == first and parse.call_count == 1
        with patch.dict(os.environ), patch.object(subject, 'DEFAULT_FACTS_CACHE', cache):
            os.environ.pop('BIT101_SOURCE_FACTS_CACHE', None)
            assert subject.swift_syntax_index_sources({relative: source})[relative] == first and parse.call_count == 1
        aliases = subject.swift_syntax_index_sources({str(path): source, relative: source})
        assert aliases[str(path)] == aliases[relative] == first
        aliases[str(path)]['calls'][0]['scope'].append('ChangedAlias')
        assert aliases[relative] == first
        with closing(sqlite3.connect(cache)) as database:
            assert database.execute("SELECT path FROM facts WHERE path = 'unrequested.swift'").fetchone() is None
        assert subject.swift_syntax_index_sources({relative: source + '\n'})[relative]['source'] == source + '\n'
        assert parse.call_count == 2
        assert subject.swift_syntax_index_sources({relative: source})[relative] == first and parse.call_count == 2
        program = f'''import fcntl,sys
sys.path.insert(0, {str(ROOT / 'Scripts')!r})
import swift_source_index as source
original = fcntl.flock
def observe(lock, operation):
    print('locking', flush=True)
    return original(lock, operation)
fcntl.flock = observe
def unexpected_parse(*args, **kwargs): raise AssertionError('shared facts')
source._run_swift_syntax_index = unexpected_parse
assert source.swift_syntax_index([source.Path({str(path)!r})])
print('done', flush=True)
'''
        with cache.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with closing(sqlite3.connect(cache)) as database, database:
                database.execute('UPDATE facts SET content = ? WHERE path = ?', ('{', str(path)))
            reader = subprocess.Popen([os.sys.executable, '-B', '-c', program], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert reader.stdout.readline().strip() == 'locking'
                with closing(sqlite3.connect(cache)) as database, database:
                    database.execute('UPDATE facts SET content = ? WHERE path = ?', (stored, str(path)))
                fcntl.flock(lock, fcntl.LOCK_UN)
                output, error = reader.communicate(timeout=5)
                assert reader.returncode == 0 and output.strip() == 'done', error
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                if reader.poll() is None: reader.kill()
                reader.communicate(timeout=5)
        base = ROOT / 'BIT101-iOSUITests/UIAutomationTestCase.swift'
        derived = ROOT / 'BIT101-iOSUITests/CommunityPublishingUITests.swift'
        derived_source = {str(derived): derived.read_text()}
        assert not subject.swift_syntax_index_sources(derived_source)[str(derived)]['tests']

        calls = parse.call_count
        with patch.object(subject, 'source_facts_signature', return_value='changed indexer'):
            assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
            assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
            assert parse.call_count == calls + 1
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        assert parse.call_count == calls + 2
        read_bytes = Path.read_bytes
        changed = source + '\n'
        with patch.object(Path, 'read_bytes', lambda file: changed.encode() if file == path else read_bytes(file)):
            assert subject.swift_syntax_index_sources({relative: changed})[relative]['source'] == changed
            assert subject.swift_syntax_index_sources({relative: changed})[relative]['source'] == changed
            assert parse.call_count == calls + 3
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        assert parse.call_count == calls + 4
        joined = subject.swift_syntax_index_sources(derived_source | {str(base): base.read_text()})
        assert joined[str(derived)]['tests']
        assert not subject.swift_syntax_index_sources(derived_source)[str(derived)]['tests']

        transformed = source + '\n'
        calls = parse.call_count
        for _ in range(2):
            assert subject.swift_syntax_index_sources({relative: transformed}, cache_transformed_sources=True)[relative]['source'] == transformed
        assert parse.call_count == calls + 1
        assert subject.swift_syntax_index_sources({relative: source}, cache_transformed_sources=True)[relative] == expected
        assert parse.call_count == calls + 2
        cache.write_bytes(b'invalid SQLite cache')
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        with closing(sqlite3.connect(cache)) as database, database:
            database.execute('UPDATE facts SET content = ? WHERE path = ?', ('{', str(path)))
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        retained = cache.read_bytes()
        failure = sqlite3.OperationalError('read-only cache')
        failure.sqlite_errorcode = sqlite3.SQLITE_READONLY
        with patch.object(sqlite3, 'connect', side_effect=failure):
            try: subject.swift_syntax_index_sources({relative: source})
            except sqlite3.OperationalError: pass
            else: raise AssertionError('缓存存储权限故障需要保留诊断。')
        assert cache.read_bytes() == retained


    source = '''struct Access {
        subscript(index: Int) -> Int { index }
        func `subscript`(_ index: Int) -> Int { index }
        func read() { _ = self[0]; _ = self.`subscript`(1); print("中文") }
    }'''
    facts = subject.swift_syntax_index_sources({'call-kind-fixture.swift': source})['call-kind-fixture.swift']
    assert len([call for call in facts['calls'] if call['value'] == 'self.subscript']) == 1
    assert len([call for call in facts['invocations'] if call['calledExpression'] == 'self.subscript']) == 2
    assert facts['source'] == source and any(row['value'] == '中文' for row in facts['stringSegments'])


def audit_self_test_selection() -> None:
    from script_test_support import shell_function
    function = shell_function(ROOT / 'Scripts/script-support.sh', 'bit101_checker_audit')
    for enabled in ('0', '1'):
        script = f'ROOT_DIR=/fixture BIT101_AUDIT_SELF_TESTS={enabled}\npython3() {{ print -r -- "$*"; }}\n'
        result = subprocess.run(['zsh', '-c', script + function + '\nbit101_checker_audit'], capture_output=True, text=True, check=True)
        assert 'check-code-quality.py --combined' in result.stdout
        assert ('validation_evidence.py self-test' in result.stdout) == (enabled == '1')
        assert ('--combined --self-test' in result.stdout) == (enabled == '1')
    source = (ROOT / 'Scripts/run-static-audit.sh').read_text()
    parser = source[source.index('set -euo pipefail'):source.index('\nROOT_DIR=')]
    for arguments, expected in [([], '1:9:9:0'), (['docs', 'python-parse', 'docs'], '0:2:2:0'),
            (['artifact-hygiene'], '0:0:0:0'), (['--self-test', 'docs'], '0:1:1:1')]:
        result = subprocess.run(['zsh', '-c', parser + '\nprint -r -- "$full_audit:${#group_names}:${#group_commands}:$self_tests_requested"',
            'audit-selection', *arguments], env=dict(os.environ, GITHUB_ACTIONS='false', BIT101_RELEASE_CHECK='false'),
            capture_output=True, text=True, check=True)
        assert result.stdout.strip() == expected, result.stdout
    for arguments, environment in [(['unknown-group'], {}), (['prepare', 'docs'], {}),
            (['docs'], {'GITHUB_ACTIONS': 'true'}), (['docs'], {'BIT101_RELEASE_CHECK': 'true'})]:
        result = subprocess.run(['zsh', str(ROOT / 'Scripts/run-static-audit.sh'), *arguments],
            env=dict(os.environ, **environment), capture_output=True, text=True)
        assert result.returncode == 64, (arguments, result.stdout, result.stderr)


def ci_diagnostic_selection(fixture: Path) -> None:
    import ci_diagnostics as subject
    log = fixture / 'compiler.log'
    log.write_text('[1/2] error: fixture compiler failure\n' + 'progress\n' * 200)
    private = fixture / 'private.txt'
    private.write_text('fixture private attachment')
    bundle = fixture / 'test-results.xcresult'
    bundle.mkdir()
    (bundle / 'data.txt').write_text('fixture binary bundle')
    excerpt = subject.cancellation_excerpt('compiler.log\ntest-results.xcresult', root=fixture)
    assert 'fixture compiler failure' in excerpt
    assert 'fixture private attachment' not in excerpt and 'fixture binary bundle' not in excerpt
    log.write_text('error: ' + 'x' * (subject.BYTE_LIMIT * 2))
    assert len(subject.cancellation_excerpt('compiler.log', root=fixture).encode()) <= subject.BYTE_LIMIT
    for cancelled, expected in [('true', subject.REPORT), ('false', 'compiler.log\ntest-results.xcresult')]:
        output = fixture / 'workflow-output'
        output.write_text('')
        with patch.object(subject, 'ROOT', fixture), patch.dict(os.environ,
                BIT101_DIAGNOSTIC_PATHS='compiler.log\ntest-results.xcresult', BIT101_CI_CANCELLED=cancelled,
                GITHUB_OUTPUT=str(output)):
            subject.main()
        assert output.read_text() == 'paths<<BIT101_DIAGNOSTIC_PATHS\n' + expected + '\nBIT101_DIAGNOSTIC_PATHS\n'
        assert (fixture / subject.REPORT).exists() == (cancelled == 'true')


def mac_process_identity(fixture: Path) -> None:
    import sys
    app = fixture / 'Mac App [fixture].app'
    executable = app / 'Contents/MacOS/BIT101-iOS'
    executable.parent.mkdir(parents=True)
    shutil.copyfile('/bin/sleep', executable)
    executable.chmod(0o755)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(executable)],
        capture_output=True, check=True)
    owned = subprocess.Popen([str(executable), '60'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    decoy = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)', str(executable)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        result = subprocess.run([sys.executable, str(ROOT / 'Scripts/validation_restore.py'), 'mac-pids', str(app)],
            capture_output=True, text=True, check=True)
        assert list(map(int, result.stdout.split())) == [owned.pid] and not result.stderr
    finally:
        owned.terminate(); decoy.terminate()
        owned.wait(timeout=5); decoy.wait(timeout=5)


def readiness_diagnostics(fixture: Path) -> None:
    import shlex
    import sys
    from textwrap import dedent
    import validation_restore as subject
    missing = fixture / 'missing-readiness.json'
    result = subprocess.run([sys.executable, str(ROOT / 'Scripts/validation_restore.py'), 'mac-ready',
        '/fixture/App.app', str(missing), 'run', 'source'], capture_output=True, text=True)
    assert result.returncode == 1 and 'FileNotFoundError' in result.stderr and str(missing) in result.stderr
    ready = dict(schemaVersion=1, runID='fixture', initialized=False, sessionRecovered=False, active=False,
        processIdentifier=1, readyAt='2000-01-01T00:00:00Z')
    with patch.object(Path, 'read_text', return_value=json.dumps(ready)), \
            patch.object(Path, 'read_bytes', return_value=plistlib.dumps({})), \
            patch.object(subject.subprocess, 'run', return_value=Mock(returncode=1, stdout='')), \
            redirect_stderr(diagnostic := StringIO()):
        assert not subject.mac_ready(Path('/fixture/App.app'), missing, 'run', 'source', diagnose=True)
    state = json.loads(diagnostic.getvalue().split('：', 1)[1])
    assert state['App身份'] is False and state['初始化'] is False and state['进程存活'] is False and state['采样有效'] is False
    source = (ROOT / 'Scripts/build-install-device.sh').read_text()
    device = source[source.index('restore_deadline='):]
    mac = dedent(source[source.index('  mac_deadline='):source.index('\nfi\n\nBUILD_OVERRIDES=')])
    log = fixture / 'restore.log'
    for platform, block, failures in [('device', device, ('copy', 'process', 'probe', 'success')),
            ('mac', mac, ('probe', 'success'))]:
        for failure in failures:
            log.write_text('old readiness failure')
            harness = f'''set -euo pipefail
ROOT_DIR={shlex.quote(str(ROOT))} RESTORE_LOG={shlex.quote(str(log))} DERIVED_DATA={shlex.quote(str(fixture))}
BIT101_DEVICETCL_DEVICE_ID=fixture BIT101_VALIDATION_RUN_ID=fixture BIT101_VALIDATION_SOURCE_DIGEST=fixture BIT101_DEVICE_NAME=fixture
INSTALL_PATH=/fixture/App.app MAC_READINESS=/fixture/proof MAC_RUN_ID=fixture MAC_INPUT_DIGEST=fixture
failure={shlex.quote(failure)}
xcrun() {{
  if [[ "$failure" == copy && "$*" == *'copy from'* ]]; then print -u2 'fixture copy failed'; return 1; fi
  if [[ "$failure" == process && "$*" == *'info processes'* ]]; then print -u2 'fixture process sample failed'; return 1; fi
  return 0
}}
python3() {{
  if [[ "$1" == */validation_restore.py ]]; then
    if [[ "$failure" == probe ]]; then print -u2 'fixture initialization pending'; return 1; fi
    return 0
  fi
  command python3 "$@"
}}
sleep() {{ SECONDS=$(( SECONDS + 60 )); }}
'''
            result = subprocess.run(['zsh', '-c', harness + block], capture_output=True, text=True)
            assert result.returncode == (0 if failure == 'success' else 1), (platform, failure, result.stderr)
            assert 'old readiness failure' not in log.read_text()
            if failure == 'success': assert result.stderr == ''
            else:
                expected = {'copy': 'fixture copy failed', 'process': 'fixture process sample failed', 'probe': 'fixture initialization pending'}[failure]
                assert expected in result.stderr and str(log) in result.stderr, (platform, failure, result.stderr)


def cache_and_ui_products(fixture: Path) -> None:
    import ctypes
    from ci_evidence import native_cache_available
    from validation_artifacts import prune_native_storage
    from test_results import ui_host_product_paths
    cache = fixture / 'cache'
    native = cache / 'CompilationCache.noindex'
    native.mkdir(parents=True)
    assert not native_cache_available(native)
    (native / 'lock').touch()
    (native / 'v1.validation').write_text('metadata')
    (native / '.DS_Store').write_text('Finder metadata')
    assert not native_cache_available(native)
    data = native / 'generic/v1.1/data.v1'
    data.parent.mkdir(parents=True); data.write_bytes(b'active compilation records')
    assert native_cache_available(native)
    (cache / 'Index.noindex/DataStore').mkdir(parents=True)
    library = Mock()
    library.indexstore_store_create.return_value = 1
    with patch.object(subprocess, 'run') as prune, patch.object(subprocess, 'check_output', return_value='/active/usr/bin/swiftc\n'), \
            patch.object(ctypes, 'CDLL', return_value=library) as load:
        prune_native_storage(cache)
    prune.assert_called_once_with(['xcrun', 'llvm-cas', '--cas=' + str(native / 'generic'), '--prune'], check=True, stdout=subprocess.DEVNULL)
    load.assert_called_once_with('/active/usr/lib/libIndexStore.dylib')
    library.indexstore_store_purge_stale_data.assert_called_once_with(1)
    library.indexstore_store_dispose.assert_called_once_with(1)
    assert data.read_bytes() == b'active compilation records'
    from compiler_cache import run_cache
    with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
            patch('validation_artifacts.prune_native_storage') as automatic:
        try: run_cache([str(fixture), 'build.log', 'build', 'xcodebuild', 'build'])
        except SystemExit as status: assert status.code == 0
    automatic.assert_not_called()
    from validation_artifacts import main as audit_artifacts
    import fcntl
    def locked_prune(shared):
        with (shared / 'cache.lock').open('a') as other:
            try: fcntl.flock(other, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError: pass
            else: raise AssertionError('原生回收持有缓存写锁。')
        raise OSError('cache busy')
    with patch('validation_artifacts.prune_native_storage', side_effect=locked_prune) as automatic, redirect_stderr(output := StringIO()):
        audit_artifacts(fixture)
    automatic.assert_called_once_with(fixture / '.build/compiler-cache')
    assert '缓存回收待重试' in output.getvalue()
    products = fixture / 'products'; products.mkdir()
    app = products / 'Release-iphonesimulator/App.app'
    runner = products / 'Release-iphonesimulator/Runner.app'
    watch = products / 'Release-watchsimulator/Watch.app'
    unrelated = products / 'Release-maccatalyst/Other.app'
    for path in (app, runner, watch, unrelated): path.mkdir(parents=True)
    target = dict(TestHostPath='__TESTROOT__/Release-iphonesimulator/Runner.app',
        UITargetAppPath='__TESTROOT__/Release-iphonesimulator/App.app',
        DependentProductPaths=['__TESTROOT__/Release-watchsimulator/Watch.app',
            '__TESTROOT__/Release-iphonesimulator/Runner.app/PlugIns/tests.xctest'])
    plan = products / 'BIT101-iOS-UIAutomation_fixture_iphonesimulator.xctestrun'
    plan.write_bytes(plistlib.dumps(dict(TestConfigurations=[dict(TestTargets=[target])])))
    assert set(ui_host_product_paths(products)) == {plan, app, runner, watch}
    target['TestHostPath'] = '__TESTROOT__/../Other.app'
    plan.write_bytes(plistlib.dumps(dict(TestConfigurations=[dict(TestTargets=[target])])))
    try: ui_host_product_paths(products)
    except ValueError: pass
    else: raise AssertionError('运行文件需要位于当前产品目录')


def incremental_archives(fixture: Path) -> None:
    from report_inbox import refresh_archive_index, prune_archive
    folder = fixture / 'archives'
    report = folder / '正式版/错误报告/report_old.json'
    recent = folder / '开发版/用户建议/report_recent.json'
    report.parent.mkdir(parents=True); recent.parent.mkdir(parents=True)
    report.write_text(json.dumps(dict(report=dict(comment='large history' * 100))))
    recent.write_text(json.dumps(dict(report=dict(mode='suggestion'))))
    refresh_archive_index(folder)
    read_text = Path.read_text
    reads = []
    def read(path, *args, **kwargs):
        reads.append(path)
        return read_text(path, *args, **kwargs)
    with patch.object(Path, 'read_text', read):
        refresh_archive_index(folder)
    assert report not in reads and recent not in reads
    recent.write_text(json.dumps(dict(report=dict(mode='suggestion', comment='changed'))))
    reads.clear()
    with patch.object(Path, 'read_text', read): refresh_archive_index(folder)
    assert report not in reads and reads.count(recent) == 1
    now = 100 * 86_400 * 1_000_000_000
    os.utime(report, ns=(0, 0)); os.utime(recent, ns=(now, now))
    with patch('time.time_ns', return_value=now), redirect_stdout(StringIO()): prune_archive(folder, 30)
    assert not report.exists() and recent.is_file()
    assert len(refresh_archive_index(folder)) == 1


def focused_result_retention(fixture: Path) -> None:
    import validation_performance as subject
    import validation_provenance as provenance
    bundle = fixture / 'results/test-results.xcresult'
    diagnostic = bundle.parent / 'diagnostics/test-results.xcresult'
    report = fixture / 'validation-evidence.json'
    def create(path, content):
        path.mkdir(parents=True, exist_ok=True)
        (path / 'Info.plist').write_bytes(content)
    create(bundle, b'full acceptance')
    report.write_text(json.dumps(dict(groups={'all': dict(scope='full', proof='retained')})))
    with patch.object(subject, 'BUNDLE', bundle), patch.object(subject, 'ROOT', fixture), \
            patch.object(provenance, 'REPORT', report), patch.object(provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(subject, 'merge_result_bundles', side_effect=AssertionError('定向回归需要覆盖当前诊断')):
        for current in (b'focused first', b'focused second', b'focused current'):
            subject.begin_result_step(True, selected_groups=['all'])
            create(bundle, current)
            current_report = json.loads(report.read_text())
            current_report['groups']['focused'] = dict(scope='selected', resultBundleIdentity=subject.bundle_identity(bundle),
                performance=dict(records=dict(sample=dict(resultBundle=dict(path=str(bundle.relative_to(fixture)))))))
            report.write_text(json.dumps(current_report))
            subject.merge_result_step(['all'])
            assert (bundle / 'Info.plist').read_bytes() == b'full acceptance'
            assert (diagnostic / 'Info.plist').read_bytes() == current
            assert not bundle.with_suffix('.retained.xcresult').exists()
            stored = json.loads(report.read_text())['groups']
            assert stored['all'] == dict(scope='full', proof='retained')
            assert stored['focused']['resultBundlePath'] == str(diagnostic)
            assert stored['focused']['performance']['records']['sample']['resultBundle']['path'] == str(diagnostic.relative_to(fixture))
        subject.begin_result_step(True, selected_groups=['all'])
        create(bundle, b'interrupted current')
        shutil.rmtree(diagnostic); shutil.move(str(bundle), str(diagnostic))
        subject.recover_result_step()
        assert (bundle / 'Info.plist').read_bytes() == b'full acceptance'
        assert (diagnostic / 'Info.plist').read_bytes() == b'interrupted current'
        assert 'selectedResult' not in json.loads(report.read_text())


def full_result_batches(fixture: Path) -> None:
    import validation_performance as subject
    import validation_provenance as provenance
    bundle = fixture / 'results/test-results.xcresult'
    report = fixture / 'validation-evidence.json'
    shutil.rmtree(bundle.parent)
    report.write_text(json.dumps(dict(groups={})))
    def create(path, content):
        path.mkdir(parents=True, exist_ok=True)
        (path / 'Info.plist').write_bytes(content)
    def merge(command, **kwargs):
        assert command[:3] == ['xcrun', 'xcresulttool', 'merge']
        create(Path(command[4]), (Path(command[5]) / 'Info.plist').read_bytes() + (Path(command[6]) / 'Info.plist').read_bytes())
        return subprocess.CompletedProcess(command, 0)
    with patch.object(subject, 'BUNDLE', bundle), patch.object(subject, 'ROOT', fixture), \
            patch.object(provenance, 'REPORT', report), patch.object(provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(provenance, 'source_digest', return_value='input'), patch.object(subject, 'environment_context', return_value={}), \
            patch.object(subject.subprocess, 'run', side_effect=merge), patch.object(subject.subprocess, 'check_output', return_value=b'{}'), \
            redirect_stderr(StringIO()):
        for group in ('all', 'ui', 'all', 'ui', 'ui', 'all'):
            retained = subject.begin_selected_result_step(replacing_group=group)
            create(bundle, (group + '\n').encode())
            current = json.loads(report.read_text())
            current['groups'][group] = dict(scope='full', exitCode=0, summary=dict(passed=True), inputDigest='input',
                environment={}, resultBundleIdentity=subject.bundle_identity(bundle))
            report.write_text(json.dumps(current))
            if retained: subject.retain_result_step([*retained, group])
            runs = (bundle / 'Info.plist').read_text().splitlines()
            assert len(runs) == len(set(runs)) <= 2
            assert set(runs) == {*retained, group}
        current = json.loads(report.read_text())
        current['groups']['all'] = dict(scope='selected', exitCode=1, resultBundleIdentity='diagnostic', lastFullRun=current['groups']['all'])
        report.write_text(json.dumps(current))
        assert subject.begin_selected_result_step(replacing_group='all') == []
        assert not bundle.exists()


def result_readers(fixture: Path) -> None:
    from test_results import current_result_bundle, report_test_results
    root = fixture / 'debug-results'
    bundle, diagnostic = root / 'test-results.xcresult', root / 'diagnostics/test-results.xcresult'
    def create(path, modified):
        path.mkdir(parents=True, exist_ok=True)
        (path / 'Info.plist').write_bytes(b'native fixture')
        for item in (path / 'Info.plist', path): os.utime(item, ns=(modified, modified))
    create(bundle, 10); create(diagnostic, 20)
    assert current_result_bundle(bundle) == diagnostic
    tree = {'title': 'Tap current result', 'attachments': [
        {'name': '失败时的界面元素树', 'payloadId': 'native'},
        {'name': 'App UI hierarchy for current', 'payloadId': 'app'},
        {'name': 'Crash Log current', 'payloadId': 'crash'},
        {'name': '界面截图', 'payloadId': 'image'}]}
    commands = []
    def read(command, **kwargs):
        commands.append(command)
        if 'activities' in command: return json.dumps(tree)
        return json.dumps(dict(result='Failed', passedTests=0, totalTestCount=1))
    def export(command, **kwargs):
        commands.append(command)
        path = Path(command[command.index('--output-path') + 1])
        path.write_text(command[command.index('--id') + 1] + ' current attachment\n')
        return subprocess.CompletedProcess(command, 0)
    for action, mode, choice in (('report', '', ''), ('report', 'json', ''), ('report', 'coverage', ''),
            ('activities', 'Current/test()', 'json'), ('screenshot', 'Current/test()', 'image'),
            ('report', 'Current/test()', '')):
        with patch.object(subprocess, 'check_output', side_effect=read), patch.object(subprocess, 'run', side_effect=export), redirect_stdout(StringIO()):
            try: report_test_results([str(bundle), mode, action, str(ROOT / 'Scripts'), choice])
            except SystemExit as status: assert status.code == 0
    assert commands and all((command[command.index('--path') + 1] if '--path' in command else command[-1]) == str(diagnostic) for command in commands)
    combined = (root / 'failure-hierarchy.txt').read_text()
    assert all(kind + ' current attachment' in combined for kind in ('native', 'app', 'crash'))
    assert not (root / 'diagnostics/failure-hierarchy.txt').exists()
    screenshot = root.parent / 'screenshot.png'
    retained_image = screenshot.read_bytes()
    for choice, failed_export in (('missing', False), ('image', True)):
        with patch.object(subprocess, 'check_output', side_effect=read), \
                patch.object(subprocess, 'run', side_effect=subprocess.CalledProcessError(7, 'export')) as exported, redirect_stdout(StringIO()):
            try: report_test_results([str(bundle), 'Current/test()', 'screenshot', str(ROOT / 'Scripts'), choice])
            except (SystemExit, subprocess.CalledProcessError): pass
            else: raise AssertionError('截图选择及导出失败需要返回失败。')
        assert exported.called == failed_export and screenshot.read_bytes() == retained_image
        assert not (root / 'diagnostics/screenshot.png').exists()
    metrics = root / 'test-metrics.txt'
    metrics.write_text('结果：Failed；总计 1；通过 0；失败 1\n构建与运行耗时：2 秒\n测试实例：' + 'raw inventory ' * 1000)
    (root / 'test-failures.txt').write_text('error: current failure\n' * 50)
    with redirect_stdout(console := StringIO()):
        report_test_results([str(bundle), '', 'report', str(ROOT / 'Scripts'), ''])
    assert '结果：Failed' in console.getvalue() and str(metrics) in console.getvalue()
    assert 'raw inventory' not in console.getvalue() and len(console.getvalue().splitlines()) < 50
    metrics.write_text(metrics.read_text() + '\n结果来源：' + json.dumps(dict(family='modules', coverage='old-coverage.json')))
    modified = metrics.stat().st_mtime_ns + 1
    create(diagnostic, modified)
    for mode in ('', 'json', 'coverage'):
        with patch.object(subprocess, 'check_output', side_effect=read), redirect_stdout(console := StringIO()):
            try: report_test_results([str(bundle), mode, 'report', str(ROOT / 'Scripts'), ''])
            except SystemExit as status: assert status.code == 0
        assert 'Failed' in console.getvalue() and str(metrics) not in console.getvalue(), '当前结果包优先于旧指标'
    with patch.object(subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'summary')), redirect_stdout(console := StringIO()):
        try: report_test_results([str(bundle), '', 'report', str(ROOT / 'Scripts'), ''])
        except SystemExit as status: assert str(diagnostic) in str(status) and 'diagnostics' in str(status)
        else: raise AssertionError('编译结果沿当前诊断入口呈现')
    assert str(metrics) not in console.getvalue()
    create(bundle, modified + 1)
    assert current_result_bundle(bundle) == bundle
    (bundle / 'Staging').mkdir()
    os.utime(bundle / 'Staging', ns=(modified + 2, modified + 2)); os.utime(bundle, ns=(modified + 2, modified + 2))
    assert current_result_bundle(bundle) == bundle


def archive_prune_then_fetch(fixture: Path) -> None:
    from report_inbox import archive_reports, prune_archive
    root = fixture / 'prune-fetch'
    staging = root / '.incoming'; staging.mkdir(parents=True)
    keys, processed = root / 'keys.json', root / 'report-keys.txt'
    key = 'report:old'
    keys.write_text(json.dumps([dict(name=key)]))
    def response(command, **kwargs):
        return subprocess.CompletedProcess(command, 0, json.dumps(dict(report=dict(comment='retained remote'))), '')
    arguments = [str(keys), str(staging), '/worker', 'namespace', str(processed)]
    with patch.object(subprocess, 'run', side_effect=response) as download, redirect_stdout(StringIO()):
        archive_reports(arguments)
        archived = next(root.glob('*/*/report_*.json'))
        os.utime(archived, ns=(0, 0))
        prune_archive(root, 30)
        assert not archived.exists()
        archive_reports(arguments)
    assert download.call_count == 1 and not archived.exists()
    assert 'pruned-file:report_old.json' in processed.read_text()
    processed.write_text(processed.read_text() + 'report:expired\npruned-file:report_expired.json\n')
    keys.write_text('[]')
    with patch.object(subprocess, 'run', side_effect=response) as download, redirect_stdout(StringIO()):
        archive_reports(arguments)
    assert processed.read_text() == '' and not download.called, '远端过期且本地已清理的处理键随抓取回收'


def cache_cleanup_after_failure() -> None:
    import ci_evidence as subject
    artifacts = [dict(id=i, name='compilation-cache-simulator-app', expired=False, workflow_run=dict(id=i)) for i in (1, 2, 3)]
    def run(command, **kwargs):
        identity = int(command[-1].rsplit('/', 1)[-1])
        return json.dumps(dict(id=identity, event='workflow_dispatch', head_branch='main',
            head_repository=dict(full_name='owner/repo'), path='.github/workflows/ci.yml',
            status='in_progress' if identity == 3 else 'completed'))
    with patch.dict(os.environ, GITHUB_RUN_ID='2'), patch.object(subject, 'repository', return_value='owner/repo'), \
            patch.object(subject, 'api_pages', return_value=[dict(artifacts=artifacts)]), \
            patch.object(subject.subprocess, 'check_output', side_effect=run), \
            patch.object(subject, 'cache_result_matches', side_effect=lambda repo, run, flavor: run['id'] == 1), \
            patch.object(subject.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as deleted:
        subject.prune_caches()
    assert [call.args[0][-1] for call in deleted.call_args_list] == ['repos/owner/repo/actions/artifacts/2']


def audit_failure_summary(fixture: Path) -> None:
    from command_output import show_log
    path = fixture / 'audit.log'
    path.write_text(''.join(f'error: preceding {index}\n' for index in range(45)) + 'error: decisive current cause\n')
    with patch.dict(os.environ, GITHUB_ACTIONS='false'), redirect_stdout(output := StringIO()): show_log(path, True)
    assert 'preceding 0' in output.getvalue() and 'decisive current cause' in output.getvalue()


def changed_staged_scripts(fixture: Path) -> None:
    repo = fixture / 'staged-scripts'
    (repo / 'Scripts').mkdir(parents=True)
    def git(*arguments):
        result = subprocess.run(['git', *arguments], cwd=repo, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
    git('init', '-q')
    (repo / 'Scripts/existing.py').write_text('print(undefined_name)\n')
    target = repo / 'Scripts/changed.py'
    target.write_text('print("initial")\n')
    git('add', '.')
    git('-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture')
    (repo / 'README.md').write_text('Documentation\n'); git('add', 'README.md')
    command = [str(Path(os.sys.executable)), '-B', str(ROOT / 'Scripts/check-python-syntax.py'), str(repo), '--staged']
    result = subprocess.run([*command, '--changed'], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    target.write_text('print("staged")\n'); git('add', str(target))
    target.write_text('print(worktree_only_name)\n')
    result = subprocess.run([*command, '--changed'], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    target.write_text('print(staged_undefined_name)\n'); git('add', str(target))
    result = subprocess.run([*command, '--changed'], capture_output=True, text=True)
    assert result.returncode and 'staged_undefined_name' in result.stderr
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode and 'undefined_name' in result.stderr


def immediate_audit_output(fixture: Path) -> None:
    import select
    import shlex
    import signal
    from script_test_support import shell_function
    support = ROOT / 'Scripts/script-support.sh'
    functions = '\n'.join(shell_function(support, name) for name in (
        'bit101_show_audit_log', 'bit101_run_audit_group', 'bit101_wait_audit_groups'))
    harness = 'ROOT_DIR=' + shlex.quote(str(ROOT)) + '\nLOG_DIR=' + shlex.quote(str(fixture)) + '\n' + functions + '''
slow_probe() { sleep 60; }
failed_probe() { print 'error: immediate failure'; return 7; }
bit101_run_audit_group slow slow_probe &
slow_pid=$!
bit101_run_audit_group fast failed_probe || true
wait "$slow_pid"
'''
    process = subprocess.Popen(['zsh', '-c', harness], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        start_new_session=True, env=dict(os.environ, GITHUB_ACTIONS='false'))
    try:
        assert select.select([process.stdout], [], [], 5)[0], '失败组需要即时显示根因。'
        assert 'immediate failure' in process.stdout.readline() and process.poll() is None
    finally:
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=5)
    harness = functions + '''
BIT101_AUDIT_BACKGROUND=1
group_names=(slow fast)
group_processes=()
failed_groups=()
sleep 60 & group_processes+=($!)
(exit 7) & group_processes+=($!)
bit101_wait_audit_groups
print -r -- "AGGREGATED ${failed_groups[*]}"
wait "$group_processes[1]"
'''
    process = subprocess.Popen(['zsh', '-c', harness], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        assert select.select([process.stdout], [], [], 5)[0], '后台聚合需要及时归集已完成的失败组。'
        assert process.stdout.readline().strip() == 'AGGREGATED fast' and process.poll() is None
    finally:
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=5)


def native_target_inventory_self_test(rules: dict) -> None:
    root = Path('/fixture')
    for name, registered in (('BIT101Watch/Source.swift', True), ('BIT101ShareExtension/Source.swift', False)):
        source = root / name
        with patch(f"{rules['native_target_errors'].__module__}.subprocess.check_output", return_value=json.dumps({})), \
                patch('validation_inputs.native_project_paths', return_value={}), \
                patch('code_quality_rules.native_project_targets', return_value=[('Target', set(), {source})]), \
                patch('validation_inputs.repository_input_names', return_value=[name]), patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', return_value=''):
            errors = rules['native_target_errors'](root, {'products': []}, set())
            assert bool(errors) != registered, (name, errors)
    for present in (True, False):
        with patch(f"{rules['native_target_errors'].__module__}.subprocess.check_output", return_value=json.dumps({})), \
                patch('validation_inputs.native_project_paths', return_value={}), \
                patch('code_quality_rules.native_project_targets', return_value=[]), \
                patch('validation_inputs.repository_input_names', return_value=['BIT101-iOS/Excluded.swift']), \
                patch.object(Path, 'is_file', return_value=present):
            errors = rules['native_target_errors'](root, {'products': []}, set())
            assert any('target membership' in error for error in errors) == present
    project = {'rootObject': 'project', 'objects': {
        'project': {'mainGroup': 'main'}, 'main': {'children': ['group', 'sdk', 'product', 'direct']},
        'group': {'path': 'Shared', 'children': ['existing', 'missing']},
        'existing': {'isa': 'PBXFileReference', 'path': 'Existing.swift'},
        'missing': {'isa': 'PBXFileReference', 'path': 'Missing.swift'},
        'direct': {'isa': 'PBXFileReference', 'path': 'Direct.swift', 'sourceTree': 'SOURCE_ROOT'},
        'sdk': {'isa': 'PBXFileReference', 'path': 'Foundation.framework', 'sourceTree': 'SDKROOT'},
        'product': {'isa': 'PBXFileReference', 'path': 'App.app', 'sourceTree': 'BUILT_PRODUCTS_DIR'}}}
    with patch(f"{rules['native_target_errors'].__module__}.subprocess.check_output", return_value=json.dumps(project)), \
            patch('code_quality_rules.native_project_targets', return_value=[]), \
            patch('validation_inputs.repository_input_names', return_value=[]), \
            patch.object(Path, 'exists', lambda path: path.name == 'Existing.swift'):
        errors = rules['native_target_errors'](root, {'products': []}, set())
        assert len(errors) == 2 and any('Shared/Missing.swift' in error for error in errors) and any('Direct.swift' in error for error in errors)
