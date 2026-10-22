"""Exercise bounded development artifacts through their public Python APIs."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from contextlib import nullcontext, redirect_stdout, redirect_stderr
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
        result_readers(fixture)
        archive_prune_then_fetch(fixture)
        cache_cleanup_after_failure()
        audit_failure_summary(fixture)
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


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
