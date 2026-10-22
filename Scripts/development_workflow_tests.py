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
        first['declarations'].append(first['declarations'][0])
        assert subject.swift_syntax_index_sources({str(path): source})[str(path)] == expected
        first = expected
        with closing(sqlite3.connect(cache)) as database, database:
            database.execute('INSERT INTO facts VALUES (?, ?)', ('unrequested.swift', 'invalid JSON'))
        relative = str(path.relative_to(ROOT))
        assert subject.swift_syntax_index_sources({relative: source})[relative] == first and parse.call_count == 1
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
                    database.execute('UPDATE facts SET content = ? WHERE path = ?', (json.dumps(first), str(path)))
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
        joined = subject.swift_syntax_index_sources(derived_source | {str(base): base.read_text()})
        assert joined[str(derived)]['tests']
        assert not subject.swift_syntax_index_sources(derived_source)[str(derived)]['tests']


def audit_self_test_selection() -> None:
    from script_test_support import shell_function
    function = shell_function(ROOT / 'Scripts/script-support.sh', 'bit101_checker_audit')
    for enabled in ('0', '1'):
        script = f'ROOT_DIR=/fixture BIT101_AUDIT_SELF_TESTS={enabled}\npython3() {{ print -r -- "$*"; }}\n'
        result = subprocess.run(['zsh', '-c', script + function + '\nbit101_checker_audit'], capture_output=True, text=True, check=True)
        assert 'check-code-quality.py --combined' in result.stdout
        assert ('validation_evidence.py self-test' in result.stdout) == (enabled == '1')
        assert ('--combined --self-test' in result.stdout) == (enabled == '1')


def cache_and_ui_products(fixture: Path) -> None:
    import ctypes
    from ci_evidence import native_cache_available
    from compiler_cache import prune_native_storage
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
            patch('compiler_cache.prune_native_storage', side_effect=OSError('cache busy')) as automatic, \
            redirect_stderr(output := StringIO()):
        try: run_cache([str(fixture), 'build.log', 'build', 'xcodebuild', 'build'])
        except SystemExit as status: assert status.code == 0
    assert automatic.called and '缓存回收待重试' in output.getvalue()
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
    create(bundle, 30)
    assert current_result_bundle(bundle) == bundle
    (bundle / 'Staging').mkdir()
    os.utime(bundle / 'Staging', ns=(40, 40)); os.utime(bundle, ns=(40, 40))
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


def cache_cleanup_after_failure() -> None:
    import ci_evidence as subject
    artifacts = [dict(id=i, name='compilation-cache-simulator-ui', expired=False, workflow_run=dict(id=i)) for i in (1, 2, 3)]
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
