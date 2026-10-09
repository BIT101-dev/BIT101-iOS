"""Validate CI execution context, required jobs and coverage baseline ordering."""
import json
import os
import re
import subprocess

CI_RUNNER = "${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'xcode-27' || fromJSON('[\"self-hosted\",\"macOS\",\"bit101-xcode-27\",\"bit101-ci\"]') }}"


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
    jobs = mapping(workflow.get("jobs"))
    for name, job in jobs.items():
        if name != 'physical-device' and mapping(job).get('runs-on') != CI_RUNNER:
            errors.append(f'.github/workflows/ci.yml: {name} 的隔离运行器需要将 fork 放到 GitHub 托管镜像，受信来源放到 bit101-ci')
        checkouts = [step for step in mapping(job).get('steps', []) if isinstance(step, dict)
            and str(step.get('uses', '')).startswith('actions/checkout@')]
        if len(checkouts) != 1 or mapping(checkouts[0].get('with')).get('clean') is not False:
            errors.append(f'.github/workflows/ci.yml: {name} 的 checkout 需要保留公共缓存')
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
            expected_directory = "Cloudflare/EmergencyUpdateWorker" if step["run"].strip() == "npm ci" else "."
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
        if name != "static-audit" and job.get("needs") not in ("static-audit", ["static-audit"]):
            label = "Release 编译 Job 必须依赖静态审计" if name == "release-build" else "Mac Catalyst 行为 Job 需要依赖静态审计"
            errors.append(f".github/workflows/ci.yml: {label}")
    static_commands = commands.get("static-audit", [])
    audit_index = next((index for index, (command, _) in enumerate(static_commands) if command == "Scripts/run-static-audit.sh"), -1)
    setup_index = next((index for index, (command, step) in enumerate(static_commands)
                        if command == "npm ci" and step.get("working-directory") == "Cloudflare/EmergencyUpdateWorker"), -1)
    if audit_index < 0: errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    if setup_index < 0 or audit_index < 0 or setup_index >= audit_index:
        errors.append(".github/workflows/ci.yml: Worker 锁定依赖需要在静态审计前安装并传播失败")
    required = {
        "static-audit": (("Scripts/run-extended-tests.sh modules", "模块行为测试需要默认执行并传播失败"),),
        "catalyst-tests": (
            ("Scripts/run-extended-tests.sh catalyst", "Mac Catalyst 行为 Job 需要执行行为用例"),
            ("Scripts/run-extended-tests.sh catalyst-release-runtime", "Mac Catalyst 行为 Job 需要执行正式组装合同"),
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
            if marker not in executed: errors.append(f".github/workflows/ci.yml: {message}")
    if not isinstance(workflow.get("on"), dict) or "v*" not in mapping(workflow["on"].get("push")).get("tags", []):
        errors.append(".github/workflows/ci.yml: 发布版本标签需要触发验收")
    acceptance = mapping(jobs.get("release-acceptance"))
    condition = "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inputs.release_check"
    if acceptance.get("if") != condition or set(acceptance.get("needs", [])) != {"static-audit", "release-build", "catalyst-tests"}:
        errors.append(".github/workflows/ci.yml: 发布验收需要承接完整编译和行为 Job")
    if not any(command == "python3 Scripts/ci_evidence.py check-release" for command, _ in run_commands(acceptance)):
        errors.append(".github/workflows/ci.yml: 发布验收需要默认核对提交绑定证据")
    merge = mapping(jobs.get("merge-acceptance"))
    if merge.get("if") != "always() && github.event_name == 'pull_request'" \
            or set(merge.get("needs", [])) != {"static-audit", "release-build", "catalyst-tests", "physical-device"} \
            or merge.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 合并验收需要核心真机行为与完整编译 Job")
    if not any(command == "python3 Scripts/validation_evidence.py check-merge --recorded-environment" for command, _ in run_commands(merge)):
        errors.append(".github/workflows/ci.yml: 合并验收需要核对绑定的核心真机证据")
    baseline_steps = [step for step in mapping(jobs.get("static-audit")).get("steps", [])
        if isinstance(step, dict) and step.get("name") == "Load target branch coverage baseline"]
    if len(baseline_steps) != 1 or baseline_steps[0].get("if") != "github.event_name == 'pull_request' || inputs.review_pr > 0" \
            or baseline_steps[0].get("continue-on-error", False) is not False \
            or 'python3 Scripts/validation_evidence.py baseline "$BIT101_BASE_COMMIT"' not in shell(baseline_steps[0]):
        errors.append(".github/workflows/ci.yml: PR 模块测试需要目标分支提交绑定的覆盖率基准")
    static_steps = mapping(jobs.get("static-audit")).get("steps", [])
    baseline_index = next((index for index, step in enumerate(static_steps) if isinstance(step, dict) and step.get("name") == "Load target branch coverage baseline"), -1)
    audit_step_index = next((index for index, step in enumerate(static_steps) if isinstance(step, dict) and step.get("run") == "Scripts/run-static-audit.sh"), -1)
    if baseline_index < 0 or audit_step_index < 0 or baseline_index >= audit_step_index:
        errors.append(".github/workflows/ci.yml: 基准载入需要先于当前分组记录，保留本次审计证据")
    physical = mapping(jobs.get("physical-device"))
    trusted = "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
    if physical.get("if") != trusted or physical.get("needs") != "static-audit" \
            or physical.get("runs-on") != ["self-hosted", "macOS", "bit101-xcode-27", "bit101-device"] \
            or type(physical.get("timeout-minutes")) is not int or physical['timeout-minutes'] < 60 \
            or physical.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 真机 Job 需要受信仓库来源、实体设备运行器与静态审计依赖")
    physical_commands = {command for command, _ in run_commands(physical, include_always=True)}
    if not {"Scripts/run-extended-tests.sh verify modules all release-runtime ui", "python3 Scripts/validation_evidence.py bind-merge", "python3 Scripts/ci_evidence.py export-core"} <= physical_commands:
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
            (physical, "Load target branch coverage baseline", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
                ["Scripts/ci_evidence.py", "baseline", "fixture", "Scripts/validation_evidence.py", "baseline", "fixture"])):
        candidates = [step for step in job.get("steps", []) if isinstance(step, dict) and step.get("name") == step_name]
        if len(candidates) != 1 or mapping(candidates[0].get("env")).get(key) != expression \
                or mapping(candidates[0].get("env")).get("GH_TOKEN") != "${{ github.token }}":
            errors.append(".github/workflows/ci.yml: 合并与覆盖率证据请求需要所属提交身份")
            continue
        step = candidates[0]
        expected_condition = "github.event_name == 'pull_request' || inputs.review_pr > 0" if key == "BIT101_BASE_COMMIT" else None
        if step.get("continue-on-error", False) is not False or step.get("if") != expected_condition:
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
    from ci_evidence import REVIEW_JOB_NAMES
    if {mapping(jobs.get(name)).get('name') for name in ('static-audit', 'release-build', 'catalyst-tests', 'physical-device')} != REVIEW_JOB_NAMES:
        errors.append('.github/workflows/ci.yml: 审查证据需要核对四个实际 Job 名称')
    inputs = mapping(mapping(mapping(workflow.get('on')).get('workflow_dispatch')).get('inputs'))
    if mapping(inputs.get('review_pr')).get('type') != 'number' or mapping(inputs.get('review_pr')).get('default') != 0 \
            or workflow.get('run-name') != "${{ inputs.review_pr && format('iOS CI review PR {0}', inputs.review_pr) || github.ref_name }}":
        errors.append('.github/workflows/ci.yml: fork 审查需要 PR 输入与运行身份')
    for name in ('static-audit', 'physical-device'):
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
    ]
    findings = ["代码质量规则边界自检失败：CI 自动触发与 shell 继承门禁"
                for changed in mutations if not ci_wiring_findings(changed)]
    for name in ('static-audit', 'release-build', 'catalyst-tests', 'release-acceptance', 'merge-acceptance'):
        for selector in ('[self-hosted, macOS, bit101-xcode-27, bit101-ci]', 'xcode-27',
                         CI_RUNNER.replace(' != github.repository', ' == github.repository')):
            unsafe = re.sub(rf'(?s)(  {name}:.*?)runs-on: ' + re.escape(CI_RUNNER),
                lambda match: match[1] + 'runs-on: ' + selector, workflow_source, count=1)
            if not any('隔离运行器' in item for item in ci_wiring_findings(unsafe)):
                findings.append(f'代码质量规则边界自检失败：{name} 的运行器隔离')
        discarded = re.sub(rf'(?s)(  {name}:.*?)          clean: false', r'\1          clean: true', workflow_source, count=1)
        if not any('保留公共缓存' in item for item in ci_wiring_findings(discarded)):
            findings.append(f'代码质量规则边界自检失败：{name} 的编译缓存保存')
    if not ci_wiring_findings(workflow_source.replace("run: npm ci", "run: echo skipped", 1)):
        findings.append("代码质量规则边界自检失败：Worker 冷启动依赖准备")
    for command in ("Scripts/run-static-audit.sh", "Scripts/run-extended-tests.sh modules",
                    "Scripts/run-extended-tests.sh build ui", "Scripts/run-extended-tests.sh catalyst",
                    "Scripts/run-extended-tests.sh catalyst-release-runtime"):
        for modifier in ("if: false", "continue-on-error: true", "shell: echo {0}", "working-directory: Cloudflare"):
            skipped = workflow_source.replace(f"        run: {command}", f"        {modifier}\n        run: {command}")
            if not ci_wiring_findings(skipped):
                findings.append("代码质量规则边界自检失败：CI 步骤条件与失败传播门禁")
    detached_release = workflow_source.replace("needs: static-audit", "needs: []", 1)
    if not any("必须依赖静态审计" in item for item in ci_wiring_findings(detached_release)):
        findings.append("代码质量规则边界自检失败：Release Job 与静态审计依赖识别")
    misplaced_audit = workflow_source.replace("run: Scripts/run-static-audit.sh", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-static-audit.sh\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
    detached_catalyst = re.sub(r"(?s)(  catalyst-tests:.*?)    needs: static-audit", r"\1    needs: []", workflow_source, count=1)
    if not any("Catalyst 行为 Job 需要依赖静态审计" in item for item in ci_wiring_findings(detached_catalyst)):
        findings.append("代码质量规则边界自检失败：Catalyst Job 与静态审计依赖识别")
    skipped_catalyst = workflow_source.replace("run: Scripts/run-extended-tests.sh catalyst", "run: echo skipped", 1)
    if not any("Catalyst 行为 Job 需要执行" in item for item in ci_wiring_findings(skipped_catalyst)):
        findings.append("代码质量规则边界自检失败：并行 Catalyst 行为用例执行门禁")
    for before, after in (("run: Scripts/run-extended-tests.sh verify modules all release-runtime ui", "run: true"),
            ("name: validation-evidence\n", "name: other-evidence\n"),
            ('baseline "$BIT101_BASE_COMMIT"', 'baseline "wrong-commit"'),
            ("catalyst-tests, physical-device]", "catalyst-tests]")):
        changed = workflow_source.replace(before, after)
        if not ci_wiring_findings(changed):
            findings.append("代码质量规则边界自检失败：真机证据生成、提交归属与产物发布")
    return findings
