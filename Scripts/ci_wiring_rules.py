"""Validate CI execution context, required jobs and coverage baseline ordering."""
import json
import ast
import os
import re
import subprocess
import shlex
from functools import cache
from audit_callback_rules import audit_callback_findings
from validation_policy import workflow_timeout_seconds
from ci_diagnostics import diagnostic_path_list

CI_RUNNER = "xcode-27"
CI_RELEASE_CONTEXT = "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inputs.release_check"
CI_NATIVE_CONTEXT = "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && (inputs.full_check || inputs.release_check)"
CI_STATIC_GATE = "${{ !cancelled() && (needs.validation-plan.result == 'success' || needs.validation-plan.result == 'skipped') }}"
CI_CANCELLATION = '${{ !(' + CI_RELEASE_CONTEXT + ') }}'
CI_CONCURRENCY_GROUP = 'ios-ci-${{ github.ref }}-${{ ' + CI_RELEASE_CONTEXT + ' }}'
CI_PLANNED_GROUPS = {'release-build': 'release', 'catalyst-tests': 'catalyst', 'ios-ui-build': 'ui',
    'ios-test-shards': 'ui', 'ios-app-tests': 'app'}
CI_EXECUTE = 'fromJSON(env.BIT101_CI_PLAN).jobs[env.BIT101_CI_GROUP].execute'
CI_EXECUTION = '${{ ' + CI_EXECUTE + ' }}'
CI_NATIVE_EXECUTION = '${{ (' + CI_NATIVE_CONTEXT + ') && ' + CI_EXECUTE + ' }}'
CI_NATIVE_REUSE = '${{ (' + CI_NATIVE_CONTEXT + ') && !' + CI_EXECUTE + ' }}'
CI_STATIC_EXECUTION = '${{ !(' + CI_NATIVE_CONTEXT + ') || !' + CI_EXECUTE + ' }}'
CI_DIAGNOSTICS = '${{ always() && ' + CI_EXECUTE + ' }}'
DIAGNOSTIC_PATHS = {
    'static-audit': {'.build/static-audit/*.log', '.build/code-quality-report.txt', '.build/ui-consistency-report.txt',
        '.build/compiler-cache/swift-syntax-indexer', '.build/compiler-cache/swift-syntax-indexer-inputs.json',
        '.build/static-audit/compilation-conditions.json',
        '.build/explanatory-text-report.txt', '.build/extended-automation/modules.log',
        '.build/extended-automation/module-events.jsonl', '.build/extended-automation/test-metrics.txt'},
    'release-build': {'.build/extended-automation/build-network-smoke.log', '.build/extended-automation/build-icloud-smoke.log',
        '.build/extended-automation/diagnostics/test-results.xcresult', 'build/DeviceInstall/build.log'},
    'catalyst-tests': {'.build/extended-automation/catalyst.log', '.build/extended-automation/catalyst-release-runtime.log',
        '.build/extended-automation/test-metrics.txt', '.build/extended-automation/test-failures.txt',
        '.build/extended-automation/test-results.xcresult'},
    'ios-tests': {'.build/extended-automation/simulator.log', '.build/extended-automation/all.log',
        '.build/extended-automation/release-runtime.log', '.build/extended-automation/ui.log',
        'build/DeviceInstall/build.log', '.build/extended-automation/restore.log',
        '.build/extended-automation/test-metrics.txt', '.build/extended-automation/test-results.xcresult',
        '.build/screenshot.png'},
}
DIAGNOSTIC_PATHS['ios-test-shards'] = DIAGNOSTIC_PATHS['ios-tests']
DIAGNOSTIC_PATHS['ios-app-tests'] = DIAGNOSTIC_PATHS['ios-tests']
DIAGNOSTIC_PATHS['ios-ui-build'] = {'.build/extended-automation/ui.log'}
for job, paths in DIAGNOSTIC_PATHS.items():
    if job != 'static-audit': paths.add('.build/extended-automation/diagnostics/test-results.xcresult')


def hook_documents_checked(source: str) -> bool:
    for line in source.splitlines():
        words = shlex.split(line, comments=True)
        if words[:1] == ['exec']: words = words[1:]
        if words[:2] == ['python3', 'Scripts/check-docs.py'] and '--staged' in words[2:]: return True
    return False


def active_script_markers(source: str) -> str:
    lines = []
    for line in source.splitlines():
        try: lines.append(' '.join(shlex.split(line, comments=True, posix=False)))
        except ValueError: lines.append(line if not line.lstrip().startswith('#') else '')
    return '\n'.join(lines)


def command_matches(actual: str, expected: str) -> bool:
    if not isinstance(actual, str) or not isinstance(expected, str): return False
    try:
        commands = [shlex.split(line, comments=True) for line in actual.replace('\\\n', ' ').splitlines()]
        commands = [words for words in commands if words]
        return len(commands) == 1 and commands[0] == shlex.split(expected, comments=True)
    except ValueError:
        return False


def runner_expression(value):
    if isinstance(value, list):
        return ('labels', tuple(sorted(value))) if all(isinstance(label, str) for label in value) else None
    if not isinstance(value, str): return None
    tokens = re.findall(r"'(?:[^']|'')*'|\"(?:[^\"\\]|\\.)*\"|==|!=|&&|\|\||\$\{\{|\}\}|[A-Za-z_]\w*|[^\s]", value)
    for position, token in enumerate(tokens):
        if token.startswith("'[") and token.endswith("]'"):
            try: labels = json.loads(token[1:-1])
            except ValueError: return None
            normalized = runner_expression(labels)
            if normalized is None: return None
            tokens[position] = normalized
    return tuple(tokens)


def ci_result_wiring_findings(jobs: dict) -> list[str]:
    errors = []
    def configuration(step):
        value = step.get('with')
        return value if isinstance(value, dict) else {}
    for name, group, condition, producer in (
            ('static-audit', 'modules', CI_NATIVE_EXECUTION, 'Scripts/run-extended-tests.sh verify audit modules'),
            ('release-build', 'release', CI_EXECUTION, 'Scripts/run-extended-tests.sh build icloud-smoke'),
            ('catalyst-tests', 'catalyst', CI_EXECUTION, 'Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime'),
            ('ios-tests', 'ios', '${{ fromJSON(env.BIT101_CI_PLAN).jobs.app.execute || fromJSON(env.BIT101_CI_PLAN).jobs.ui.execute }}',
                'Scripts/run-extended-tests.sh simulator merge')):
        job = jobs.get(name)
        steps = job.get('steps', []) if isinstance(job, dict) else []
        steps = [step for step in steps if isinstance(step, dict)] if isinstance(steps, list) else []
        exports = [step for step in steps if command_matches(step.get('run'), 'python3 Scripts/ci_evidence.py export-result ' + group)]
        uploads = [step for step in steps if configuration(step).get('name') == 'verified-result-' + group]
        producers = [step for step in steps if command_matches(step.get('run'), producer)]
        if len(exports) != 1 or len(uploads) != 1 or len(producers) != 1:
            errors.append(f'.github/workflows/ci.yml: {name} 需要独立的完整成功记录')
            continue
        export, upload = exports[0], uploads[0]
        settings = configuration(upload)
        if not steps.index(producers[0]) < steps.index(export) < steps.index(upload) \
                or any(step.get('if') != condition or step.get('continue-on-error', False) for step in (export, upload)) \
                or not str(upload.get('uses', '')).startswith('actions/upload-artifact@') \
                or settings.get('path') != '.build/extended-automation/ci-validation-result.json' \
                or settings.get('compression-level') != 0 or settings.get('overwrite') is not True \
                or settings.get('include-hidden-files') is not True or settings.get('if-no-files-found') != 'error':
            errors.append(f'.github/workflows/ci.yml: {name} 的完整成功记录需要绑定实际验收与固定产物')
    return errors


def ci_wiring_findings(workflow_source: str) -> list[str]:
    errors: list[str] = []
    try:
        # YAML 1.1 将裸 on 识别为布尔值；保留 GitHub 工作流的事件键。
        source = re.sub(r'(?m)^on(?=\s*:)', '"on"', workflow_source)
        parsed = subprocess.run(
            ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))"],
            input=source, capture_output=True, text=True, check=True,
        )
        workflow = json.loads(parsed.stdout)
        if not isinstance(workflow, dict): raise ValueError("工作流需要映射")
    except (OSError, subprocess.CalledProcessError, ValueError):
        return [".github/workflows/ci.yml: CI 工作流需要有效 YAML"]

    def mapping(value):
        return value if isinstance(value, dict) else {}

    cancellation = mapping(workflow.get('concurrency')).get('cancel-in-progress')
    concurrency_group = mapping(workflow.get('concurrency')).get('group')
    if runner_expression(concurrency_group) != runner_expression(CI_CONCURRENCY_GROUP) \
            or cancellation is not False and runner_expression(cancellation) != runner_expression(CI_CANCELLATION):
        errors.append('.github/workflows/ci.yml: 发布真机需要独立并发组保留完整恢复时间，常规托管验证自动取消同分支旧运行')

    def shell(step):
        value = mapping(step).get('run', '')
        return value if isinstance(value, str) else ''

    def step_has_role(step, role):
        step = mapping(step)
        if role == 'Verify maintainer review commit': return step.get('id') == 'review'
        artifacts = {'Preserve native compilation cache': 'compilation-cache-',
            'Preserve shared UI test host': 'ui-test-host',
            'Preserve validation diagnostics': 'validation-${{ github.job }}',
            'Preserve App validation diagnostics': 'validation-ios-test-shards-app-0'}
        if role in artifacts:
            name = str(mapping(step.get('with')).get('name', ''))
            return str(step.get('uses', '')).startswith('actions/upload-artifact@') \
                and (name == artifacts[role] if role in {'Preserve shared UI test host', 'Preserve App validation diagnostics'}
                    else name.startswith(artifacts[role]))
        commands = {
            'Show toolchain': 'Scripts/build-install-device.sh toolchain',
            'Reuse compatible successful validation': 'python3 Scripts/ci_evidence.py reuse',
            'Run static audit': 'Scripts/run-static-audit.sh',
            'Check current CI results': 'python3 Scripts/ci_evidence.py current',
            'Download release validation evidence': 'python3 Scripts/ci_evidence.py release',
            'Load target branch coverage baseline': 'python3 Scripts/ci_evidence.py baseline',
            'Restore native compilation cache': 'python3 Scripts/ci_evidence.py cache-restore',
            'Prepare native compilation cache': 'python3 Scripts/ci_evidence.py cache-export',
            'Prepare full iOS Simulator': 'Scripts/run-extended-tests.sh simulator prepare',
            'Run assigned complete Simulator inventory': 'Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"',
            'Run complete App behavior inventory': 'Scripts/run-extended-tests.sh simulator app',
            'Restore shared UI test host': 'gh run download "$GITHUB_RUN_ID" --name ui-test-host',
            'Build complete UI test host': 'Scripts/run-extended-tests.sh simulator build-ui',
        }
        if role not in commands: return False
        expected = shlex.split(commands[role])
        try:
            return any(shlex.split(line, comments=True)[:len(expected)] == expected
                for line in shell(step).replace('\\\n', ' ').splitlines())
        except ValueError: return False

    events = workflow.get("on", {})
    events = {events} if isinstance(events, str) else events if isinstance(events, (list, dict)) else {}
    if not {"pull_request", "push"}.issubset(events):
        errors.append(".github/workflows/ci.yml: CI 需要 pull_request 和 push 自动触发")
    for event in ("pull_request", "push"):
        if {"paths", "paths-ignore"} & mapping(mapping(workflow.get("on")).get(event)).keys():
            errors.append(f".github/workflows/ci.yml: {event} 需要覆盖全部仓库路径")
    pull = mapping(mapping(workflow.get('on')).get('pull_request'))
    if {'branches', 'branches-ignore'} & pull.keys() or 'types' in pull and (
            not isinstance(pull['types'], list) or not all(isinstance(item, str) for item in pull['types'])
            or not {'opened', 'synchronize', 'reopened'} <= set(pull['types'])):
        errors.append('.github/workflows/ci.yml: pull_request 需要覆盖全部目标分支及打开、更新、重新打开事件')
    push = mapping(mapping(workflow.get('on')).get('push'))
    if push.get('branches') != ['main'] or 'branches-ignore' in push:
        errors.append('.github/workflows/ci.yml: push 需要覆盖 main 分支更新')
    jobs = mapping(workflow.get("jobs"))
    errors.extend(ci_result_wiring_findings(jobs))
    for name, job in jobs.items():
        for step in mapping(job).get('steps', []):
            action = str(mapping(step).get('uses', ''))
            if action and not action.startswith(('./', 'docker://')) and not re.fullmatch(r'[^@]+@[0-9a-f]{40}', action):
                errors.append(f'.github/workflows/ci.yml: {name} 的外部 Action 需要固定完整提交 SHA')
        if name != 'physical-device' and runner_expression(mapping(job).get('runs-on')) != runner_expression(CI_RUNNER):
            errors.append(f'.github/workflows/ci.yml: {name} 的隔离运行器需要使用 GitHub 托管的 xcode-27 镜像')
        checkouts = [step for step in mapping(job).get('steps', []) if isinstance(step, dict)
            and str(step.get('uses', '')).startswith('actions/checkout@')]
        if len(checkouts) != 1 or mapping(checkouts[0].get('with')).get('clean') is not False:
            errors.append(f'.github/workflows/ci.yml: {name} 的 checkout 需要保留公共缓存')
        if len(checkouts) != 1 or 'if' in checkouts[0] \
                or checkouts[0].get('continue-on-error', False) is not False \
                or mapping(checkouts[0].get('with')).get('fetch-depth') != 0 \
                or mapping(checkouts[0].get('with')).get('ref', '${{ github.sha }}') != '${{ github.sha }}':
            errors.append(f'.github/workflows/ci.yml: {name} 的检出需要默认执行、完整提交历史及失败传播')
        if name in DIAGNOSTIC_PATHS:
            uploads = [step for step in mapping(job).get('steps', []) if isinstance(step, dict)
                and str(step.get('uses', '')).startswith('actions/upload-artifact@') and step_has_role(step, 'Preserve validation diagnostics')]
            if len(uploads) != 1 or set(diagnostic_path_list(mapping(job).get('steps', []), uploads[0]).splitlines()) != DIAGNOSTIC_PATHS[name]:
                errors.append(f'.github/workflows/ci.yml: {name} 的诊断上传需要采用所属任务的文件清单，人工附件保留在本地')
            diagnostic_condition = CI_DIAGNOSTICS if name in CI_PLANNED_GROUPS else '${{ always() }}'
            if len(uploads) != 1 or uploads[0].get('if') != diagnostic_condition \
                    or mapping(uploads[0].get('with')).get('compression-level') != 0 \
                    or mapping(uploads[0].get('with')).get('include-hidden-files') is not True \
                    or mapping(uploads[0].get('with')).get('overwrite') is not True:
                errors.append(f'.github/workflows/ci.yml: {name} 的诊断上传需要始终保存原始文件及隐藏路径')
    planner = mapping(jobs.get('validation-plan'))
    plan_steps = [step for step in planner.get('steps', []) if step.get('id') == 'plan']
    if planner.get('if') != CI_NATIVE_CONTEXT or planner.get('needs', []) != [] or planner.get('continue-on-error', False) is not False \
            or len(plan_steps) != 1 or not command_matches(str(plan_steps[0].get('run') or ""), 'python3 Scripts/ci_evidence.py plan') \
            or 'if' in plan_steps[0] or plan_steps[0].get('continue-on-error', False) is not False \
            or mapping(plan_steps[0].get('env')).get('GH_TOKEN') != '${{ github.token }}' \
            or mapping(plan_steps[0].get('env')).get('BIT101_FULL_CHECK') != '${{ github.event_name == \'workflow_dispatch\' && inputs.full_check }}' \
            or mapping(plan_steps[0].get('env')).get('BIT101_RELEASE_CHECK') != '${{ github.event_name == \'workflow_dispatch\' && inputs.release_check }}' \
            or mapping(planner.get('outputs')).get('plan') != '${{ steps.plan.outputs.plan }}':
        errors.append('.github/workflows/ci.yml: 验证计划需要绑定手动全量、发布上下文与任务输出')
    for name, group in (CI_PLANNED_GROUPS | {'static-audit': 'modules'}).items():
        job = mapping(jobs.get(name))
        environment = mapping(job.get('env'))
        reuse = [step for step in job.get('steps', []) if step_has_role(step, 'Reuse compatible successful validation')]
        if environment.get('BIT101_CI_PLAN') != '${{ needs.validation-plan.outputs.plan }}' \
                or environment.get('BIT101_CI_GROUP') != group or len(reuse) != 1 \
                or reuse[0].get('if') != (CI_NATIVE_REUSE if name == 'static-audit' else '${{ !' + CI_EXECUTE + ' }}') \
                or not command_matches(str(reuse[0].get('run') or ""), 'python3 Scripts/ci_evidence.py reuse "$BIT101_CI_GROUP"') \
                or reuse[0].get('continue-on-error', False) is not False:
            errors.append(f'.github/workflows/ci.yml: {name} 需要采用所属输入计划并展示成功结果来源')
    if mapping(mapping(jobs.get('ios-tests')).get('env')).get('BIT101_CI_PLAN') != '${{ needs.validation-plan.outputs.plan }}':
        errors.append('.github/workflows/ci.yml: 分片汇总需要核对增量计划中的来源提交与运行')
    workflow_defaults = mapping(mapping(workflow.get("defaults")).get("run"))
    default_shell = workflow_defaults.get("shell", "bash")

    def run_commands(job, *, include_always=False):
        commands = []
        job_defaults = mapping(mapping(job.get("defaults")).get("run"))
        shell = job_defaults.get("shell", default_shell)
        directory = job_defaults.get("working-directory", workflow_defaults.get("working-directory", "."))
        steps = job.get("steps", [])
        for step in steps if isinstance(steps, list) else []:
            step = mapping(step)
            if "run" not in step: continue
            if not isinstance(step['run'], str):
                errors.append('.github/workflows/ci.yml: 执行步骤需要 shell 文本')
                continue
            step = dict(step, **{"working-directory": step.get("working-directory", directory)})
            expected_directory = "Cloudflare/EmergencyUpdateWorker" if command_matches(step["run"], "npm ci") else "."
            if step["working-directory"] != expected_directory:
                errors.append(".github/workflows/ci.yml: 执行步骤需要沿所属仓库目录运行")
                continue
            if step.get("shell", shell) != "bash":
                errors.append(".github/workflows/ci.yml: CI 执行步骤需要 bash shell")
                continue
            planned = mapping(job.get('env')).get('BIT101_CI_GROUP') in {*CI_PLANNED_GROUPS.values(), 'modules'}
            conditions = {CI_EXECUTION} if planned else set()
            if job is jobs.get('static-audit'):
                conditions.update({CI_NATIVE_EXECUTION, CI_NATIVE_REUSE, CI_STATIC_EXECUTION, CI_NATIVE_CONTEXT})
            if include_always: conditions.update({'always()', '${{ always() }}', '${{ !cancelled() }}',
                '${{ !cancelled() && ' + CI_EXECUTE + ' }}', CI_DIAGNOSTICS})
            if planned and mapping(job.get('env')).get('BIT101_CI_GROUP') != 'modules' \
                    and not step_has_role(step, 'Show toolchain') and step.get('if') not in conditions: continue
            if "if" in step and step['if'] not in conditions \
                    or step.get("continue-on-error", False) is not False: continue
            command = step["run"]
            if isinstance(command, str): commands.append((command.strip(), step))
        return commands

    if not any(command_matches(command, 'python3 Scripts/ci_evidence.py plan') for command, _ in run_commands(planner)):
        errors.append('.github/workflows/ci.yml: 增量计划需要沿默认 shell 执行并传播失败')

    commands = {}
    for name in ("static-audit", "release-build", "catalyst-tests", "ios-tests", "ios-test-shards", "ios-app-tests", "ios-ui-build"):
        job = mapping(jobs.get(name))
        if not job:
            errors.append(f".github/workflows/ci.yml: CI 缺少 {name} Job")
            continue
        expected_gate = CI_STATIC_GATE if name == 'static-audit' else CI_NATIVE_CONTEXT
        if job.get('if') != expected_gate or job.get("continue-on-error", False) is not False:
            errors.append(f".github/workflows/ci.yml: {name} 需要按静态与手动全量、发布范围执行并传播失败")
        commands[name] = run_commands(job)
        if not any(command_matches(command, "Scripts/build-install-device.sh toolchain") for command, _ in commands[name]):
            errors.append(f".github/workflows/ci.yml: {name} 的工具链版本核对需要共用构建脚本入口")
        if name not in {'ios-tests', 'ios-test-shards', 'ios-app-tests', 'ios-ui-build'} and not any(command_matches(command, "python3 Scripts/validation_evidence.py summary --recorded-environment")
                for command, _ in run_commands(job, include_always=True)):
            errors.append(f".github/workflows/ci.yml: {name} 的证据汇总需要采用记录环境")
        expected_dependencies = ['validation-plan', *{'ios-tests': ['static-audit', 'ios-test-shards', 'ios-app-tests'],
            'catalyst-tests': ['release-build', 'static-audit'],
            'ios-test-shards': ['ios-ui-build']}.get(name, [])]
        if job.get('needs', []) != expected_dependencies:
            errors.append(f'.github/workflows/ci.yml: {name} 需要按独立执行与最终汇总的依赖图运行')
    static_commands = commands.get("static-audit", [])
    audit_index = next((index for index, (command, _) in enumerate(static_commands) if command_matches(command, "Scripts/run-extended-tests.sh verify audit modules")), -1)
    setup_index = next((index for index, (command, step) in enumerate(static_commands)
                        if command_matches(command, "npm ci") and step.get("working-directory") == "Cloudflare/EmergencyUpdateWorker"), -1)
    if audit_index < 0: errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    audit_only = [step for step in mapping(jobs.get('static-audit')).get('steps', []) if step_has_role(step, 'Run static audit')]
    if len(audit_only) != 1 or not command_matches(str(audit_only[0].get('run') or ""), 'Scripts/run-static-audit.sh') \
            or audit_only[0].get('if') != CI_STATIC_EXECUTION \
            or audit_only[0].get('continue-on-error', False) is not False \
            or not any(command_matches(command, 'Scripts/run-static-audit.sh') for command, _ in static_commands) \
            or audit_index >= 0 and (static_commands[audit_index][1].get('if') != CI_NATIVE_EXECUTION \
                or mapping(audit_only[0].get('env')) != mapping(static_commands[audit_index][1].get('env'))):
        errors.append('.github/workflows/ci.yml: 推送与 PR 需要执行静态审计，模块测试限定在手动全量和发布流程')
    release_expression = "${{ github.event_name == 'workflow_dispatch' && inputs.release_check }}"
    if audit_index >= 0 and mapping(static_commands[audit_index][1].get('env')).get('BIT101_RELEASE_CHECK') != release_expression:
        errors.append('.github/workflows/ci.yml: 手动上传预检需要 App Store 版本前进核对')
    if setup_index < 0 or audit_index < 0 or setup_index >= audit_index:
        errors.append(".github/workflows/ci.yml: Worker 锁定依赖需要在静态审计前安装并传播失败")
    required = {
        "static-audit": (("Scripts/run-extended-tests.sh verify audit modules", "静态审计与模块行为测试需要沿聚合入口执行并传播失败"),),
        "catalyst-tests": (
            ("Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime", "Mac Catalyst 行为 Job 需要聚合执行行为用例和正式组装合同"),
        ),
        "release-build": (
            ("Scripts/build-install-device.sh archive", "CI 需要正式归档编译模式验证"),
            ("Scripts/run-extended-tests.sh build network-smoke", "CI 需要网络 Smoke 编译条件构建"),
            ("Scripts/run-extended-tests.sh build icloud-smoke", "CI 需要 iCloud Smoke 编译条件构建"),
        ),
        "ios-tests": (("Scripts/run-extended-tests.sh simulator merge", "模拟器 Job 需要汇总完整库存及覆盖率"),),
        "ios-ui-build": (("Scripts/run-extended-tests.sh simulator build-ui", "UI 测试宿主需要沿共享构建入口生成"),),
        "ios-test-shards": (("Scripts/run-extended-tests.sh simulator prepare", "模拟器分片需要准备完整模拟器"),
            ('Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"', "模拟器分片需要执行完整分配库存")),
        "ios-app-tests": (("Scripts/run-extended-tests.sh simulator prepare", "正式组装需要准备完整模拟器"),
            ("Scripts/run-extended-tests.sh simulator app", "App 行为需要执行完整合同库存"),
            ("Scripts/run-extended-tests.sh simulator release-runtime", "正式组装需要执行完整合同库存")),
    }
    for name, rules in required.items():
        executed = {command for command, _ in commands.get(name, [])}
        for marker, message in rules:
            if not any(command_matches(command, marker) for command in executed): errors.append(f".github/workflows/ci.yml: {message}")
    if not isinstance(workflow.get("on"), dict) or "v*" not in mapping(workflow["on"].get("push")).get("tags", []):
        errors.append(".github/workflows/ci.yml: 发布版本标签需要触发验收")
    acceptance = mapping(jobs.get("release-acceptance"))
    condition = "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inputs.release_check"
    if acceptance.get("if") != condition or set(acceptance.get("needs", [])) != {"static-audit", "release-build", "catalyst-tests", "ios-tests", "physical-device"} \
            or acceptance.get('continue-on-error', False) is not False:
        errors.append(".github/workflows/ci.yml: 发布验收需要承接完整编译和行为 Job")
    if not any(command_matches(command, "python3 Scripts/ci_evidence.py check-release") for command, _ in run_commands(acceptance)):
        errors.append(".github/workflows/ci.yml: 发布验收需要默认核对提交绑定证据")
    merge = mapping(jobs.get("merge-acceptance"))
    if merge.get("if") != "always() && !cancelled()" \
            or set(merge.get("needs", [])) != {"validation-plan", "static-audit", "release-build", "catalyst-tests", "ios-tests"} \
            or merge.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 最终验收需要按所选范围核对静态、编译、Catalyst 与完整模拟器 Job")
    result_steps = [step for step in merge.get('steps', []) if step_has_role(step, 'Check current CI results')]
    if len(result_steps) != 1 or mapping(result_steps[0].get('env')).get('BIT101_NATIVE_CHECK') != '${{ ' + CI_NATIVE_CONTEXT + ' }}':
        errors.append('.github/workflows/ci.yml: 最终验收需要绑定静态与完整验收范围')
    for name, command in (('static-audit', 'Scripts/run-extended-tests.sh verify audit modules'),
                          ('catalyst-tests', 'Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime'),
                          ('ios-tests', 'Scripts/run-extended-tests.sh simulator merge'),
                          ('ios-app-tests', 'Scripts/run-extended-tests.sh simulator app'),
                          ('ios-test-shards', 'Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"')):
        steps = mapping(jobs.get(name)).get('steps', [])
        baseline_index = next((index for index, step in enumerate(steps) if isinstance(step, dict) and step_has_role(step, 'Load target branch coverage baseline')), -1)
        execution_index = next((index for index, step in enumerate(steps) if isinstance(step, dict) and command_matches(str(step.get('run', '')), command)), -1)
        if not 0 <= baseline_index < execution_index:
            errors.append(f'.github/workflows/ci.yml: {name} 基准载入需要先于当前分组记录')
    physical = mapping(jobs.get("physical-device"))
    if physical.get("if") != condition or physical.get("needs", []) != [] \
            or runner_expression(physical.get("runs-on")) != runner_expression(["self-hosted", "macOS", "bit101-xcode-27", "bit101-device"]) \
            or type(physical.get("timeout-minutes")) is not int \
            or physical['timeout-minutes'] < workflow_timeout_seconds(('modules', 'all', 'release-runtime', 'ui')) // 60 + 10 \
            or physical.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 真机 Job 需要发布入口、实体设备运行器与审计并行的依赖图")
    simulator = mapping(jobs.get('ios-tests'))
    shard_job = mapping(jobs.get('ios-test-shards'))
    formal_job = mapping(jobs.get('ios-app-tests'))
    for job in (simulator, shard_job, formal_job):
        if mapping(job.get('env')).get('BIT101_SIMULATOR_AUTHORIZED') != '1' \
                or any('BIT101_SIMULATOR_AUTHORIZED' in mapping(step.get('env'))
                    for step in job.get('steps', []) if isinstance(step, dict)):
            errors.append('.github/workflows/ci.yml: 完整模拟器 CI 需要统一显式授权标记')
    from validation_coverage import SIMULATOR_SHARDS, SIMULATOR_WORKERS
    expected_matrix = [{'mode': 'app' if group == 'all' else group, 'shard': index, 'count': count, 'workers': SIMULATOR_WORKERS['app' if group == 'all' else group]}
        for group, count in SIMULATOR_SHARDS.items() if group == 'ui' for index in range(count)]
    strategy = mapping(shard_job.get('strategy'))
    actual_matrix = mapping(strategy.get('matrix')).get('include', [])
    canonical = lambda rows: sorted(json.dumps(row, sort_keys=True) for row in rows)
    if strategy.get('max-parallel') != 3 or strategy.get('fail-fast') is not False or canonical(actual_matrix) != canonical(expected_matrix) \
            or mapping(shard_job.get('env')).get('BIT101_CI_SHARD') != '${{ matrix.shard }}/${{ matrix.count }}' \
            or mapping(shard_job.get('env')).get('BIT101_SIMULATOR_WORKERS') != '${{ matrix.workers }}':
        errors.append('.github/workflows/ci.yml: 模拟器完整 UI 库存需要精确分片、全部执行及统一身份')
    if mapping(formal_job.get('env')).get('BIT101_CI_SHARD') != f"0/{SIMULATOR_SHARDS['release-runtime']}" \
            or mapping(formal_job.get('env')).get('BIT101_SIMULATOR_WORKERS') != str(SIMULATOR_WORKERS['release-runtime']) \
            or 'strategy' in formal_job:
        errors.append('.github/workflows/ci.yml: App 与正式组装需要共用完整库存和单个工作进程')
    app_steps = formal_job.get('steps', [])
    app_run = next((i for i, step in enumerate(app_steps) if command_matches(str(step.get('run') or ""), 'Scripts/run-extended-tests.sh simulator app')), -1)
    formal_run = next((i for i, step in enumerate(app_steps) if command_matches(str(step.get('run') or ""), 'Scripts/run-extended-tests.sh simulator release-runtime')), -1)
    app_upload = [step for step in app_steps if step_has_role(step, 'Preserve App validation diagnostics')]
    if len(app_upload) != 1 or not 0 <= app_run < app_steps.index(app_upload[0]) < formal_run \
            or app_upload[0].get('if') != CI_DIAGNOSTICS \
            or not str(app_upload[0].get('uses', '')).startswith('actions/upload-artifact@') \
            or any(mapping(app_upload[0].get('with')).get(key) != value for key, value in {
                'name': 'validation-ios-test-shards-app-0', 'compression-level': 0, 'include-hidden-files': True, 'overwrite': True}.items()) \
            or set(diagnostic_path_list(app_steps, app_upload[0]).splitlines()) != DIAGNOSTIC_PATHS['ios-app-tests']:
        errors.append('.github/workflows/ci.yml: 同设备正式组装前需要顺序执行 App 库存并保留原始诊断上传')
    for job, groups in (('static-audit', ('audit', 'modules')),
            ('release-build', ('build-archive', 'network', 'icloud')),
            ('catalyst-tests', ('catalyst', 'catalyst-release-runtime'))):
        timeout = mapping(jobs.get(job)).get('timeout-minutes')
        if type(timeout) is not int or timeout < workflow_timeout_seconds(groups) // 60 + 10:
            errors.append(f'.github/workflows/ci.yml: {job} Job 需要覆盖所属执行及恢复预算')
    for job, minimum in (('ios-test-shards', workflow_timeout_seconds(('ui',)) // 60 + 10),
            ('ios-app-tests', workflow_timeout_seconds(('all', 'release-runtime')) // 60 + 10), ('ios-tests', 10)):
        timeout = mapping(jobs.get(job)).get('timeout-minutes')
        if type(timeout) is not int or timeout < minimum:
            errors.append(f'.github/workflows/ci.yml: {job} Job 需要覆盖所属执行及恢复预算')
    physical_commands = {command for command, _ in run_commands(physical, include_always=True)}
    if any(not any(command_matches(command, marker) for command in physical_commands) for marker in (
            "Scripts/run-extended-tests.sh verify modules all release-runtime ui",
            "python3 Scripts/validation_evidence.py bind-merge", "python3 Scripts/ci_evidence.py export-core")):
        errors.append(".github/workflows/ci.yml: 真机 Job 需要执行、恢复并绑定完整验收")
    publishers = [step for step in physical.get("steps", []) if isinstance(step, dict)
        and re.fullmatch(r"actions/upload-artifact@(?:v[1-9]\d*(?:\.\d+){0,2}|[0-9a-f]{40})", str(step.get("uses", ""))) and mapping(step.get("with")).get("name") == "validation-evidence"]
    if len(publishers) != 1 or publishers[0].get("if") != "always()" \
            or any(mapping(publishers[0].get("with")).get(key) != value for key, value in {"name": "validation-evidence",
                "path": ".build/extended-automation/core-validation-evidence.json", "compression-level": 0,
                "overwrite": True, "if-no-files-found": "error", "include-hidden-files": True}.items()):
        errors.append(".github/workflows/ci.yml: 真机证据需要固定产物发布与完整诊断保留")
    if mapping(workflow.get("permissions")).get("actions") != "read":
        errors.append(".github/workflows/ci.yml: 提交证据读取需要 Actions 读取权限")
    cache_condition = "${{ github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')"
    for name, flavor in {'release-build': 'release-build', 'catalyst-tests': 'catalyst-tests',
            'ios-ui-build': 'simulator-ui', 'ios-app-tests': 'simulator-app'}.items():
        steps = mapping(jobs.get(name)).get('steps', [])
        restore = [step for step in steps if step_has_role(step, 'Restore native compilation cache')]
        prepare = [step for step in steps if step_has_role(step, 'Prepare native compilation cache')]
        save = [step for step in steps if step_has_role(step, 'Preserve native compilation cache')]
        condition = '${{ (' + cache_condition.removeprefix('${{ ') + ') && ' + CI_EXECUTE + ' }}'
        if len(restore) != 1 or not command_matches(str(restore[0].get('run') or ""), f'python3 Scripts/ci_evidence.py cache-restore "{flavor}"') \
                or restore[0].get('if') != CI_EXECUTION or mapping(restore[0].get('env')).get('GH_TOKEN') != '${{ github.token }}':
            errors.append(f'.github/workflows/ci.yml: {name} 需要实际恢复所属原生编译缓存')
        if name == 'ios-app-tests':
            boot = [step for step in steps if step_has_role(step, 'Prepare full iOS Simulator')]
            network = [step for step in steps if any(step_has_role(step, role) for role in {'Restore native compilation cache', 'Load target branch coverage baseline'})]
            inventory = [step for step in steps if step_has_role(step, 'Run assigned complete Simulator inventory' if name == 'ios-test-shards' else 'Run complete App behavior inventory')]
            if len(boot) != 1 or not command_matches(str(boot[0].get('run') or ""), 'Scripts/run-extended-tests.sh simulator prepare') \
                    or len(network) != 2 or len(inventory) != 1 \
                    or not max(map(steps.index, network)) < steps.index(boot[0]) < steps.index(inventory[0]):
                errors.append(f'.github/workflows/ci.yml: {name} 需要完成缓存与基准请求后启动完整模拟器，再执行测试库存')
        if len(prepare) != 1 or prepare[0].get('if') != condition \
                or not command_matches(str(prepare[0].get('run') or ""), f'python3 Scripts/ci_evidence.py cache-export "{flavor}"') \
                or len(save) != 1 or save[0].get('if') != condition:
            errors.append(f'.github/workflows/ci.yml: {name} 的缓存发布需要来自 main 运行及唯一生产者')
        if len(save) == 1 and any(mapping(save[0].get('with')).get(key) != value for key, value in {
                'name': 'compilation-cache-' + flavor, 'compression-level': 0, 'overwrite': True,
                'include-hidden-files': True, 'if-no-files-found': 'error',
                'path': '.build/compiler-cache/CompilationCache.noindex\n.build/compiler-cache/compilation-cache.json\n.build/compiler-cache/swift-syntax-indexer\n.build/compiler-cache/swift-syntax-indexer-inputs.json\n'}.items()):
            errors.append(f'.github/workflows/ci.yml: {name} 需要沿固定目录零压缩保存原生缓存')
        if len(save) == 1 and save[0].get('continue-on-error') is not True:
            errors.append(f'.github/workflows/ci.yml: {name} 的缓存上传需要独立于验证结果')
    host = mapping(jobs.get('ios-ui-build'))
    host_upload = [step for step in host.get('steps', []) if step_has_role(step, 'Preserve shared UI test host')]
    if len(host_upload) != 1 or not re.fullmatch(r'actions/upload-artifact@[0-9a-f]{40}', str(host_upload[0].get('uses', ''))) \
            or any(mapping(host_upload[0].get('with')).get(key) != value for key, value in {
                'name': 'ui-test-host', 'compression-level': 0, 'include-hidden-files': True,
                'if-no-files-found': 'error', 'retention-days': 1,
                'path': '${{ steps.ui-host.outputs.paths }}'}.items()):
        errors.append('.github/workflows/ci.yml: UI 宿主需要完整保存运行产物、索引工具及编译条件缓存')
    selected_host = [step for step in host.get('steps', []) if step.get('id') == 'ui-host']
    if len(selected_host) != 1 or not command_matches(str(selected_host[0].get('run') or ''),
            'python3 Scripts/test_results.py ui-host-paths .build/extended-automation/Build/Products') \
            or selected_host[0].get('if') != CI_EXECUTION or len(host_upload) != 1 \
            or host['steps'].index(selected_host[0]) >= host['steps'].index(host_upload[0]):
        errors.append('.github/workflows/ci.yml: UI 宿主需要先按当前运行配置选择传输产物')
    shard_steps = shard_job.get('steps', [])
    download = [step for step in shard_steps if step_has_role(step, 'Restore shared UI test host')]
    if mapping(shard_job.get('env')).get('BIT101_REUSE_UI_HOST') != '1' or len(download) != 1 \
            or not command_matches(str(download[0].get('run') or ""), 'gh run download "$GITHUB_RUN_ID" --name ui-test-host --dir .build') \
            or mapping(download[0].get('env')).get('GH_TOKEN') != '${{ github.token }}' \
            or any(any(step_has_role(step, role) for role in {'Restore native compilation cache', 'Prepare native compilation cache',
                'Preserve native compilation cache'}) for step in shard_steps):
        errors.append('.github/workflows/ci.yml: UI 分组需要复用当前运行的共享宿主及唯一缓存生产者')
    boot = next((i for i, step in enumerate(shard_steps) if step_has_role(step, 'Prepare full iOS Simulator')), -1)
    baseline = next((i for i, step in enumerate(shard_steps) if step_has_role(step, 'Load target branch coverage baseline')), -1)
    if len(download) == 1 and not shard_steps.index(download[0]) < baseline < boot:
        errors.append('.github/workflows/ci.yml: UI 分组需要在宿主与基准读取完成后启动模拟器')
    cleanup = mapping(jobs.get('compiler-cache-cleanup'))
    if cleanup.get('if') != "${{ always() && github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch' && (inputs.full_check || inputs.release_check) }}" \
            or mapping(cleanup.get('permissions')) != {'contents': 'read', 'actions': 'write'} \
            or cleanup.get('needs') != ['release-build', 'catalyst-tests', 'ios-ui-build', 'ios-test-shards', 'ios-app-tests', 'ios-tests'] \
            or not any(command_matches(str(step.get('run') or ""), 'python3 Scripts/ci_evidence.py cache-prune') for step in cleanup.get('steps', [])):
        errors.append('.github/workflows/ci.yml: 缓存替换需要 main 专用的清理任务')
    if any(mapping(job.get('permissions')).get('actions', 'read') != 'read' for name, job in jobs.items() if name != 'compiler-cache-cleanup'):
        errors.append('.github/workflows/ci.yml: 验证任务沿 Actions 读取权限执行')
    baseline_command = 'python3 Scripts/ci_evidence.py baseline "$BIT101_BASE_COMMIT"'
    for job, step_name, key, expression, expected in (
            (acceptance, "Download release validation evidence", "BIT101_RELEASE_TAG", "${{ inputs.validation_tag || github.ref_name }}",
                ["Scripts/ci_evidence.py", "release", "fixture"]),
            (merge, "Check current CI results", "BIT101_REQUIRED_RESULTS", "${{ toJSON(needs) }}",
                ["Scripts/ci_evidence.py", "current", "--results", "fixture"]),
            (mapping(jobs.get("static-audit")), "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (mapping(jobs.get("catalyst-tests")), "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (simulator, "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (shard_job, "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (formal_job, "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (physical, "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"])):
        candidates = [step for step in job.get("steps", []) if isinstance(step, dict) and step_has_role(step, step_name)]
        if len(candidates) != 1 or mapping(candidates[0].get("env")).get(key) != expression \
                or mapping(candidates[0].get("env")).get("GH_TOKEN") != "${{ github.token }}":
            errors.append(".github/workflows/ci.yml: 合并与覆盖率证据请求需要所属提交身份")
            continue
        expected_condition = CI_EXECUTION if mapping(job.get('env')).get('BIT101_CI_GROUP') in CI_PLANNED_GROUPS.values() else None
        if job is jobs.get('static-audit'): expected_condition = CI_NATIVE_CONTEXT
        if step_name == 'Load target branch coverage baseline' and candidates[0].get('if') != expected_condition:
            errors.append('.github/workflows/ci.yml: 每个执行入口需要设置所属覆盖率基准')
        step = candidates[0]
        if step.get("continue-on-error", False) is not False or step.get("if") != expected_condition:
            errors.append(".github/workflows/ci.yml: 提交证据读取失败需要传播")
        errors.extend(evidence_execution_findings(shell(step), key, expected))
    steps = physical.get("steps", [])
    exports = [step for step in steps if isinstance(step, dict) and command_matches(str(step.get('run') or ""), 'python3 Scripts/ci_evidence.py export-core')]
    if len(exports) != 1 or exports[0].get('if') != 'always()' or not publishers \
            or steps.index(exports[0]) >= steps.index(publishers[0]):
        errors.append('.github/workflows/ci.yml: CI 交换需要先导出核心验证组，保留完整人工证明在本地')
    diagnostics = [step for step in steps if isinstance(step, dict) and step_has_role(step, 'Preserve validation diagnostics')]
    if len(diagnostics) != 1 or diagnostics[0].get('if') != 'always()' \
            or not diagnostics[0].get('uses', '').startswith('actions/upload-artifact@') \
            or mapping(diagnostics[0].get('with')).get('compression-level') != 0 \
            or mapping(diagnostics[0].get('with')).get('include-hidden-files') is not True \
            or set(diagnostic_path_list(steps, diagnostics[0]).splitlines()) != {
                '.build/extended-automation/*.log', '.build/extended-automation/*.txt',
                '.build/extended-automation/test-results.xcresult', '.build/extended-automation/diagnostics/test-results.xcresult'}:
        errors.append('.github/workflows/ci.yml: 真机失败需要保存完整日志与原始 XCTest 附件')
    checkouts = [step for step in steps if isinstance(step, dict) and step.get('uses', '').startswith('actions/checkout@')]
    if len(checkouts) != 1 or mapping(checkouts[0].get('with')).get('clean') is not False:
        errors.append('.github/workflows/ci.yml: 真机工作区需要保留共享增量编译缓存')
    load = next((i for i, step in enumerate(steps) if baseline_command in shell(step)), -1)
    verify = next((i for i, step in enumerate(steps) if isinstance(step, dict) and command_matches(str(step.get("run") or ""), "Scripts/run-extended-tests.sh verify modules all release-runtime ui")), -1)
    bind = next((i for i, step in enumerate(steps) if isinstance(step, dict) and command_matches(str(step.get("run") or ""), "python3 Scripts/validation_evidence.py bind-merge")), -1)
    if not 0 <= load < verify < bind:
        errors.append(".github/workflows/ci.yml: 真机证据需要沿基准、执行和提交绑定顺序生成")
    from validation_policy import REVIEW_JOB_NAMES
    if {mapping(jobs.get(name)).get('name') for name in ('static-audit', 'release-build', 'catalyst-tests', 'ios-tests')} != REVIEW_JOB_NAMES:
        errors.append('.github/workflows/ci.yml: 审查证据需要核对四个实际 Job 名称')
    inputs = mapping(mapping(mapping(workflow.get('on')).get('workflow_dispatch')).get('inputs'))
    full_check = mapping(inputs.get('full_check'))
    if full_check.get('type') != 'boolean' or full_check.get('default') is not False or full_check.get('required') is not False:
        errors.append('.github/workflows/ci.yml: 手动全量验收需要默认关闭的可选布尔输入 full_check')
    if mapping(inputs.get('review_pr')).get('type') != 'number' or mapping(inputs.get('review_pr')).get('default') != 0 \
            or workflow.get('run-name') != "${{ inputs.review_pr && format('iOS CI review PR {0}', inputs.review_pr) || github.ref_name }}":
        errors.append('.github/workflows/ci.yml: fork 审查需要 PR 输入与运行身份')
    for name in ('static-audit', 'catalyst-tests', 'ios-tests', 'ios-test-shards', 'ios-app-tests', 'ios-ui-build', 'physical-device'):
        steps = mapping(jobs.get(name)).get('steps', [])
        review = [(i, step) for i, step in enumerate(steps) if isinstance(step, dict) and step_has_role(step, 'Verify maintainer review commit')]
        next_step = 'Build complete UI test host' if name == 'ios-ui-build' else 'Load target branch coverage baseline'
        baseline = next((i for i, step in enumerate(steps) if isinstance(step, dict) and step_has_role(step, next_step)), -1)
        if len(review) != 1: errors.append('.github/workflows/ci.yml: 审查提交验证需要唯一入口'); continue
        position, step = review[0]
        if position >= baseline or step.get('id') != 'review' or step.get('if') != "github.event_name == 'workflow_dispatch' && inputs.review_pr > 0" \
                or mapping(step.get('env')) != {'GH_TOKEN': '${{ github.token }}', 'BIT101_REVIEW_PR': '${{ inputs.review_pr }}'} \
                or step.get('continue-on-error', False) is not False:
            errors.append('.github/workflows/ci.yml: 审查提交与基准需要沿所属 PR 顺序处理')
        if name == 'static-audit' and any(shell(prior).strip() == 'npm ci' for prior in steps[:position]):
            errors.append('.github/workflows/ci.yml: 审查提交核对需要先于依赖安装')
        errors.extend(review_execution_findings(shell(step)))
    return errors


@cache
def review_execution_findings(command: str) -> tuple[str, ...]:
    harness = 'python3() { printf "%s\\0" "$@" >&2; [[ "$fail_at" == 0 ]] || return 73; printf "fixture-base"; };\n'
    for failure in ('0', '1'):
        env = dict(os.environ, BIT101_REVIEW_PR='12', GITHUB_OUTPUT='/dev/stdout', fail_at=failure)
        result = subprocess.run(['bash', '-eo', 'pipefail', '-c', harness + command], env=env, capture_output=True, text=True)
        if result.stderr.split('\0')[:-1] != ['Scripts/ci_evidence.py', 'review-pr', '12'] \
                or result.returncode != (73 if failure == '1' else 0) \
                or result.stdout != ('' if failure == '1' else 'base_sha=fixture-base\n'):
            return ('.github/workflows/ci.yml: 审查需要核对原 PR 合并提交并传播失败',)
    return ()


def evidence_execution_findings(command: str, key: str, expected: list[str]) -> list[str]:
    return list(_evidence_execution_findings(command, key, tuple(expected)))


@cache
def _evidence_execution_findings(command: str, key: str, expected: tuple[str, ...]) -> tuple[str, ...]:
    harness = 'call=0; python3() { ((call+=1)); printf "%s\\0" "$@"; [[ "$call" != "$fail_at" ]] || return 73; return 0; };\n'
    environment = dict(os.environ, **{key: "fixture", "fail_at": "0"})
    result = subprocess.run(["bash", "-eo", "pipefail", "-c", harness + command], env=environment, capture_output=True, text=True)
    if result.returncode or tuple(result.stdout.split("\0")[:-1]) != expected:
        return (".github/workflows/ci.yml: 证据交换需要所属提交或运行的完整命令",)
    for index in range(1, sum(argument.endswith('.py') for argument in expected) + 1):
        failed = subprocess.run(["bash", "-eo", "pipefail", "-c", harness + command],
            env=dict(environment, fail_at=str(index)), capture_output=True, text=True)
        if failed.returncode != 73:
            return (".github/workflows/ci.yml: 证据交换失败需要结束所属步骤",)
    return ()


def ci_trigger_shell_self_test(workflow_source: str) -> list[str]:
    source = workflow_source
    for name in ('validation-plan', *CI_PLANNED_GROUPS, 'ios-tests'):
        block = re.search(r'(?ms)^  ' + name + r':\n.*?(?=^  [\w-]+:|\Z)', source)[0]
        for condition in ('', '    if: true\n', "    if: github.event_name == 'pull_request'\n"):
            changed = block.replace('    if: ' + CI_NATIVE_CONTEXT + '\n', condition, 1)
            assert changed != block and ci_wiring_findings(source.replace(block, changed, 1)), name
    for before, after in ((CI_STATIC_GATE, '${{ success() }}'), (CI_NATIVE_EXECUTION, CI_EXECUTION),
            (CI_STATIC_EXECUTION, '${{ !' + CI_EXECUTE + ' }}'),
            ('BIT101_NATIVE_CHECK: ${{ ' + CI_NATIVE_CONTEXT + ' }}', 'BIT101_NATIVE_CHECK: false')):
        assert ci_wiring_findings(source.replace(before, after)), before
    for before, after in (
            ('      - name: Preserve native compilation cache\n        continue-on-error: true',
             '      - name: Preserve native compilation cache'),
            ('BIT101_FULL_CHECK: ${{ github.event_name == \'workflow_dispatch\' && inputs.full_check }}', 'BIT101_FULL_CHECK: false'),
            ('      full_check:', '      unused_check:'),
            ('description: Run full compilation, module, behavior and UI validation\n        required: false\n        default: false\n        type: boolean',
             'description: Run full compilation, module, behavior and UI validation\n        required: false\n        default: false\n        type: string'),
            ('run: python3 Scripts/ci_evidence.py plan', 'run: true'),
            ('${{ steps.plan.outputs.plan }}', '${{ steps.unused.outputs.plan }}'),
            ('BIT101_CI_GROUP: app', 'BIT101_CI_GROUP: ui'),
            ('run: python3 Scripts/ci_evidence.py reuse "$BIT101_CI_GROUP"', 'run: true'),
            ('BIT101_CI_PLAN: ${{ needs.validation-plan.outputs.plan }}', 'BIT101_CI_PLAN: "{}"'),
            ('run: Scripts/run-static-audit.sh', 'run: true'),
            (CI_EXECUTION, '${{ false }}')):
        assert ci_wiring_findings(source.replace(before, after)), before
    for selector in ('"xcode-27"', "'xcode-27'"):
        assert not ci_wiring_findings(source.replace('runs-on: xcode-27', 'runs-on: ' + selector))
    for selector in ('macos-latest', '[self-hosted, macOS, bit101-xcode-27, bit101-ci]'):
        assert any('隔离运行器' in row for row in ci_wiring_findings(
            source.replace('runs-on: xcode-27', 'runs-on: ' + selector, 1)))
    assert runner_expression(CI_CANCELLATION.replace(' && ', '  && ')) == runner_expression(CI_CANCELLATION)
    assert runner_expression(CI_CANCELLATION.replace('!(', '! =(')) != runner_expression(CI_CANCELLATION)
    for replacement in ('xcodebuild -version', 'echo skipped'):
        assert any('工具链版本核对' in row for row in ci_wiring_findings(
            source.replace('Scripts/build-install-device.sh toolchain', replacement, 1)))
    for cancellation in ('true', '[]', '{}', '0', "${{ github.event_name == 'pull_request' }}"):
        assert any('完整恢复时间' in row for row in ci_wiring_findings(source.replace(CI_CANCELLATION, cancellation)))
    assert not ci_wiring_findings(source.replace(CI_CANCELLATION, 'false'))
    assert any('完整恢复时间' in row for row in ci_wiring_findings(source.replace(CI_CONCURRENCY_GROUP, 'ios-ci-${{ github.ref }}')))
    catalyst_start = source.index('  catalyst-tests:')
    baseline_start = source.index('      - name: Load target branch coverage baseline', catalyst_start)
    baseline_end = source.index('      - ', baseline_start + 8)
    baseline = source[baseline_start:baseline_end]
    removed = source[:baseline_start] + source[baseline_end:]
    assert any('catalyst-tests 基准载入' in row for row in ci_wiring_findings(removed))
    execution = removed.index('run: Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime', catalyst_start)
    after = removed.index('\n', execution) + 1
    assert any('catalyst-tests 基准载入' in row for row in ci_wiring_findings(removed[:after] + baseline + removed[after:]))
    conditional = source.replace('      - name: Load target branch coverage baseline\n        if: ' + CI_NATIVE_CONTEXT + '\n',
        "      - name: Load target branch coverage baseline\n        if: github.event_name == 'pull_request'\n", 1)
    assert any('每个执行入口' in row for row in ci_wiring_findings(conditional))
    tag_store_check = source.replace("BIT101_RELEASE_CHECK: ${{ github.event_name == 'workflow_dispatch' && inputs.release_check }}",
        "BIT101_RELEASE_CHECK: ${{ startsWith(github.ref, 'refs/tags/v') || (github.event_name == 'workflow_dispatch' && inputs.release_check) }}")
    assert any('App Store 版本前进核对' in row for row in ci_wiring_findings(tag_store_check))
    for action in re.findall(r'actions/(?:checkout|upload-artifact)@[0-9a-f]{40}', source):
        for reference in ('v7', '1234567'):
            changed = source.replace(action, action.split('@')[0] + '@' + reference, 1)
            assert any('完整提交 SHA' in item for item in ci_wiring_findings(changed))
    checkout = re.search(r'actions/checkout@[0-9a-f]{40}', source)[0]
    if not any('采用记录环境' in item for item in ci_wiring_findings(
            source.replace('summary --recorded-environment', 'summary', 1))):
        return ['代码质量规则边界自检失败：CI 证据汇总的执行环境口径']
    review_start = source.index('      - name: Verify maintainer review commit')
    review_end = source.index('      - name: Show toolchain', review_start)
    review = source[review_start:review_end]
    reordered = source[:review_start] + source[review_end:]
    position = reordered.index('      - name: Load target branch coverage baseline')
    reordered = reordered[:position] + review + reordered[position:]
    if not any('先于依赖安装' in item for item in ci_wiring_findings(reordered)):
        return ['代码质量规则边界自检失败：审查提交核对与依赖安装顺序']
    if not any('原始 XCTest 附件' in item for item in ci_wiring_findings(source.replace('.build/extended-automation/test-results.xcresult', '.build/extended-automation/omitted'))):
        return ['代码质量规则边界自检失败：真机原始附件留存门禁']
    if not ci_wiring_findings(source.replace('          clean: false', '          clean: true')):
        return ['代码质量规则边界自检失败：真机共享缓存保留门禁']
    mutations = [
        re.sub(r"(?m)^  pull_request:.*\n", "", source),
        re.sub(r"(?m)^  push:\n    branches:.*\n", "", source),
        source.replace("jobs:", "defaults:\n  run:\n    shell: echo {0}\njobs:", 1),
        source.replace("    steps:", "    defaults:\n      run:\n        shell: echo {0}\n    steps:", 1),
        source.replace('  pull_request:\n', '  pull_request:\n    branches: [unused-branch]\n'),
        source.replace('  pull_request:\n', "  pull_request:\n    branches-ignore: ['**']\n"),
        source.replace('  pull_request:\n', '  pull_request:\n    types: [closed]\n'),
        source.replace('    branches: [main]', '    branches: [unused-branch]'),
        source.replace('    branches: [main]', "    branches-ignore: ['**']"),
    ]
    for types in ('[opened, synchronize, reopened]', '[opened, synchronize, reopened, ready_for_review]'):
        assert not ci_wiring_findings(source.replace('  pull_request:\n', f'  pull_request:\n    types: {types}\n'))
    findings = ["代码质量规则边界自检失败：CI 自动触发与 shell 继承门禁"
                for changed in mutations if not ci_wiring_findings(changed)]
    for name in DIAGNOSTIC_PATHS:
        for required_path in DIAGNOSTIC_PATHS[name]:
            omitted = re.sub(rf'(?s)(  {name}:.*?- name: Select validation diagnostics.*?          BIT101_DIAGNOSTIC_PATHS: \|\n)(.*?)(?=\n  [a-z]|\Z)',
                lambda match: match[1] + match[2].replace('            ' + required_path + '\n', ''), workflow_source, count=1)
            if not any('诊断上传' in item for item in ci_wiring_findings(omitted)):
                findings.append(f'代码质量规则边界自检失败：{name} 的必要诊断文件')
        compressed = re.sub(rf'(?s)(  {name}:.*?      - name: Preserve validation diagnostics.*?)          compression-level: 0',
            r'\1          compression-level: 9', workflow_source, count=1)
        if not any('始终保存原始文件' in item for item in ci_wiring_findings(compressed)):
            findings.append(f'代码质量规则边界自检失败：{name} 的原始诊断上传')
        private_paths = {'.build/extended-automation/validation-evidence.json', '.build/extended-automation/**',
            '.build/extended-automation/test-results.xcresult'} - DIAGNOSTIC_PATHS[name]
        for private_path in sorted(private_paths):
            exposed = re.sub(rf'(?s)(  {name}:.*?      - name: Select validation diagnostics.*?          BIT101_DIAGNOSTIC_PATHS: \|\n)',
                lambda match: match[1] + '            ' + private_path + '\n', workflow_source, count=1)
            if not any('诊断上传' in item for item in ci_wiring_findings(exposed)):
                findings.append(f'代码质量规则边界自检失败：{name} 的历史附件隔离')
    cache_start = source.index('      - name: Preserve native compilation cache')
    cache_end = source.index('      - name: ', cache_start + 8)
    cache_step = source[cache_start:cache_end]
    for before, after in [('compression-level: 0', 'compression-level: 6'), ('overwrite: true', 'overwrite: false'),
            ('include-hidden-files: true', 'include-hidden-files: false'), ('CompilationCache.noindex', '**'),
            ("github.ref == 'refs/heads/main'", 'true')]:
        assert any('缓存' in row for row in ci_wiring_findings(source.replace(cache_step, cache_step.replace(before, after), 1))), before
    boot_step = '      - name: Prepare full iOS Simulator\n        if: ' + CI_EXECUTION + '\n        run: Scripts/run-extended-tests.sh simulator prepare\n'
    for name in ('ios-test-shards', 'ios-app-tests'):
        block = re.search(r'(?ms)^  ' + name + r':\n.*?(?=^  [\w-]+:|\Z)', source)[0]
        anchors = ('Restore shared UI test host', 'Load target branch coverage baseline') if name == 'ios-test-shards' else (
            'Restore native compilation cache', 'Load target branch coverage baseline', 'Prepare native compilation cache')
        for anchor in anchors:
            reordered = block.replace(boot_step, '').replace('      - name: ' + anchor, boot_step + '      - name: ' + anchor, 1)
            marker = '宿主与基准读取完成后' if name == 'ios-test-shards' else '缓存与基准请求后'
            assert any(marker in row for row in ci_wiring_findings(source.replace(block, reordered, 1))), (name, anchor)
    app_block = re.search(r'(?ms)^  ios-app-tests:\n.*?(?=^  [\w-]+:|\Z)', source)[0]
    upload = app_block[app_block.index('      - name: Select validation diagnostics'):app_block.index('      - name: Run complete formal runtime inventory')]
    for replacement in ('', upload.replace('validation-ios-test-shards-app-0', 'validation-unused'),
            upload.replace('compression-level: 0', 'compression-level: 6'),
            upload.replace('            .build/extended-automation/test-results.xcresult\n', '')):
        assert any('同设备' in row for row in ci_wiring_findings(source.replace(upload, replacement, 1)))
    reordered = app_block.replace(upload, '').replace('      - name: Prepare native compilation cache',
        upload + '      - name: Prepare native compilation cache', 1)
    assert any('同设备' in row for row in ci_wiring_findings(source.replace(app_block, reordered, 1)))
    for name in ('static-audit', 'release-build', 'catalyst-tests', 'ios-tests', 'release-acceptance', 'merge-acceptance'):
        for selector in ('[self-hosted, macOS, bit101-xcode-27, bit101-ci]', 'macos-latest',
                         "${{ github.event_name == 'push' && 'xcode-27' || 'macos-latest' }}"):
            unsafe = re.sub(rf'(?s)(  {name}:.*?)runs-on: ' + re.escape(CI_RUNNER),
                lambda match: match[1] + 'runs-on: ' + selector, workflow_source, count=1)
            if not any('隔离运行器' in item for item in ci_wiring_findings(unsafe)):
                findings.append(f'代码质量规则边界自检失败：{name} 的运行器隔离')
        discarded = re.sub(rf'(?s)(  {name}:.*?)          clean: false', r'\1          clean: true', workflow_source, count=1)
        if not any('保留公共缓存' in item for item in ci_wiring_findings(discarded)):
            findings.append(f'代码质量规则边界自检失败：{name} 的编译缓存保存')
    for name in ('static-audit', 'release-build', 'catalyst-tests', 'ios-tests', 'physical-device', 'release-acceptance', 'merge-acceptance'):
        for before, after in ((f'      - uses: {checkout}', f'      - if: false\n        uses: {checkout}'),
                              ('          fetch-depth: 0', '          fetch-depth: 1'),
                              ('          clean: false', '          clean: false\n          ref: main'),
                              (f'      - uses: {checkout}', f'      - continue-on-error: true\n        uses: {checkout}')):
            changed = re.sub(rf'(?s)(  {name}:.*?)' + re.escape(before),
                lambda match: match[1] + after, workflow_source, count=1)
            if not any('完整提交历史' in item for item in ci_wiring_findings(changed)):
                findings.append(f'代码质量规则边界自检失败：{name} 的完整仓库检出')
    if not ci_wiring_findings(workflow_source.replace("run: npm ci", "run: echo skipped", 1)):
        findings.append("代码质量规则边界自检失败：Worker 冷启动依赖准备")
    for command in ("Scripts/run-extended-tests.sh verify audit modules",
                    "Scripts/run-extended-tests.sh build network-smoke",
                    'Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"',
                    'Scripts/run-extended-tests.sh simulator release-runtime',
                    "Scripts/run-extended-tests.sh simulator merge",
                    "Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime"):
        for modifier in ("if: false", "continue-on-error: true", "shell: echo {0}", "working-directory: Cloudflare"):
            skipped = workflow_source.replace(f"        run: {command}", f"        {modifier}\n        run: {command}")
            if not ci_wiring_findings(skipped):
                findings.append("代码质量规则边界自检失败：CI 步骤条件与失败传播门禁")
    downgraded_release = workflow_source.replace('  release-acceptance:\n', '  release-acceptance:\n    continue-on-error: true\n')
    if not ci_wiring_findings(downgraded_release):
        findings.append('代码质量规则边界自检失败：发布验收的失败传播')
    for job in ('release-build', 'ios-ui-build', 'ios-app-tests', 'physical-device'):
        serialized = re.sub(r'(?m)(^  ' + job + r':\n)(?:    needs:.*\n)?', r'\1    needs: static-audit\n', workflow_source, count=1)
        assert any('依赖图' in item for item in ci_wiring_findings(serialized))
    for dependency in ('', '    needs: static-audit\n'):
        changed = source.replace('    needs: [validation-plan, ios-ui-build]\n', dependency, 1)
        assert any('依赖图' in row for row in ci_wiring_findings(changed))
    for before, after in (("BIT101_REUSE_UI_HOST: '1'", "BIT101_REUSE_UI_HOST: '0'"),
            ('--name ui-test-host --dir .build', '--pattern ui-* --dir .build')):
        assert any('共享宿主' in row for row in ci_wiring_findings(source.replace(before, after, 1)))
    marker = '${{ steps.ui-host.outputs.paths }}'
    assert any('UI 宿主需要' in row for row in ci_wiring_findings(source.replace(marker, '.build/extended-automation/Build/Products', 1)))
    selector = 'python3 Scripts/test_results.py ui-host-paths .build/extended-automation/Build/Products'
    assert any('UI 宿主需要' in row for row in ci_wiring_findings(source.replace(selector, 'true', 1)))
    for dependency in ('', '    needs: release-build\n', '    needs: static-audit\n'):
        changed = workflow_source.replace('  catalyst-tests:\n    needs: [validation-plan, release-build, static-audit]\n', '  catalyst-tests:\n' + dependency)
        assert any('依赖图' in row for row in ci_wiring_findings(changed))
    for dependency in ('    needs: release-build\n', '    needs: ios-ui-build\n'):
        changed = workflow_source.replace('  ios-app-tests:\n    needs: [validation-plan]\n', '  ios-app-tests:\n' + dependency)
        assert any('依赖图' in row for row in ci_wiring_findings(changed))
    detached = workflow_source.replace('needs: [validation-plan, static-audit, ios-test-shards, ios-app-tests]', 'needs: []', 1)
    assert any('依赖图' in item for item in ci_wiring_findings(detached))
    detached_formal = workflow_source.replace('needs: [validation-plan, static-audit, ios-test-shards, ios-app-tests]', 'needs: [static-audit, ios-test-shards]', 1)
    assert any('依赖图' in item for item in ci_wiring_findings(detached_formal))
    misplaced_audit = workflow_source.replace("run: Scripts/run-extended-tests.sh verify audit modules", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-extended-tests.sh verify audit modules\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
    skipped_catalyst = workflow_source.replace("run: Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime", "run: echo skipped", 1)
    if not any("Catalyst 行为 Job 需要聚合执行" in item for item in ci_wiring_findings(skipped_catalyst)):
        findings.append("代码质量规则边界自检失败：并行 Catalyst 行为用例执行门禁")
    for before, after in (("run: Scripts/run-extended-tests.sh verify modules all release-runtime ui", "run: true"),
            ('timeout-minutes: 105', 'timeout-minutes: 20'),
            ("name: validation-evidence\n", "name: other-evidence\n"),
            ('baseline "$BIT101_BASE_COMMIT"', 'baseline "wrong-commit"'),
            ("ios-tests, physical-device]", "ios-tests]")):
        changed = workflow_source.replace(before, after)
        if not ci_wiring_findings(changed):
            findings.append("代码质量规则边界自检失败：真机证据生成、提交归属与产物发布")
    for before, after in (("BIT101_SIMULATOR_AUTHORIZED: '1'", "BIT101_SIMULATOR_AUTHORIZED: '0'"),
            ('needs: [validation-plan, static-audit, release-build, catalyst-tests, ios-tests]', 'needs: [validation-plan, static-audit, release-build, catalyst-tests]'),
            ("if: startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inputs.release_check", "if: github.event_name == 'push'")):
        if not ci_wiring_findings(workflow_source.replace(before, after)):
            findings.append('代码质量规则边界自检失败：完整模拟器合并验收与发布真机分支')
    for before, after in (('run: Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"', 'run: true'),
            ('run: Scripts/run-extended-tests.sh simulator merge', 'run: true'),
            ('fail-fast: false', 'fail-fast: true'), ('max-parallel: 3', 'max-parallel: 4'), ('{mode: ui, shard: 0, count: 3, workers: 1}', '{mode: ui, shard: 0, count: 3, workers: 2}'),
            ('BIT101_CI_SHARD: ${{ matrix.shard }}/${{ matrix.count }}', 'BIT101_CI_SHARD: 0/1')):
        assert ci_wiring_findings(workflow_source.replace(before, after)), before
    for before, after in (('Scripts/build-install-device.sh toolchain', 'Scripts/build-install-device.sh  toolchain'),
            ('Scripts/run-extended-tests.sh build network-smoke', 'Scripts/run-extended-tests.sh build   network-smoke'),
            ('npm ci', 'npm  ci')):
        if ci_wiring_findings(workflow_source.replace(before, after)):
            findings.append('代码质量规则边界自检失败：CI 命令参数间距保持执行合同')
    for replacement in ('"\'Scripts/build-install-device.sh toolchain\'"', 'Scripts/build-install-device.sh toolchain extra'):
        if not ci_wiring_findings(workflow_source.replace('run: Scripts/build-install-device.sh toolchain', 'run: ' + replacement)):
            findings.append('代码质量规则边界自检失败：CI 可执行文件与参数边界')
    for job in ('static-audit', 'release-build', 'catalyst-tests', 'ios-test-shards', 'ios-app-tests'):
        changed = re.sub(r'(?s)(  ' + job + r':.*?timeout-minutes:) \d+', r'\1 20', workflow_source, count=1)
        if not any(job + ' Job 需要覆盖所属执行及恢复预算' in item for item in ci_wiring_findings(changed)):
            findings.append(f'代码质量规则边界自检失败：{job} 执行预算')
    release_minimum = workflow_timeout_seconds(('build-archive', 'network', 'icloud')) // 60 + 10
    for timeout, expected in ((45, True), (release_minimum - 1, True), (release_minimum, False)):
        changed = re.sub(r'(?s)(  release-build:.*?timeout-minutes:) \d+',
            lambda match: match[1] + ' ' + str(timeout), workflow_source, count=1)
        actual = any('release-build Job 需要覆盖所属执行及恢复预算' in item for item in ci_wiring_findings(changed))
        if actual != expected:
            findings.append('代码质量规则边界自检失败：Release 多构建流程预算边界')
    return findings


def audit_wiring_findings(ROOT, scheme_inventory_findings, extension_dependency_findings) -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    SCRIPT_ROOT = ROOT / "Scripts"
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    errors.extend(audit_callback_findings(audit_source))
    groups = re.search(r"(?ms)^group_names=\((.*?)\)(?=[ \t]*(?:\n|$))", audit_source)
    commands = re.search(r"(?ms)^group_commands=\((.*?)\)(?=[ \t]*(?:\n|$))", audit_source)
    group_names = shlex.split(groups[1], comments=True) if groups else []
    group_commands = shlex.split(commands[1], comments=True) if commands else []
    wiring = dict(zip(group_names, group_commands)) if len(group_names) == len(group_commands) else {}
    expected = {"swift-parse": "swift_parse", "shell-parse": "shell_parse", "python-parse": "python_parse",
        "worker-parse": "worker_parse", "dependency-audit": "dependency_audit", "module-boundary": "module_boundary_audit",
        "git-diff": "git_check", "docs": "docs_check", "checkers": "bit101_checker_audit"}
    if wiring != expected or len(group_names) != len(expected):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要逐组接入完整契约")
    if not re.search(r"(?m)^\s*bit101_run_audit_group\s+artifact-hygiene\s+artifact_hygiene(?:\s|$)", audit_source):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要接入产物清理检查")
    if "npm audit --audit-level=high" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 依赖漏洞审计门槛缺失")
    if "release-network-smoke" in audit_source:
        errors.append("Scripts/run-static-audit.sh: 静态审计不得调用网络 smoke")

    workflow_path = ROOT / ".github/workflows/ci.yml"
    if not workflow_path.is_file():
        errors.append(".github/workflows/ci.yml: CI 工作流不存在")
    else:
        errors.extend(ci_wiring_findings(workflow_path.read_text(encoding="utf-8")))
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"),
    ], text=True))
    errors.extend(scheme_inventory_findings({path.name: path.read_text() for path in
        (ROOT / "BIT101-iOS.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme")}))
    errors.extend(extension_dependency_findings(project))
    project_settings = project['objects'][project['objects'][project['rootObject']]['buildConfigurationList']]['buildConfigurations']
    for identifier in project_settings:
        configuration = project['objects'][identifier]
        if configuration.get("isa") == "XCBuildConfiguration" and "SWIFT_COMPILATION_MODE" in configuration.get("buildSettings", {}):
            if "$(BIT101_WORKFLOW_CONDITIONS)" not in configuration["buildSettings"].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""):
                errors.append("App 工程编译条件需要接入工作流变量")
    for name in ("run-extended-tests.sh", "run_icloud_cross_device_smoke.sh", "release-network-smoke.sh"):
        if "SWIFT_ACTIVE_COMPILATION_CONDITIONS=" in (SCRIPT_ROOT / name).read_text():
            errors.append(f"{name}: 工作流条件需要限定在 App 工程")

    test_script = ROOT / "Scripts/run-extended-tests.sh"
    if not test_script.is_file():
        errors.append("Scripts/run-extended-tests.sh: 真机测试入口不存在")
    else:
        test_source = active_script_markers(test_script.read_text(encoding="utf-8"))
        metrics = ast.parse((SCRIPT_ROOT / 'test_results.py').read_text())
        handlers = [value.id for node in ast.walk(metrics) if isinstance(node, ast.Dict)
            for key, value in zip(node.keys, node.values)
            if isinstance(key, ast.Constant) and key.value == 'native-metrics' and isinstance(value, ast.Name)]
        native_coverage = any(isinstance(node, ast.Constant) and node.value == 'xccov'
            for function in metrics.body if isinstance(function, ast.FunctionDef) and function.name in handlers
            for node in ast.walk(function))
        if not native_coverage:
            errors.append('Scripts/test_results.py: 原生指标处理需要提取代码覆盖率')
        required_test_metrics = (
            ("native-metrics", "真机测试需要接入原生指标处理"),
            ("Scripts/test_results.py", "真机指标需要沿共享结果入口处理"),
            ("test-metrics.txt", "真机测试指标未写入固定报告"),
            ("generic/platform=iOS", "测试编译需要通用 iOS 目的地"),
            ("extensions)", "缺少扩展共享逻辑测试分组"),
            ("ExternalScheduleInfrastructureTests", "扩展共享逻辑分组未执行对应测试套件"),
        )
        for marker, message in required_test_metrics:
            if marker not in test_source:
                errors.append(f"Scripts/run-extended-tests.sh: {message}")

    hook_path = ROOT / ".githooks/pre-commit"
    if not hook_path.is_file() or not hook_documents_checked(hook_path.read_text(encoding="utf-8")):
        errors.append(".githooks/pre-commit: 提交前必须检查文档引用")
    return errors
