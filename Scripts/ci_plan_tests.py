"""Regression contracts for CI validation plans and portable result records."""
import json
import os
import subprocess
from pathlib import Path
from copy import deepcopy
from unittest.mock import patch
from validation_environment import toolchain_identity

CONTEXT = {'host': {'system': 'Darwin', 'architecture': 'arm64', 'ProductVersion': '27', 'ProductBuildVersion': 'host'},
    'xcode': {'CFBundleVersion': '27'}, 'toolchains': '', 'compiler': {'size': 10, 'version': 'Swift fixture'},
    'sdks': {'MacOSX': {'Version': '27'}, 'iPhoneOS': {'Version': '27'}, 'WatchOS': {'Version': '27'}},
    'device': {'systemVersion': '27.0', 'systemBuild': 'simulator'}}
ENVIRONMENT = dict(host=CONTEXT['host'], toolchain=toolchain_identity(CONTEXT))
PLATFORM = CONTEXT['device']


def environment_fixture(group):
    return deepcopy(ENVIRONMENT | ({'runtimes': [PLATFORM]} if group == 'app' else {}))


def result_fixture(candidate):
    from validation_inputs import CI_VALIDATION_GROUPS
    return dict(schemaVersion=1, commit=candidate['head_sha'], run=str(candidate['id']), groups={
        group: dict(passed=True, scopes=list(scopes), environment=deepcopy(ENVIRONMENT | (
            {'platform': PLATFORM} if group == 'app' else {})))
        for group, (scopes, _, _) in CI_VALIDATION_GROUPS.items()})


def self_test(subject) -> None:
    def result(candidate, group):
        return candidate.get('_result', result_fixture(candidate))
    with patch.object(subject, 'ci_validation_environment', side_effect=environment_fixture), \
            patch.object(subject, 'validation_result', side_effect=result):
        plan_self_test(subject)
        result_self_test(subject)
        export_self_test(subject)
    archive_self_test(subject)
    environment_self_test(subject)
    wiring_self_test(subject)
    from ci_simulator_tests import self_test as simulator_self_test
    simulator_self_test(subject, CONTEXT, PLATFORM, environment_fixture)

def plan_self_test(subject) -> None:
    from copy import deepcopy
    select_validation_plan = subject.select_validation_plan
    read_validation_plan = subject.read_validation_plan
    validation_plan = subject.validation_plan
    from unittest.mock import patch
    from validation_inputs import CI_VALIDATION_GROUPS
    commit = 'a' * 40
    candidate = {'id': 7, 'head_sha': 'b' * 40,
        'jobs': [{'name': name, 'conclusion': 'success'} for _, names, _ in CI_VALIDATION_GROUPS.values() for name in names],
        'artifacts': [{'name': name, 'expired': False} for _, _, names in CI_VALIDATION_GROUPS.values() for name in names]}
    for names, required in (([], set()), (['README.md'], set()),
            (['BIT101-iOSUITests/InteractionCoverageCommunityUITests.swift'], set()),
            (['BIT101-iOSTests/AccountTests.swift'], {'release', 'app', 'catalyst'}),
            (['BIT101-iOSTests/PerformanceWorkloads.json'], {'release', 'app', 'catalyst'}),
            (['BIT101-iOS/Feature.swift'], {'release', 'app', 'catalyst'}),
            (['Modules/Feature/Sources/Feature.swift'], set(CI_VALIDATION_GROUPS)),
            (['.github/workflows/ci.yml'], set(CI_VALIDATION_GROUPS)),
            (['Scripts/simulator-tests.sh'], set(CI_VALIDATION_GROUPS))):
        plan = select_validation_plan(commit, '8', [candidate], lambda _: names)
        assert {group for group, row in plan['jobs'].items() if row['execute']} == required, names
        assert all(row['run'] == '7' and row['commit'] == 'b' * 40 for row in plan['jobs'].values() if not row['execute'])
    for conclusion in ('failure', 'timed_out', 'action_required', 'cancelled', 'skipped', None):
        failed = deepcopy(candidate)
        next(job for job in failed['jobs'] if job['name'] == 'iOS Simulator app and formal runtime')['conclusion'] = conclusion
        older = candidate | {'id': 6}
        plan = select_validation_plan(commit, '8', [failed, older], lambda _: [])
        assert not plan['jobs']['catalyst']['execute']
        if conclusion in ('failure', 'timed_out', 'action_required'):
            assert plan['jobs']['app']['execute']
        else:
            assert not plan['jobs']['app']['execute'] and plan['jobs']['app']['run'] == '6'
            failed['head_sha'] = 'c' * 40
            plan = select_validation_plan(commit, '8', [failed, older],
                lambda source: ['BIT101-iOS/Feature.swift'] if source == failed['head_sha'] else [])
            assert plan['jobs']['app']['run'] == '6'
            plan = select_validation_plan(commit, '8', [failed, older], lambda _: ['BIT101-iOS/Feature.swift'])
            assert plan['jobs']['app']['execute']
            plan = select_validation_plan(commit, '8', [failed], lambda _: [])
            assert plan['jobs']['app']['execute']
    absent = deepcopy(candidate)
    absent['jobs'] = [job for job in absent['jobs'] if job['name'] != 'iOS Simulator app and formal runtime']
    assert select_validation_plan(commit, '8', [absent, older], lambda _: [])['jobs']['app']['run'] == '6'
    missing = deepcopy(candidate)
    next(row for row in missing['artifacts'] if row['name'] == 'validation-ios-test-shards-app-0')['expired'] = True
    plan = select_validation_plan(commit, '8', [missing], lambda _: [])
    assert plan['jobs']['app']['execute'] and not plan['jobs']['catalyst']['execute']
    plan = select_validation_plan(commit, '8', [missing, candidate | {'id': 6}], lambda _: [])
    assert plan['jobs']['app']['run'] == '6'
    def unused():
        raise AssertionError('发布全量验收沿当前运行执行。')
        yield
    assert all(row['execute'] for row in select_validation_plan(commit, '8', unused(), lambda _: [], full=True)['jobs'].values())
    from contextlib import redirect_stdout
    from io import StringIO
    module = subject
    for environment, full in (({}, False), ({'BIT101_FULL_CHECK': 'true'}, True),
            ({'BIT101_FULL_CHECK': 'false'}, False), ({'BIT101_RELEASE_CHECK': 'true'}, False),
            ({'GITHUB_REF': 'refs/tags/v1.0'}, False)):
        context = dict(BIT101_FULL_CHECK='false', BIT101_RELEASE_CHECK='false', GITHUB_REF='refs/heads/main',
            GITHUB_RUN_ID='8', GITHUB_OUTPUT='plan') | environment
        with patch.dict(os.environ, context), patch('validation_environment.ci_commit_findings', return_value=[]), \
                patch.object(module, 'repository', return_value='owner/repo'), patch.object(Path, 'open') as output, \
                patch.object(subprocess, 'check_output', side_effect=[commit, '[{"workflow_runs": []}]']) as requests, \
                redirect_stdout(StringIO()):
            validation_plan()
            written = json.loads(output.return_value.__enter__.return_value.write.call_args.args[0].removeprefix('plan='))
            assert written['commit'] == commit and written['run'] == '8'
            assert all(row['execute'] and (row['reason'] == '完整验收') == full for row in written['jobs'].values())
            assert requests.call_count == (1 if full else 2), environment
    def affected():
        yield candidate
        raise AssertionError('受影响的验证组沿当前运行执行。')
    assert all(row['execute'] for row in select_validation_plan(commit, '8', affected(),
        lambda _: ['.github/workflows/ci.yml'])['jobs'].values())
    valid = select_validation_plan(commit, '8', [candidate], lambda _: [])
    with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_RUN_ID='8', BIT101_CI_PLAN=json.dumps(valid)):
        assert read_validation_plan() == valid
    for key, value in (('commit', 'c' * 40), ('run', '9'), ('jobs', {})):
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_RUN_ID='8', BIT101_CI_PLAN=json.dumps(valid | {key: value})):
            try: read_validation_plan()
            except ValueError: pass
            else: raise AssertionError('来源计划需要匹配当前运行与全部验证组。')
    for key, value in (('execute', 'false'), ('commit', 'invalid'), ('run', '0')):
        malformed = deepcopy(valid)
        malformed['jobs']['app'][key] = value
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_RUN_ID='8', BIT101_CI_PLAN=json.dumps(malformed)):
            try: read_validation_plan()
            except ValueError: pass
            else: raise AssertionError('复用来源需要有效的执行状态与身份。')


def result_self_test(subject) -> None:
    from validation_inputs import CI_VALIDATION_GROUPS
    candidate = dict(id=7, head_sha='b' * 40,
        jobs=[dict(name=name, conclusion='success') for _, names, _ in CI_VALIDATION_GROUPS.values() for name in names],
        artifacts=[dict(name=name, expired=False) for _, _, names in CI_VALIDATION_GROUPS.values() for name in names])
    def selected(row):
        return subject.select_validation_plan('a' * 40, '8', [row], lambda _: [])['jobs']
    static = dict(candidate, jobs=[dict(name='Static audit (Apple toolchain)', conclusion='success')],
        artifacts=[dict(name='validation-static-audit', expired=False)])
    assert selected(static)['modules']['execute']
    for payload in (None, {}, {'schemaVersion': 1, 'commit': candidate['head_sha'], 'run': '7', 'groups': []}):
        assert all(row['execute'] for row in selected(candidate | {'_result': payload}).values())
    for key, value in (('run', '8'), ('commit', 'c' * 40), ('schemaVersion', 0)):
        assert all(row['execute'] for row in selected(candidate | {'_result': result_fixture(candidate) | {key: value}}).values())
    for key, value in (('passed', False), ('scopes', []), ('environment', None)):
        result = result_fixture(candidate)
        result['groups']['modules'][key] = value
        plan = selected(candidate | {'_result': result})
        assert plan['modules']['execute'] and not plan['release']['execute']
    for field in ('xcode', 'compiler', 'sdks'):
        result = result_fixture(candidate)
        result['groups']['modules']['environment']['toolchain'][field] = {'changed': True}
        assert selected(candidate | {'_result': result})['modules']['execute']
    for field in ('host', 'platform'):
        result = result_fixture(candidate)
        result['groups']['app']['environment'][field] = {'changed': True}
        plan = selected(candidate | {'_result': result})
        assert plan['app']['execute'] and not plan['catalyst']['execute']
    incomplete = deepcopy(candidate)
    next(job for job in incomplete['jobs'] if job['name'] == 'iOS Simulator behavior tests')['conclusion'] = 'failure'
    incomplete['jobs'] = [job for job in incomplete['jobs'] if job['name'] != 'iOS Simulator behavior tests'] + [
        dict(name='iOS Simulator behavior tests', conclusion='failure')]
    assert selected(incomplete)['app']['execute']
    from contextlib import redirect_stdout
    from io import StringIO
    plan = subject.select_validation_plan('a' * 40, '8', [candidate], lambda _: [])
    with patch.dict(os.environ, GITHUB_SHA='a' * 40, GITHUB_RUN_ID='8', GITHUB_STEP_SUMMARY='summary', BIT101_CI_PLAN=json.dumps(plan)), \
            patch.object(subject, 'api_pages', return_value=[{'artifacts': []}]), \
            patch.object(subject, 'repository', return_value='owner/repo'), patch.object(Path, 'open'), redirect_stdout(StringIO()):
        subject.reuse_validation('modules')
        with patch.object(subject, 'validation_result', return_value=None):
            try: subject.reuse_validation('modules')
            except ValueError: pass
            else: raise AssertionError('复用任务再次核对当前工具链与完整成功记录')
    pages = [{'workflow_runs': []}, {'workflow_runs': [candidate | {
        'event': 'workflow_dispatch', 'status': 'completed', 'head_branch': 'main', 'path': '.github/workflows/ci.yml',
        'head_repository': {'full_name': 'owner/repo'}}]}]
    def api(endpoint):
        if '/workflows/' in endpoint: return pages
        return [{'jobs': candidate['jobs']}] if endpoint.endswith('/jobs') else [{'artifacts': candidate['artifacts']}]
    with patch.dict(os.environ, GITHUB_RUN_ID='8', GITHUB_OUTPUT='plan', BIT101_FULL_CHECK='false'), \
            patch('validation_environment.ci_commit_findings', return_value=[]), patch.object(subject, 'api_pages', side_effect=api), \
            patch.object(subject, 'repository', return_value='owner/repo'), patch.object(Path, 'open') as output, \
            patch.object(subprocess, 'check_output', side_effect=lambda command, **_: 'a' * 40 if command[1] == 'rev-parse' else b''), \
            patch.object(subprocess, 'run', return_value=type('Result', (), {'returncode': 0})()), redirect_stdout(StringIO()):
        subject.validation_plan()
        value = json.loads(output.return_value.__enter__.return_value.write.call_args.args[0].removeprefix('plan='))
        assert all(not row['execute'] for row in value['jobs'].values())


def export_self_test(subject) -> None:
    from validation_inputs import CI_VALIDATION_GROUPS
    plan = dict(jobs={group: {'execute': True} for group in CI_VALIDATION_GROUPS})
    report = dict(groups={scope: dict(scope='full', environment=CONTEXT)
        for scopes, _, _ in CI_VALIDATION_GROUPS.values() for scope in scopes})
    for group in ('modules', 'release', 'catalyst'):
        with patch.object(subject, 'read_validation_plan', return_value=plan), \
                patch.object(Path, 'read_text', return_value=json.dumps(report)), patch.object(Path, 'mkdir'), \
                patch.object(Path, 'write_text') as saved, patch.object(subprocess, 'check_output', return_value='a' * 40), \
                patch('validation_environment.ci_commit_findings', return_value=[]), \
                patch('validation_evidence.group_complete', return_value=True), patch.dict(os.environ, GITHUB_RUN_ID='8'):
            subject.export_validation_result(group)
            result = json.loads(saved.call_args.args[0])
            assert set(result['groups']) == ({'app'} if group == 'ios' else {group})
            assert result['commit'] == 'a' * 40 and result['run'] == '8'
            with patch('validation_evidence.group_complete', return_value=False):
                try: subject.export_validation_result(group)
                except ValueError: pass
                else: raise AssertionError('完整验收通过后生成独立成功记录')
            with patch.object(subject, 'ci_validation_environment', return_value={'host': {}, 'toolchain': {}}):
                try: subject.export_validation_result(group)
                except ValueError: pass
                else: raise AssertionError('记录环境与当前工具链一致')


def archive_self_test(subject) -> None:
    from io import BytesIO
    import zipfile
    payload = BytesIO()
    with zipfile.ZipFile(payload, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr(subject.RESULT_FILE.name, json.dumps(result_fixture(dict(id=7, head_sha='b' * 40))))
    subject.read_validation_result.cache_clear()
    try:
        with patch.object(subprocess, 'check_output', return_value=payload.getvalue()) as api:
            assert subject.read_validation_result('owner/repo', 7)['run'] == '7'
            assert subject.read_validation_result('owner/repo', 7)['schemaVersion'] == 1
            api.assert_called_once()
    finally: subject.read_validation_result.cache_clear()


def environment_self_test(subject) -> None:
    runtimes = {'runtimes': [dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', isAvailable=True,
        version=PLATFORM['systemVersion'], buildversion=PLATFORM['systemBuild']),
        dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-26-0', isAvailable=False)]}
    with patch('validation_environment.environment_context', return_value=CONTEXT) as environment, \
            patch.object(subprocess, 'check_output', return_value=json.dumps(runtimes)):
        assert 'runtimes' not in subject.ci_validation_environment.__wrapped__('modules')
        environment.assert_called_with('modules')
        assert subject.ci_validation_environment.__wrapped__('app')['runtimes'] == [PLATFORM]
        environment.assert_called_with('build-release')


def wiring_self_test(subject) -> None:
    from ci_wiring_rules import ci_wiring_findings
    source = (subject.ROOT / '.github/workflows/ci.yml').read_text()
    assert not ci_wiring_findings(source)
    invalid_status = source.replace("BIT101_CI_CANCELLED: ${{ job.status == 'cancelled' }}",
        'BIT101_CI_CANCELLED: ${{ cancelled() }}', 1)
    assert any('诊断上传' in message for message in ci_wiring_findings(invalid_status))
    for original, replacement in (
            ('python3 Scripts/ci_evidence.py export-result modules', 'echo modules'),
            ('name: verified-result-modules', 'name: diagnostic-modules'),
            ('path: .build/extended-automation/ci-validation-result.json', 'path: other.json')):
        assert any('完整成功记录' in message for message in ci_wiring_findings(source.replace(original, replacement, 1)))
    detached = source.replace('ios-app-tests, ios-tests]', 'ios-app-tests]', 1)
    assert any('清理任务' in message for message in ci_wiring_findings(detached))
    workflow = json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))'], input=source.replace('\non:', '\n"on":'), text=True))
    for command in ('Scripts/run-extended-tests.sh ui', 'Scripts/run-extended-tests.sh verify all ui',
            'Scripts/run-extended-tests.sh verify', 'Scripts/run-extended-tests.sh verify --self-test',
            'Scripts/run-extended-tests.sh simulator ui', 'Scripts/run-extended-tests.sh simulator verify',
            'Scripts/run-extended-tests.sh simulator build-ui',
            'xcodebuild test -scheme BIT101-iOS-UIAutomation',
            'xcodebuild test -only-testing:BIT101-iOSUITests'):
        changed = deepcopy(workflow)
        changed['jobs']['extra-validation'] = {'if': False, 'runs-on': 'xcode-27', 'steps': [{'run': command}]}
        assert any('禁止执行 UITest' in message for message in ci_wiring_findings(json.dumps(changed))), command
        assert any('禁止执行 UITest' in message for message in ci_wiring_findings(
            json.dumps({'jobs': {'extra-validation': changed['jobs']['extra-validation']}}), ui_only=True)), command
    changed = deepcopy(workflow)
    changed['jobs']['extra-validation'] = {'strategy': {'matrix': {'mode': ['ui']}},
        'steps': [{'run': 'Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"'}]}
    assert any('禁止执行 UITest' in message for message in ci_wiring_findings(json.dumps(changed)))
    for name in ('catalyst-tests', 'ios-app-tests'):
        changed = deepcopy(workflow)
        for step in changed['jobs'][name]['steps']:
            settings = step.get('env', {})
            if 'BIT101_DIAGNOSTIC_PATHS' in settings:
                settings['BIT101_DIAGNOSTIC_PATHS'] = '\n'.join(line for line in settings['BIT101_DIAGNOSTIC_PATHS'].splitlines()
                    if line != '.build/extended-automation/diagnostics/test-results.xcresult')
        assert any('诊断' in message or '原始 XCTest' in message for message in ci_wiring_findings(json.dumps(changed))), name
