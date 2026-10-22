"""Exercise bounded development artifacts through their public Python APIs."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from contextlib import nullcontext, redirect_stdout
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
