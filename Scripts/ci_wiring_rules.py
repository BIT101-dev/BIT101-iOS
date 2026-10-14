"""Validate CI execution context, required jobs and coverage baseline ordering."""
import json
import os
import re
import subprocess
import shlex
from audit_callback_rules import audit_callback_findings
from validation_policy import workflow_timeout_seconds

CI_RUNNER = "xcode-27"
CI_CANCELLATION = "${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}"
DIAGNOSTIC_PATHS = {
    'static-audit': {'.build/static-audit/*.log', '.build/code-quality-report.txt', '.build/ui-consistency-report.txt',
        '.build/explanatory-text-report.txt', '.build/extended-automation/modules.log',
        '.build/extended-automation/module-events.jsonl', '.build/extended-automation/test-metrics.txt'},
    'release-build': {'.build/extended-automation/build-release.log', '.build/extended-automation/build-ui.log',
        '.build/extended-automation/build-network-smoke.log', '.build/extended-automation/build-icloud-smoke.log',
        '.build/extended-automation/diagnostics/test-results.xcresult', 'build/DeviceInstall/build.log'},
    'catalyst-tests': {'.build/extended-automation/catalyst.log', '.build/extended-automation/catalyst-release-runtime.log',
        '.build/extended-automation/test-metrics.txt', '.build/extended-automation/test-failures.txt',
        '.build/extended-automation/test-results.xcresult'},
}


def hook_documents_checked(source: str) -> bool:
    for line in source.splitlines():
        words = shlex.split(line, comments=True)
        if words[:1] == ['exec']: words = words[1:]
        if words[:2] == ['python3', 'Scripts/check-docs.py'] and {'--all', '--staged'} <= set(words[2:]): return True
    return False


def active_script_markers(source: str) -> str:
    lines = []
    for line in source.splitlines():
        try: lines.append(' '.join(shlex.split(line, comments=True, posix=False)))
        except ValueError: lines.append(line if not line.lstrip().startswith('#') else '')
    return '\n'.join(lines)


def command_matches(actual: str, expected: str) -> bool:
    try:
        return shlex.split(actual, comments=True) == shlex.split(expected, comments=True)
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
    if cancellation is not False and runner_expression(cancellation) != runner_expression(CI_CANCELLATION):
        errors.append('.github/workflows/ci.yml: 真机与受信宿主工作流需要保留完整恢复时间，自动取消归属 fork 托管任务')

    def shell(step):
        value = mapping(step).get('run', '')
        return value if isinstance(value, str) else ''

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
                and str(step.get('uses', '')).startswith('actions/upload-artifact@')]
            if len(uploads) != 1 or set(mapping(uploads[0].get('with')).get('path', '').splitlines()) != DIAGNOSTIC_PATHS[name]:
                errors.append(f'.github/workflows/ci.yml: {name} 的诊断上传需要采用所属任务的文件清单，人工附件保留在本地')
            if len(uploads) != 1 or uploads[0].get('if') != 'always()' \
                    or mapping(uploads[0].get('with')).get('compression-level') != 0 \
                    or mapping(uploads[0].get('with')).get('include-hidden-files') is not True:
                errors.append(f'.github/workflows/ci.yml: {name} 的诊断上传需要始终保存原始文件及隐藏路径')
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
            if "if" in step and not (include_always and step["if"] == "always()") \
                    or step.get("continue-on-error", False) is not False: continue
            command = step["run"]
            if isinstance(command, str): commands.append((command.strip(), step))
        return commands

    commands = {}
    for name in ("static-audit", "release-build", "catalyst-tests"):
        job = mapping(jobs.get(name))
        if not job:
            errors.append(f".github/workflows/ci.yml: CI 缺少 {name} Job")
            continue
        if "if" in job or job.get("continue-on-error", False) is not False:
            errors.append(f".github/workflows/ci.yml: {name} 需要默认执行并传播失败")
        commands[name] = run_commands(job)
        if not any(command_matches(command, "Scripts/build-install-device.sh toolchain") for command, _ in commands[name]):
            errors.append(f".github/workflows/ci.yml: {name} 的工具链版本核对需要共用构建脚本入口")
        if not any(command_matches(command, "python3 Scripts/validation_evidence.py summary --recorded-environment")
                for command, _ in run_commands(job, include_always=True)):
            errors.append(f".github/workflows/ci.yml: {name} 的证据汇总需要采用记录环境")
        if name != "static-audit" and job.get("needs") not in ("static-audit", ["static-audit"]):
            label = "Release 编译 Job 必须依赖静态审计" if name == "release-build" else "Mac Catalyst 行为 Job 需要依赖静态审计"
            errors.append(f".github/workflows/ci.yml: {label}")
    static_commands = commands.get("static-audit", [])
    audit_index = next((index for index, (command, _) in enumerate(static_commands) if command_matches(command, "Scripts/run-static-audit.sh")), -1)
    setup_index = next((index for index, (command, step) in enumerate(static_commands)
                        if command_matches(command, "npm ci") and step.get("working-directory") == "Cloudflare/EmergencyUpdateWorker"), -1)
    if audit_index < 0: errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    release_expression = "${{ github.event_name == 'workflow_dispatch' && inputs.release_check }}"
    if audit_index >= 0 and mapping(static_commands[audit_index][1].get('env')).get('BIT101_RELEASE_CHECK') != release_expression:
        errors.append('.github/workflows/ci.yml: 手动上传预检需要 App Store 版本前进核对')
    if setup_index < 0 or audit_index < 0 or setup_index >= audit_index:
        errors.append(".github/workflows/ci.yml: Worker 锁定依赖需要在静态审计前安装并传播失败")
    required = {
        "static-audit": (("Scripts/run-extended-tests.sh modules", "模块行为测试需要默认执行并传播失败"),),
        "catalyst-tests": (
            ("Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime", "Mac Catalyst 行为 Job 需要聚合执行行为用例和正式组装合同"),
        ),
        "release-build": (
            ("Scripts/build-install-device.sh archive", "CI 需要正式归档编译模式验证"),
            ("Scripts/run-extended-tests.sh build release", "CI 需要通用 iOS Release 测试构建"),
            ("Scripts/run-extended-tests.sh build ui", "CI 需要 UI 宿主与测试构建"),
            ("Scripts/run-extended-tests.sh build network-smoke", "CI 需要网络 Smoke 编译条件构建"),
            ("Scripts/run-extended-tests.sh build icloud-smoke", "CI 需要 iCloud Smoke 编译条件构建"),
        ),
    }
    for name, rules in required.items():
        executed = {command for command, _ in commands.get(name, [])}
        for marker, message in rules:
            if not any(command_matches(command, marker) for command in executed): errors.append(f".github/workflows/ci.yml: {message}")
    if not isinstance(workflow.get("on"), dict) or "v*" not in mapping(workflow["on"].get("push")).get("tags", []):
        errors.append(".github/workflows/ci.yml: 发布版本标签需要触发验收")
    acceptance = mapping(jobs.get("release-acceptance"))
    condition = "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inputs.release_check"
    if acceptance.get("if") != condition or set(acceptance.get("needs", [])) != {"static-audit", "release-build", "catalyst-tests"} \
            or acceptance.get('continue-on-error', False) is not False:
        errors.append(".github/workflows/ci.yml: 发布验收需要承接完整编译和行为 Job")
    if not any(command_matches(command, "python3 Scripts/ci_evidence.py check-release") for command, _ in run_commands(acceptance)):
        errors.append(".github/workflows/ci.yml: 发布验收需要默认核对提交绑定证据")
    merge = mapping(jobs.get("merge-acceptance"))
    if merge.get("if") != "always() && github.event_name == 'pull_request'" \
            or set(merge.get("needs", [])) != {"static-audit", "release-build", "catalyst-tests", "physical-device"} \
            or merge.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 合并验收需要核心真机行为与完整编译 Job")
    core_checks = [step for step in merge.get('steps', []) if isinstance(step, dict)
        and command_matches(str(step.get('run', '')), 'python3 Scripts/validation_evidence.py check-merge --recorded-environment')]
    scope_condition = "needs.static-audit.outputs.physical_required == 'true'"
    if len(core_checks) != 1 or core_checks[0].get('if') != scope_condition:
        errors.append(".github/workflows/ci.yml: 合并验收需要核对绑定的核心真机证据")
    for name, command in (('static-audit', 'Scripts/run-static-audit.sh'),
                          ('catalyst-tests', 'Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime')):
        steps = mapping(jobs.get(name)).get('steps', [])
        baseline_index = next((index for index, step in enumerate(steps) if isinstance(step, dict) and step.get('name') == 'Load target branch coverage baseline'), -1)
        execution_index = next((index for index, step in enumerate(steps) if isinstance(step, dict) and command_matches(str(step.get('run', '')), command)), -1)
        if not 0 <= baseline_index < execution_index:
            errors.append(f'.github/workflows/ci.yml: {name} 基准载入需要先于当前分组记录')
    physical = mapping(jobs.get("physical-device"))
    static = mapping(jobs.get('static-audit'))
    scope_steps = [step for step in static.get('steps', []) if isinstance(step, dict) and step.get('id') == 'physical_scope']
    if mapping(static.get('outputs')).get('physical_required') != '${{ steps.physical_scope.outputs.required }}' \
            or len(scope_steps) != 1 or scope_steps[0].get('run') != 'python3 Scripts/ci_evidence.py physical-scope "$BIT101_BASE_COMMIT" >> "$GITHUB_OUTPUT"' \
            or mapping(scope_steps[0].get('env')).get('BIT101_BASE_COMMIT') != "${{ github.event.pull_request.base.sha || '' }}" \
            or scope_steps[0].get('if') or scope_steps[0].get('continue-on-error', False):
        errors.append('.github/workflows/ci.yml: 真机范围需要沿 PR 目标提交计算并绑定实际输出')
    trusted = "(github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) && " + scope_condition
    if physical.get("if") != trusted or physical.get("needs") != "static-audit" \
            or runner_expression(physical.get("runs-on")) != runner_expression(["self-hosted", "macOS", "bit101-xcode-27", "bit101-device"]) \
            or type(physical.get("timeout-minutes")) is not int \
            or physical['timeout-minutes'] < workflow_timeout_seconds(('modules', 'all', 'release-runtime', 'ui')) // 60 + 10 \
            or physical.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 真机 Job 需要受信仓库来源、实体设备运行器与静态审计依赖")
    for job, groups in (('static-audit', ('audit', 'modules')),
            ('release-build', ('all', 'build-archive', 'ui', 'network', 'icloud')),
            ('catalyst-tests', ('catalyst', 'catalyst-release-runtime'))):
        timeout = mapping(jobs.get(job)).get('timeout-minutes')
        if type(timeout) is not int or timeout < workflow_timeout_seconds(groups) // 60 + 10:
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
    baseline_command = 'python3 Scripts/ci_evidence.py baseline "$BIT101_BASE_COMMIT"'
    for job, step_name, key, expression, expected in (
            (acceptance, "Download release validation evidence", "BIT101_RELEASE_TAG", "${{ inputs.validation_tag || github.ref_name }}",
                ["Scripts/ci_evidence.py", "release", "fixture"]),
            (merge, "Download merge validation evidence", "BIT101_REQUIRED_RESULTS", "${{ join(needs.*.result, ',') }}",
                ["Scripts/ci_evidence.py", "current", "--results", "fixture"]),
            (mapping(jobs.get("static-audit")), "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (mapping(jobs.get("catalyst-tests")), "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"]),
            (physical, "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"])):
        candidates = [step for step in job.get("steps", []) if isinstance(step, dict) and step.get("name") == step_name]
        if len(candidates) != 1 or mapping(candidates[0].get("env")).get(key) != expression \
                or mapping(candidates[0].get("env")).get("GH_TOKEN") != "${{ github.token }}":
            errors.append(".github/workflows/ci.yml: 合并与覆盖率证据请求需要所属提交身份")
            continue
        if step_name == 'Load target branch coverage baseline' and candidates[0].get('if'):
            errors.append('.github/workflows/ci.yml: 每个执行入口需要设置所属覆盖率基准')
        step = candidates[0]
        if step.get("continue-on-error", False) is not False or step.get("if") is not None:
            errors.append(".github/workflows/ci.yml: 提交证据读取失败需要传播")
        errors.extend(evidence_execution_findings(shell(step), key, expected))
    steps = physical.get("steps", [])
    exports = [step for step in steps if isinstance(step, dict) and step.get('run') == 'python3 Scripts/ci_evidence.py export-core']
    if len(exports) != 1 or exports[0].get('if') != 'always()' or not publishers \
            or steps.index(exports[0]) >= steps.index(publishers[0]):
        errors.append('.github/workflows/ci.yml: CI 交换需要先导出核心验证组，保留完整人工证明在本地')
    diagnostics = [step for step in steps if isinstance(step, dict) and step.get('name') == 'Preserve validation diagnostics']
    if len(diagnostics) != 1 or diagnostics[0].get('if') != 'always()' \
            or not diagnostics[0].get('uses', '').startswith('actions/upload-artifact@') \
            or mapping(diagnostics[0].get('with')).get('compression-level') != 0 \
            or mapping(diagnostics[0].get('with')).get('include-hidden-files') is not True \
            or set(mapping(diagnostics[0].get('with')).get('path', '').splitlines()) != {
                '.build/extended-automation/*.log', '.build/extended-automation/*.txt',
                '.build/extended-automation/test-results.xcresult'}:
        errors.append('.github/workflows/ci.yml: 真机失败需要保存完整日志与原始 XCTest 附件')
    checkouts = [step for step in steps if isinstance(step, dict) and step.get('uses', '').startswith('actions/checkout@')]
    if len(checkouts) != 1 or mapping(checkouts[0].get('with')).get('clean') is not False:
        errors.append('.github/workflows/ci.yml: 真机工作区需要保留共享增量编译缓存')
    load = next((i for i, step in enumerate(steps) if baseline_command in shell(step)), -1)
    verify = next((i for i, step in enumerate(steps) if isinstance(step, dict) and step.get("run") == "Scripts/run-extended-tests.sh verify modules all release-runtime ui"), -1)
    bind = next((i for i, step in enumerate(steps) if isinstance(step, dict) and step.get("run") == "python3 Scripts/validation_evidence.py bind-merge"), -1)
    if not 0 <= load < verify < bind:
        errors.append(".github/workflows/ci.yml: 真机证据需要沿基准、执行和提交绑定顺序生成")
    from validation_policy import REVIEW_JOB_NAMES
    if {mapping(jobs.get(name)).get('name') for name in ('static-audit', 'release-build', 'catalyst-tests', 'physical-device')} != REVIEW_JOB_NAMES:
        errors.append('.github/workflows/ci.yml: 审查证据需要核对四个实际 Job 名称')
    inputs = mapping(mapping(mapping(workflow.get('on')).get('workflow_dispatch')).get('inputs'))
    if mapping(inputs.get('review_pr')).get('type') != 'number' or mapping(inputs.get('review_pr')).get('default') != 0 \
            or workflow.get('run-name') != "${{ inputs.review_pr && format('iOS CI review PR {0}', inputs.review_pr) || github.ref_name }}":
        errors.append('.github/workflows/ci.yml: fork 审查需要 PR 输入与运行身份')
    for name in ('static-audit', 'catalyst-tests', 'physical-device'):
        steps = mapping(jobs.get(name)).get('steps', [])
        review = [(i, step) for i, step in enumerate(steps) if isinstance(step, dict) and step.get('name') == 'Verify maintainer review commit']
        baseline = next((i for i, step in enumerate(steps) if isinstance(step, dict) and step.get('name') == 'Load target branch coverage baseline'), -1)
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


def review_execution_findings(command: str) -> list[str]:
    harness = 'python3() { printf "%s\\0" "$@" >&2; [[ "$fail_at" == 0 ]] || return 73; printf "fixture-base"; };\n'
    for failure in ('0', '1'):
        env = dict(os.environ, BIT101_REVIEW_PR='12', GITHUB_OUTPUT='/dev/stdout', fail_at=failure)
        result = subprocess.run(['bash', '-eo', 'pipefail', '-c', harness + command], env=env, capture_output=True, text=True)
        if result.stderr.split('\0')[:-1] != ['Scripts/ci_evidence.py', 'review-pr', '12'] \
                or result.returncode != (73 if failure == '1' else 0) \
                or result.stdout != ('' if failure == '1' else 'base_sha=fixture-base\n'):
            return ['.github/workflows/ci.yml: 审查需要核对原 PR 合并提交并传播失败']
    return []


def evidence_execution_findings(command: str, key: str, expected: list[str]) -> list[str]:
    harness = 'call=0; python3() { ((call+=1)); printf "%s\\0" "$@"; [[ "$call" != "$fail_at" ]] || return 73; return 0; };\n'
    environment = dict(os.environ, **{key: "fixture", "fail_at": "0"})
    result = subprocess.run(["bash", "-eo", "pipefail", "-c", harness + command], env=environment, capture_output=True, text=True)
    if result.returncode or result.stdout.split("\0")[:-1] != expected:
        return [".github/workflows/ci.yml: 证据交换需要所属提交或运行的完整命令"]
    for index in range(1, sum(argument.endswith('.py') for argument in expected) + 1):
        failed = subprocess.run(["bash", "-eo", "pipefail", "-c", harness + command],
            env=dict(environment, fail_at=str(index)), capture_output=True, text=True)
        if failed.returncode != 73:
            return [".github/workflows/ci.yml: 证据交换失败需要结束所属步骤"]
    return []


def ci_trigger_shell_self_test(workflow_source: str) -> list[str]:
    source = workflow_source
    for selector in ('"xcode-27"', "'xcode-27'"):
        assert not ci_wiring_findings(source.replace('runs-on: xcode-27', 'runs-on: ' + selector))
    for selector in ('macos-latest', '[self-hosted, macOS, bit101-xcode-27, bit101-ci]'):
        assert any('隔离运行器' in row for row in ci_wiring_findings(
            source.replace('runs-on: xcode-27', 'runs-on: ' + selector, 1)))
    assert runner_expression(CI_CANCELLATION.replace(' && ', '  && ')) == runner_expression(CI_CANCELLATION)
    assert runner_expression(CI_CANCELLATION.replace(' != ', ' ! = ')) != runner_expression(CI_CANCELLATION)
    for replacement in ('xcodebuild -version', 'echo skipped'):
        assert any('工具链版本核对' in row for row in ci_wiring_findings(
            source.replace('Scripts/build-install-device.sh toolchain', replacement, 1)))
    for cancellation in ('true', '[]', '{}', '0', "${{ github.event_name == 'pull_request' }}"):
        assert any('完整恢复时间' in row for row in ci_wiring_findings(source.replace(CI_CANCELLATION, cancellation)))
    assert not ci_wiring_findings(source.replace(CI_CANCELLATION, 'false'))
    catalyst_start = source.index('  catalyst-tests:')
    baseline_start = source.index('      - name: Load target branch coverage baseline', catalyst_start)
    baseline_end = source.index('      - ', baseline_start + 8)
    baseline = source[baseline_start:baseline_end]
    removed = source[:baseline_start] + source[baseline_end:]
    assert any('catalyst-tests 基准载入' in row for row in ci_wiring_findings(removed))
    execution = removed.index('run: Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime', catalyst_start)
    after = removed.index('\n', execution) + 1
    assert any('catalyst-tests 基准载入' in row for row in ci_wiring_findings(removed[:after] + baseline + removed[after:]))
    conditional = source.replace('      - name: Load target branch coverage baseline\n',
        "      - name: Load target branch coverage baseline\n        if: github.event_name == 'pull_request'\n", 1)
    assert any('每个执行入口' in row for row in ci_wiring_findings(conditional))
    tag_store_check = source.replace("BIT101_RELEASE_CHECK: ${{ github.event_name == 'workflow_dispatch' && inputs.release_check }}",
        "BIT101_RELEASE_CHECK: ${{ startsWith(github.ref, 'refs/tags/v') || (github.event_name == 'workflow_dispatch' && inputs.release_check) }}", 1)
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
            omitted = re.sub(rf'(?s)(  {name}:.*?          path: \|\n)(.*?)(?=\n  [a-z]|\Z)',
                lambda match: match[1] + match[2].replace('            ' + required_path + '\n', ''), workflow_source, count=1)
            if not any('诊断上传' in item for item in ci_wiring_findings(omitted)):
                findings.append(f'代码质量规则边界自检失败：{name} 的必要诊断文件')
        compressed = re.sub(rf'(?s)(  {name}:.*?)          compression-level: 0',
            r'\1          compression-level: 9', workflow_source, count=1)
        if not any('始终保存原始文件' in item for item in ci_wiring_findings(compressed)):
            findings.append(f'代码质量规则边界自检失败：{name} 的原始诊断上传')
        private_paths = {'.build/extended-automation/validation-evidence.json', '.build/extended-automation/**',
            '.build/extended-automation/test-results.xcresult'} - DIAGNOSTIC_PATHS[name]
        for private_path in sorted(private_paths):
            exposed = re.sub(rf'(?s)(  {name}:.*?          path: \|\n)',
                lambda match: match[1] + '            ' + private_path + '\n', workflow_source, count=1)
            if not any('诊断上传' in item for item in ci_wiring_findings(exposed)):
                findings.append(f'代码质量规则边界自检失败：{name} 的历史附件隔离')
    for name in ('static-audit', 'release-build', 'catalyst-tests', 'release-acceptance', 'merge-acceptance'):
        for selector in ('[self-hosted, macOS, bit101-xcode-27, bit101-ci]', 'macos-latest',
                         "${{ github.event_name == 'push' && 'xcode-27' || 'macos-latest' }}"):
            unsafe = re.sub(rf'(?s)(  {name}:.*?)runs-on: ' + re.escape(CI_RUNNER),
                lambda match: match[1] + 'runs-on: ' + selector, workflow_source, count=1)
            if not any('隔离运行器' in item for item in ci_wiring_findings(unsafe)):
                findings.append(f'代码质量规则边界自检失败：{name} 的运行器隔离')
        discarded = re.sub(rf'(?s)(  {name}:.*?)          clean: false', r'\1          clean: true', workflow_source, count=1)
        if not any('保留公共缓存' in item for item in ci_wiring_findings(discarded)):
            findings.append(f'代码质量规则边界自检失败：{name} 的编译缓存保存')
    for name in ('static-audit', 'release-build', 'catalyst-tests', 'physical-device', 'release-acceptance', 'merge-acceptance'):
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
    for command in ("Scripts/run-static-audit.sh", "Scripts/run-extended-tests.sh modules",
                    "Scripts/run-extended-tests.sh build ui",
                    "Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime"):
        for modifier in ("if: false", "continue-on-error: true", "shell: echo {0}", "working-directory: Cloudflare"):
            skipped = workflow_source.replace(f"        run: {command}", f"        {modifier}\n        run: {command}")
            if not ci_wiring_findings(skipped):
                findings.append("代码质量规则边界自检失败：CI 步骤条件与失败传播门禁")
    detached_release = workflow_source.replace("needs: static-audit", "needs: []", 1)
    downgraded_release = workflow_source.replace('  release-acceptance:\n', '  release-acceptance:\n    continue-on-error: true\n')
    if not ci_wiring_findings(downgraded_release):
        findings.append('代码质量规则边界自检失败：发布验收的失败传播')
    if not any("必须依赖静态审计" in item for item in ci_wiring_findings(detached_release)):
        findings.append("代码质量规则边界自检失败：Release Job 与静态审计依赖识别")
    misplaced_audit = workflow_source.replace("run: Scripts/run-static-audit.sh", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-static-audit.sh\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
    detached_catalyst = re.sub(r"(?s)(  catalyst-tests:.*?)    needs: static-audit", r"\1    needs: []", workflow_source, count=1)
    if not any("Catalyst 行为 Job 需要依赖静态审计" in item for item in ci_wiring_findings(detached_catalyst)):
        findings.append("代码质量规则边界自检失败：Catalyst Job 与静态审计依赖识别")
    skipped_catalyst = workflow_source.replace("run: Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime", "run: echo skipped", 1)
    if not any("Catalyst 行为 Job 需要聚合执行" in item for item in ci_wiring_findings(skipped_catalyst)):
        findings.append("代码质量规则边界自检失败：并行 Catalyst 行为用例执行门禁")
    for before, after in (("run: Scripts/run-extended-tests.sh verify modules all release-runtime ui", "run: true"),
            ('timeout-minutes: 195', 'timeout-minutes: 60'), ('timeout-minutes: 105', 'timeout-minutes: 20'),
            ("name: validation-evidence\n", "name: other-evidence\n"),
            ('baseline "$BIT101_BASE_COMMIT"', 'baseline "wrong-commit"'),
            ("catalyst-tests, physical-device]", "catalyst-tests]")):
        changed = workflow_source.replace(before, after)
        if not ci_wiring_findings(changed):
            findings.append("代码质量规则边界自检失败：真机证据生成、提交归属与产物发布")
    for before, after in (('physical-scope "$BIT101_BASE_COMMIT"', 'physical-scope ""'),
            ('${{ steps.physical_scope.outputs.required }}', 'false'),
            ("if: needs.static-audit.outputs.physical_required == 'true'", "if: false")):
        if not ci_wiring_findings(workflow_source.replace(before, after)):
            findings.append('代码质量规则边界自检失败：真机输入范围与核心验收分支')
    for before, after in (('Scripts/build-install-device.sh toolchain', 'Scripts/build-install-device.sh  toolchain'),
            ('Scripts/run-extended-tests.sh build ui', 'Scripts/run-extended-tests.sh build   ui'),
            ('npm ci', 'npm  ci')):
        if ci_wiring_findings(workflow_source.replace(before, after)):
            findings.append('代码质量规则边界自检失败：CI 命令参数间距保持执行合同')
    for replacement in ('"\'Scripts/build-install-device.sh toolchain\'"', 'Scripts/build-install-device.sh toolchain extra'):
        if not ci_wiring_findings(workflow_source.replace('run: Scripts/build-install-device.sh toolchain', 'run: ' + replacement)):
            findings.append('代码质量规则边界自检失败：CI 可执行文件与参数边界')
    for job in ('static-audit', 'release-build', 'catalyst-tests'):
        changed = re.sub(r'(?s)(  ' + job + r':.*?timeout-minutes:) \d+', r'\1 20', workflow_source, count=1)
        if not any(job + ' Job 需要覆盖所属执行及恢复预算' in item for item in ci_wiring_findings(changed)):
            findings.append(f'代码质量规则边界自检失败：{job} 执行预算')
    release_minimum = workflow_timeout_seconds(('all', 'build-archive', 'ui', 'network', 'icloud')) // 60 + 10
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
        "git-diff": "git_check", "docs": "docs_check", "checkers": "checker_audit"}
    if wiring != expected or len(group_names) != len(expected):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要逐组接入完整契约")
    if "check-docs.py --all" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入文档引用检查")
    if not re.search(r"(?m)^\s*run_group\s+artifact-hygiene\s+artifact_hygiene(?:\s|$)", audit_source):
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
    for configuration in project["objects"].values():
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
        required_test_metrics = (
            ("xccov", "真机测试未提取代码覆盖率"),
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
