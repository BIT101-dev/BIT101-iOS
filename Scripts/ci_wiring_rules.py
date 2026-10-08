"""Validate CI execution context, required jobs and coverage baseline ordering."""
import json
import os
import re
import subprocess


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

    events = workflow.get("on", {})
    events = {events} if isinstance(events, str) else events if isinstance(events, (list, dict)) else {}
    if not {"pull_request", "push"}.issubset(events):
        errors.append(".github/workflows/ci.yml: CI 需要 pull_request 和 push 自动触发")
    for event in ("pull_request", "push"):
        if {"paths", "paths-ignore"} & mapping(mapping(workflow.get("on")).get(event)).keys():
            errors.append(f".github/workflows/ci.yml: {event} 需要覆盖全部仓库路径")
    jobs = mapping(workflow.get("jobs"))
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
    if not any(command == "python3 Scripts/validation_evidence.py check --recorded-environment" for command, _ in run_commands(acceptance)):
        errors.append(".github/workflows/ci.yml: 发布验收需要默认核对提交绑定证据")
    if not any(command == "python3 Scripts/validation_evidence.py summary --recorded-environment" for command, _ in run_commands(acceptance, include_always=True)):
        errors.append(".github/workflows/ci.yml: 发布汇总需要沿用验收的记录环境")
    merge = mapping(jobs.get("merge-acceptance"))
    if merge.get("if") != "github.event_name == 'pull_request'" or set(merge.get("needs", [])) != {"static-audit", "release-build", "catalyst-tests"} \
            or merge.get("continue-on-error", False) is not False:
        errors.append(".github/workflows/ci.yml: 合并验收需要核心真机行为与完整编译 Job")
    if not any(command == "python3 Scripts/validation_evidence.py check-merge --recorded-environment" for command, _ in run_commands(merge)):
        errors.append(".github/workflows/ci.yml: 合并验收需要核对绑定的核心真机证据")
    baseline_steps = [step for step in mapping(jobs.get("static-audit")).get("steps", [])
        if isinstance(step, dict) and step.get("name") == "Load target branch coverage baseline"]
    if len(baseline_steps) != 1 or baseline_steps[0].get("if") != "github.event_name == 'pull_request'" \
            or baseline_steps[0].get("continue-on-error", False) is not False \
            or 'python3 Scripts/validation_evidence.py baseline "$BIT101_BASE_COMMIT"' not in baseline_steps[0].get("run", ""):
        errors.append(".github/workflows/ci.yml: PR 模块测试需要目标分支提交绑定的覆盖率基准")
    static_steps = mapping(jobs.get("static-audit")).get("steps", [])
    baseline_index = next((index for index, step in enumerate(static_steps) if isinstance(step, dict) and step.get("name") == "Load target branch coverage baseline"), -1)
    audit_step_index = next((index for index, step in enumerate(static_steps) if isinstance(step, dict) and step.get("run") == "Scripts/run-static-audit.sh"), -1)
    if baseline_index < 0 or audit_step_index < 0 or baseline_index >= audit_step_index:
        errors.append(".github/workflows/ci.yml: 基准载入需要先于当前分组记录，保留本次审计证据")
    for job, step_name, url_key, commit_key, commit_expression in (
            (acceptance, "Download release validation evidence", "BIT101_RELEASE_EVIDENCE_URL", "BIT101_RELEASE_COMMIT", "${{ github.sha }}"),
            (merge, "Download merge validation evidence", "BIT101_MERGE_EVIDENCE_URL", "BIT101_MERGE_COMMIT", "${{ github.sha }}"),
            (mapping(jobs.get("static-audit")), "Load target branch coverage baseline",
                "BIT101_COVERAGE_BASELINE_URL", "BIT101_BASE_COMMIT", "${{ github.event.pull_request.base.sha }}")):
        candidates = [step for step in job.get("steps", []) if isinstance(step, dict) and step.get("name") == step_name]
        if len(candidates) != 1 or mapping(candidates[0].get("env")).get(commit_key) != commit_expression:
            errors.append(".github/workflows/ci.yml: 合并与覆盖率证据请求需要所属提交身份")
            continue
        step = candidates[0]
        expected_condition = "github.event_name == 'pull_request'" if commit_key == "BIT101_BASE_COMMIT" else None
        if step.get("continue-on-error", False) is not False or step.get("if") != expected_condition:
            errors.append(".github/workflows/ci.yml: 提交证据读取失败需要传播")
        errors.extend(evidence_request_findings(step.get("run", ""), url_key, commit_key))
    return errors


def evidence_request_findings(command: str, url_key: str, commit_key: str) -> list[str]:
    harness = 'mkdir() { :; }; python3() { :; }; curl() { printf "%s\\0" "$@"; };\n'
    environment = dict(os.environ, **{url_key: "https://evidence.invalid/validation-evidence.json", commit_key: "fixture-commit"})
    result = subprocess.run(["bash", "-eo", "pipefail", "-c", harness + command], env=environment, capture_output=True, text=True)
    arguments = result.stdout.split("\0")
    pairs = set(zip(arguments, arguments[1:]))
    if result.returncode or "--get" not in arguments \
            or ("--data-urlencode", "commit=fixture-commit") not in pairs \
            or ("--output", ".build/extended-automation/validation-evidence.json") not in pairs \
            or "https://evidence.invalid/validation-evidence.json" not in arguments:
        return [".github/workflows/ci.yml: 证据服务需要按提交查询并保存固定工作区文件"]
    failed = subprocess.run(["bash", "-eo", "pipefail", "-c", harness.replace('printf "%s\\0" "$@"', 'return 73') + command],
        env=environment, capture_output=True, text=True)
    return [] if failed.returncode == 73 else [".github/workflows/ci.yml: 证据服务失败需要结束所属步骤"]


def ci_trigger_shell_self_test(workflow_source: str) -> list[str]:
    source = workflow_source
    mutations = [
        re.sub(r"(?m)^  pull_request:.*\n", "", source),
        re.sub(r"(?m)^  push:\n    branches:.*\n", "", source),
        source.replace("jobs:", "defaults:\n  run:\n    shell: echo {0}\njobs:", 1),
        source.replace("    steps:", "    defaults:\n      run:\n        shell: echo {0}\n    steps:", 1),
    ]
    findings = ["代码质量规则边界自检失败：CI 自动触发与 shell 继承门禁"
                for changed in mutations if not ci_wiring_findings(changed)]
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
    for commit in ("BIT101_BASE_COMMIT", "BIT101_MERGE_COMMIT", "BIT101_RELEASE_COMMIT"):
        changed = workflow_source.replace(f'--get --data-urlencode "commit=${commit}"', '')
        if not ci_wiring_findings(changed):
            findings.append("代码质量规则边界自检失败：各提交证据请求隔离")
    return findings
