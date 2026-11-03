"""Check the GitHub workflow execution graph."""

import json
import re
import subprocess
import shlex
from validation_policy import workflow_timeout_seconds
from ci_diagnostics import diagnostic_path_list
from ci_wiring_support import (
    hook_documents_checked as hook_documents_checked,
    active_script_markers as active_script_markers,
    command_matches as command_matches,
    runner_expression as runner_expression,
    ci_result_wiring_findings as ci_result_wiring_findings,
    check_command_forbidden_ui as check_command_forbidden_ui,
    ci_ui_execution_findings as ci_ui_execution_findings,
    review_execution_findings as review_execution_findings,
    evidence_execution_findings as evidence_execution_findings,
    _evidence_execution_findings as _evidence_execution_findings,
    check_test_results_native_coverage as check_test_results_native_coverage,
    CI_RUNNER as CI_RUNNER,
    CI_RELEASE_CONTEXT as CI_RELEASE_CONTEXT,
    CI_NATIVE_CONTEXT as CI_NATIVE_CONTEXT,
    CI_STATIC_GATE as CI_STATIC_GATE,
    CI_CANCELLATION as CI_CANCELLATION,
    CI_CONCURRENCY_GROUP as CI_CONCURRENCY_GROUP,
    CI_PLANNED_GROUPS as CI_PLANNED_GROUPS,
    CI_EXECUTE as CI_EXECUTE,
    CI_EXECUTION as CI_EXECUTION,
    CI_NATIVE_EXECUTION as CI_NATIVE_EXECUTION,
    CI_NATIVE_REUSE as CI_NATIVE_REUSE,
    CI_STATIC_EXECUTION as CI_STATIC_EXECUTION,
    CI_DIAGNOSTICS as CI_DIAGNOSTICS,
    DIAGNOSTIC_PATHS as DIAGNOSTIC_PATHS,
)


def ci_wiring_findings(workflow_source: str, *, ui_only: bool = False) -> list[str]:
    errors: list[str] = []
    try:
        # YAML 1.1 将裸 on 识别为布尔值；保留 GitHub 工作流的事件键。
        source = re.sub(r"(?m)^on(?=\s*:)", '"on"', workflow_source)
        parsed = subprocess.run(
            [
                "ruby",
                "-ryaml",
                "-rjson",
                "-e",
                "puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))",
            ],
            input=source,
            capture_output=True,
            text=True,
            check=True,
        )
        workflow = json.loads(parsed.stdout)
        if not isinstance(workflow, dict):
            raise ValueError("工作流需要映射")
    except (OSError, subprocess.CalledProcessError, ValueError):
        return [".github/workflows/ci.yml: CI 工作流需要有效 YAML"]

    def mapping(value):
        return value if isinstance(value, dict) else {}

    if ui_only:
        return ci_ui_execution_findings(mapping(workflow.get("jobs")))

    cancellation = mapping(workflow.get("concurrency")).get("cancel-in-progress")
    concurrency_group = mapping(workflow.get("concurrency")).get("group")
    if (
        runner_expression(concurrency_group) != runner_expression(CI_CONCURRENCY_GROUP)
        or cancellation is not False
        and runner_expression(cancellation) != runner_expression(CI_CANCELLATION)
    ):
        errors.append(
            ".github/workflows/ci.yml: 发布真机需要独立并发组保留完整恢复时间，常规托管验证自动取消同分支旧运行"
        )

    def shell(step):
        value = mapping(step).get("run", "")
        return value if isinstance(value, str) else ""

    def step_has_role(step, role):
        step = mapping(step)
        if role == "Verify maintainer review commit":
            return step.get("id") == "review"
        artifacts = {
            "Preserve native compilation cache": "compilation-cache-",
            "Preserve validation diagnostics": "validation-${{ github.job }}",
            "Preserve App validation diagnostics": "validation-ios-test-shards-app-0",
        }
        if role in artifacts:
            name = str(mapping(step.get("with")).get("name", ""))
            return str(step.get("uses", "")).startswith("actions/upload-artifact@") and (
                name == artifacts[role]
                if role == "Preserve App validation diagnostics"
                else name.startswith(artifacts[role])
            )
        commands = {
            "Show toolchain": "Scripts/build-install-device.sh toolchain",
            "Reuse compatible successful validation": "python3 Scripts/ci_evidence.py reuse",
            "Run static audit": "Scripts/run-static-audit.sh",
            "Check current CI results": "python3 Scripts/ci_evidence.py current",
            "Download release validation evidence": "python3 Scripts/ci_evidence.py release",
            "Load target branch coverage baseline": "python3 Scripts/ci_evidence.py baseline",
            "Restore native compilation cache": "python3 Scripts/ci_evidence.py cache-restore",
            "Prepare native compilation cache": "python3 Scripts/ci_evidence.py cache-export",
            "Prepare full iOS Simulator": "Scripts/run-extended-tests.sh simulator prepare",
            "Run assigned complete Simulator inventory": (
                'Scripts/run-extended-tests.sh simulator "${{ matrix.mode }}"'
            ),
            "Run complete App behavior inventory": "Scripts/run-extended-tests.sh simulator app",
        }
        if role not in commands:
            return False
        expected = shlex.split(commands[role])
        try:
            return any(
                shlex.split(line, comments=True)[: len(expected)] == expected
                for line in shell(step).replace("\\\n", " ").splitlines()
            )
        except ValueError:
            return False

    events = workflow.get("on", {})
    events = (
        {events} if isinstance(events, str) else events if isinstance(events, (list, dict)) else {}
    )
    if not {"pull_request", "push"}.issubset(events):
        errors.append(".github/workflows/ci.yml: CI 需要 pull_request 和 push 自动触发")
    for event in ("pull_request", "push"):
        if {"paths", "paths-ignore"} & mapping(mapping(workflow.get("on")).get(event)).keys():
            errors.append(f".github/workflows/ci.yml: {event} 需要覆盖全部仓库路径")
    pull = mapping(mapping(workflow.get("on")).get("pull_request"))
    if (
        {"branches", "branches-ignore"} & pull.keys()
        or "types" in pull
        and (
            not isinstance(pull["types"], list)
            or not all(isinstance(item, str) for item in pull["types"])
            or not {"opened", "synchronize", "reopened"} <= set(pull["types"])
        )
    ):
        errors.append(
            ".github/workflows/ci.yml: pull_request 需要覆盖全部目标分支及打开、更新、重新打开事件"
        )
    push = mapping(mapping(workflow.get("on")).get("push"))
    if push.get("branches") != ["main"] or "branches-ignore" in push:
        errors.append(".github/workflows/ci.yml: push 需要覆盖 main 分支更新")
    jobs = mapping(workflow.get("jobs"))
    errors.extend(ci_ui_execution_findings(jobs))
    errors.extend(ci_result_wiring_findings(jobs))
    for name, job in jobs.items():
        for step in mapping(job).get("steps", []):
            action = str(mapping(step).get("uses", ""))
            if (
                action
                and not action.startswith(("./", "docker://"))
                and not re.fullmatch(r"[^@]+@[0-9a-f]{40}", action)
            ):
                errors.append(
                    f".github/workflows/ci.yml: {name} 的外部 Action 需要固定完整提交 SHA"
                )
        if runner_expression(mapping(job).get("runs-on")) != runner_expression(CI_RUNNER):
            errors.append(
                f".github/workflows/ci.yml: {name} 的隔离运行器需要使用 GitHub 托管的 xcode-27 镜像"
            )
        checkouts = [
            step
            for step in mapping(job).get("steps", [])
            if isinstance(step, dict) and str(step.get("uses", "")).startswith("actions/checkout@")
        ]
        if len(checkouts) != 1 or mapping(checkouts[0].get("with")).get("clean") is not False:
            errors.append(f".github/workflows/ci.yml: {name} 的 checkout 需要保留公共缓存")
        if (
            len(checkouts) != 1
            or "if" in checkouts[0]
            or checkouts[0].get("continue-on-error", False) is not False
            or mapping(checkouts[0].get("with")).get("fetch-depth") != 0
            or mapping(checkouts[0].get("with")).get("ref", "${{ github.sha }}")
            != "${{ github.sha }}"
        ):
            errors.append(
                f".github/workflows/ci.yml: {name} 的检出需要默认执行、完整提交历史及失败传播"
            )
        if not (name in DIAGNOSTIC_PATHS):
            continue
        uploads = [
            step
            for step in mapping(job).get("steps", [])
            if isinstance(step, dict)
            and str(step.get("uses", "")).startswith("actions/upload-artifact@")
            and step_has_role(step, "Preserve validation diagnostics")
        ]
        if (
            len(uploads) != 1
            or set(diagnostic_path_list(mapping(job).get("steps", []), uploads[0]).splitlines())
            != DIAGNOSTIC_PATHS[name]
        ):
            errors.append(
                f".github/workflows/ci.yml: {name} 的诊断上传需要采用所属任务的文件清单，人工附件保留在本地"
            )
        diagnostic_condition = CI_DIAGNOSTICS if name in CI_PLANNED_GROUPS else "${{ always() }}"
        if (
            len(uploads) != 1
            or uploads[0].get("if") != diagnostic_condition
            or mapping(uploads[0].get("with")).get("compression-level") != 0
            or mapping(uploads[0].get("with")).get("include-hidden-files") is not True
            or mapping(uploads[0].get("with")).get("overwrite") is not True
        ):
            errors.append(
                f".github/workflows/ci.yml: {name} 的诊断上传需要始终保存原始文件及隐藏路径"
            )
    planner = mapping(jobs.get("validation-plan"))
    plan_steps = [step for step in planner.get("steps", []) if step.get("id") == "plan"]
    if (
        planner.get("if") != CI_NATIVE_CONTEXT
        or planner.get("needs", []) != []
        or planner.get("continue-on-error", False) is not False
        or len(plan_steps) != 1
        or not command_matches(
            str(plan_steps[0].get("run") or ""), "python3 Scripts/ci_evidence.py plan"
        )
        or "if" in plan_steps[0]
        or plan_steps[0].get("continue-on-error", False) is not False
        or mapping(plan_steps[0].get("env")).get("GH_TOKEN") != "${{ github.token }}"
        or mapping(plan_steps[0].get("env")).get("BIT101_FULL_CHECK")
        != "${{ github.event_name == 'workflow_dispatch' && inputs.full_check }}"
        or mapping(plan_steps[0].get("env")).get("BIT101_RELEASE_CHECK")
        != "${{ github.event_name == 'workflow_dispatch' && inputs.release_check }}"
        or mapping(planner.get("outputs")).get("plan") != "${{ steps.plan.outputs.plan }}"
    ):
        errors.append(".github/workflows/ci.yml: 验证计划需要绑定手动全量、发布上下文与任务输出")
    for name, group in (CI_PLANNED_GROUPS | {"static-audit": "modules"}).items():
        job = mapping(jobs.get(name))
        environment = mapping(job.get("env"))
        reuse = [
            step
            for step in job.get("steps", [])
            if step_has_role(step, "Reuse compatible successful validation")
        ]
        if (
            environment.get("BIT101_CI_PLAN") != "${{ needs.validation-plan.outputs.plan }}"
            or environment.get("BIT101_CI_GROUP") != group
            or len(reuse) != 1
            or reuse[0].get("if")
            != (CI_NATIVE_REUSE if name == "static-audit" else "${{ !" + CI_EXECUTE + " }}")
            or not command_matches(
                str(reuse[0].get("run") or ""),
                'python3 Scripts/ci_evidence.py reuse "$BIT101_CI_GROUP"',
            )
            or reuse[0].get("continue-on-error", False) is not False
        ):
            errors.append(
                f".github/workflows/ci.yml: {name} 需要采用所属输入计划并展示成功结果来源"
            )
    if (
        mapping(mapping(jobs.get("ios-tests")).get("env")).get("BIT101_CI_PLAN")
        != "${{ needs.validation-plan.outputs.plan }}"
    ):
        errors.append(".github/workflows/ci.yml: 分片汇总需要核对增量计划中的来源提交与运行")
    workflow_defaults = mapping(mapping(workflow.get("defaults")).get("run"))
    default_shell = workflow_defaults.get("shell", "bash")

    def run_commands(job, *, include_always=False):
        commands = []
        job_defaults = mapping(mapping(job.get("defaults")).get("run"))
        shell = job_defaults.get("shell", default_shell)
        directory = job_defaults.get(
            "working-directory", workflow_defaults.get("working-directory", ".")
        )
        steps = job.get("steps", [])
        for step in steps if isinstance(steps, list) else []:
            step = mapping(step)
            if "run" not in step:
                continue
            if not isinstance(step["run"], str):
                errors.append(".github/workflows/ci.yml: 执行步骤需要 shell 文本")
                continue
            step = dict(step, **{"working-directory": step.get("working-directory", directory)})
            expected_directory = (
                "Cloudflare/EmergencyUpdateWorker"
                if command_matches(step["run"], "npm ci")
                else "."
            )
            if step["working-directory"] != expected_directory:
                errors.append(".github/workflows/ci.yml: 执行步骤需要沿所属仓库目录运行")
                continue
            if step.get("shell", shell) != "bash":
                errors.append(".github/workflows/ci.yml: CI 执行步骤需要 bash shell")
                continue
            planned = mapping(job.get("env")).get("BIT101_CI_GROUP") in {
                *CI_PLANNED_GROUPS.values(),
                "modules",
            }
            conditions = {CI_EXECUTION} if planned else set()
            if job is jobs.get("static-audit"):
                conditions.update(
                    {CI_NATIVE_EXECUTION, CI_NATIVE_REUSE, CI_STATIC_EXECUTION, CI_NATIVE_CONTEXT}
                )
            if include_always:
                conditions.update(
                    {
                        "always()",
                        "${{ always() }}",
                        "${{ !cancelled() }}",
                        "${{ !cancelled() && " + CI_EXECUTE + " }}",
                        CI_DIAGNOSTICS,
                    }
                )
            if (
                planned
                and mapping(job.get("env")).get("BIT101_CI_GROUP") != "modules"
                and not step_has_role(step, "Show toolchain")
                and step.get("if") not in conditions
            ):
                continue
            if (
                "if" in step
                and step["if"] not in conditions
                or step.get("continue-on-error", False) is not False
            ):
                continue
            command = step["run"]
            if isinstance(command, str):
                commands.append((command.strip(), step))
        return commands

    if not any(
        command_matches(command, "python3 Scripts/ci_evidence.py plan")
        for command, _ in run_commands(planner)
    ):
        errors.append(".github/workflows/ci.yml: 增量计划需要沿默认 shell 执行并传播失败")

    commands = {}
    for name in ("static-audit", "release-build", "catalyst-tests", "ios-tests", "ios-app-tests"):
        job = mapping(jobs.get(name))
        if not job:
            errors.append(f".github/workflows/ci.yml: CI 缺少 {name} Job")
            continue
        expected_gate = CI_STATIC_GATE if name == "static-audit" else CI_NATIVE_CONTEXT
        if job.get("if") != expected_gate or job.get("continue-on-error", False) is not False:
            errors.append(
                f".github/workflows/ci.yml: {name} 需要按静态与手动全量、发布范围执行并传播失败"
            )
        commands[name] = run_commands(job)
        if not any(
            command_matches(command, "Scripts/build-install-device.sh toolchain")
            for command, _ in commands[name]
        ):
            errors.append(f".github/workflows/ci.yml: {name} 的工具链版本核对需要共用构建脚本入口")
        if name not in {"ios-tests", "ios-app-tests"} and not any(
            command_matches(
                command, "python3 Scripts/validation_evidence.py summary --recorded-environment"
            )
            for command, _ in run_commands(job, include_always=True)
        ):
            errors.append(f".github/workflows/ci.yml: {name} 的证据汇总需要采用记录环境")
        expected_dependencies = [
            "validation-plan",
            *{"ios-tests": ["static-audit", "ios-app-tests"]}.get(name, []),
        ]
        dependencies = job.get("needs", [])
        if isinstance(dependencies, str):
            dependencies = [dependencies]
        if (
            not isinstance(dependencies, list)
            or any(not isinstance(value, str) for value in dependencies)
            or set(dependencies) != set(expected_dependencies)
        ):
            errors.append(f".github/workflows/ci.yml: {name} 需要按独立执行与最终汇总的依赖图运行")
    static_commands = commands.get("static-audit", [])
    audit_index = next(
        (
            index
            for index, (command, _) in enumerate(static_commands)
            if command_matches(command, "Scripts/run-extended-tests.sh verify audit modules")
        ),
        -1,
    )
    setup_index = next(
        (
            index
            for index, (command, step) in enumerate(static_commands)
            if command_matches(command, "npm ci")
            and step.get("working-directory") == "Cloudflare/EmergencyUpdateWorker"
        ),
        -1,
    )
    if audit_index < 0:
        errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    audit_only = [
        step
        for step in mapping(jobs.get("static-audit")).get("steps", [])
        if step_has_role(step, "Run static audit")
    ]
    if (
        len(audit_only) != 1
        or not command_matches(str(audit_only[0].get("run") or ""), "Scripts/run-static-audit.sh")
        or audit_only[0].get("if") != CI_STATIC_EXECUTION
        or audit_only[0].get("continue-on-error", False) is not False
        or not any(
            command_matches(command, "Scripts/run-static-audit.sh")
            for command, _ in static_commands
        )
        or audit_index >= 0
        and (
            static_commands[audit_index][1].get("if") != CI_NATIVE_EXECUTION
            or mapping(audit_only[0].get("env"))
            != mapping(static_commands[audit_index][1].get("env"))
        )
    ):
        errors.append(
            ".github/workflows/ci.yml: 推送与 PR 需要执行静态审计，模块测试限定在手动全量和发布流程"
        )
    release_expression = "${{ github.event_name == 'workflow_dispatch' && inputs.release_check }}"
    if (
        audit_index >= 0
        and mapping(static_commands[audit_index][1].get("env")).get("BIT101_RELEASE_CHECK")
        != release_expression
    ):
        errors.append(".github/workflows/ci.yml: 手动上传预检需要 App Store 版本前进核对")
    if setup_index < 0 or audit_index < 0 or setup_index >= audit_index:
        errors.append(".github/workflows/ci.yml: Worker 锁定依赖需要在静态审计前安装并传播失败")
    required = {
        "static-audit": (
            (
                "Scripts/run-extended-tests.sh verify audit modules",
                "静态审计与模块行为测试需要沿聚合入口执行并传播失败",
            ),
        ),
        "catalyst-tests": (
            (
                "Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime",
                "Mac Catalyst 行为 Job 需要聚合执行行为用例和正式组装合同",
            ),
        ),
        "release-build": (
            ("Scripts/build-install-device.sh archive", "CI 需要正式归档编译模式验证"),
            ("Scripts/run-extended-tests.sh build network-smoke", "CI 需要网络 Smoke 编译条件构建"),
            (
                "Scripts/run-extended-tests.sh build icloud-smoke",
                "CI 需要 iCloud Smoke 编译条件构建",
            ),
        ),
        "ios-tests": (
            (
                "Scripts/run-extended-tests.sh simulator merge",
                "模拟器 Job 需要汇总完整库存及覆盖率",
            ),
        ),
        "ios-app-tests": (
            ("Scripts/run-extended-tests.sh simulator prepare", "正式组装需要准备完整模拟器"),
            ("Scripts/run-extended-tests.sh simulator app", "App 行为需要执行完整合同库存"),
            (
                "Scripts/run-extended-tests.sh simulator release-runtime",
                "正式组装需要执行完整合同库存",
            ),
        ),
    }
    for name, rules in required.items():
        executed = {command for command, _ in commands.get(name, [])}
        for marker, message in rules:
            if not any(command_matches(command, marker) for command in executed):
                errors.append(f".github/workflows/ci.yml: {message}")
    if not isinstance(workflow.get("on"), dict) or "v*" not in mapping(
        workflow["on"].get("push")
    ).get("tags", []):
        errors.append(".github/workflows/ci.yml: 发布版本标签需要触发验收")
    acceptance = mapping(jobs.get("release-acceptance"))
    condition = (
        "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inpu"
        "ts.release_check"
    )
    if (
        acceptance.get("if") != condition
        or set(acceptance.get("needs", []))
        != {"static-audit", "release-build", "catalyst-tests", "ios-tests"}
        or acceptance.get("continue-on-error", False) is not False
    ):
        errors.append(".github/workflows/ci.yml: 发布验收需要承接完整编译和行为 Job")
    if not any(
        command_matches(command, "python3 Scripts/ci_evidence.py check-release")
        for command, _ in run_commands(acceptance)
    ):
        errors.append(".github/workflows/ci.yml: 发布验收需要默认核对提交绑定证据")
    merge = mapping(jobs.get("merge-acceptance"))
    if (
        merge.get("if") != "always() && !cancelled()"
        or set(merge.get("needs", []))
        != {"validation-plan", "static-audit", "release-build", "catalyst-tests", "ios-tests"}
        or merge.get("continue-on-error", False) is not False
    ):
        errors.append(
            ".github/workflows/ci.yml: 最终验收需要按所选范围核对静态、编译、Catalyst 与完整模拟器 Job"
        )
    result_steps = [
        step for step in merge.get("steps", []) if step_has_role(step, "Check current CI results")
    ]
    if (
        len(result_steps) != 1
        or mapping(result_steps[0].get("env")).get("BIT101_NATIVE_CHECK")
        != "${{ " + CI_NATIVE_CONTEXT + " }}"
    ):
        errors.append(".github/workflows/ci.yml: 最终验收需要绑定静态与完整验收范围")
    for name, command in (
        ("static-audit", "Scripts/run-extended-tests.sh verify audit modules"),
        (
            "catalyst-tests",
            "Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime",
        ),
        ("ios-tests", "Scripts/run-extended-tests.sh simulator merge"),
        ("ios-app-tests", "Scripts/run-extended-tests.sh simulator app"),
    ):
        steps = mapping(jobs.get(name)).get("steps", [])
        baseline_index = next(
            (
                index
                for index, step in enumerate(steps)
                if isinstance(step, dict)
                and step_has_role(step, "Load target branch coverage baseline")
            ),
            -1,
        )
        execution_index = next(
            (
                index
                for index, step in enumerate(steps)
                if isinstance(step, dict) and command_matches(str(step.get("run", "")), command)
            ),
            -1,
        )
        if not 0 <= baseline_index < execution_index:
            errors.append(f".github/workflows/ci.yml: {name} 基准载入需要先于当前分组记录")
    simulator = mapping(jobs.get("ios-tests"))
    formal_job = mapping(jobs.get("ios-app-tests"))
    for job in (simulator, formal_job):
        if mapping(job.get("env")).get("BIT101_SIMULATOR_AUTHORIZED") != "1" or any(
            "BIT101_SIMULATOR_AUTHORIZED" in mapping(step.get("env"))
            for step in job.get("steps", [])
            if isinstance(step, dict)
        ):
            errors.append(".github/workflows/ci.yml: 完整模拟器 CI 需要统一显式授权标记")
    from validation_coverage import SIMULATOR_SHARDS, SIMULATOR_WORKERS

    if (
        mapping(formal_job.get("env")).get("BIT101_CI_SHARD")
        != f"0/{SIMULATOR_SHARDS['release-runtime']}"
        or mapping(formal_job.get("env")).get("BIT101_SIMULATOR_WORKERS")
        != str(SIMULATOR_WORKERS["release-runtime"])
        or "strategy" in formal_job
    ):
        errors.append(".github/workflows/ci.yml: App 与正式组装需要共用完整库存和单个工作进程")
    app_steps = formal_job.get("steps", [])
    app_run = next(
        (
            i
            for i, step in enumerate(app_steps)
            if command_matches(
                str(step.get("run") or ""), "Scripts/run-extended-tests.sh simulator app"
            )
        ),
        -1,
    )
    formal_run = next(
        (
            i
            for i, step in enumerate(app_steps)
            if command_matches(
                str(step.get("run") or ""),
                "Scripts/run-extended-tests.sh simulator release-runtime",
            )
        ),
        -1,
    )
    app_upload = [
        step for step in app_steps if step_has_role(step, "Preserve App validation diagnostics")
    ]
    if (
        len(app_upload) != 1
        or not 0 <= app_run < app_steps.index(app_upload[0]) < formal_run
        or app_upload[0].get("if") != CI_DIAGNOSTICS
        or not str(app_upload[0].get("uses", "")).startswith("actions/upload-artifact@")
        or any(
            mapping(app_upload[0].get("with")).get(key) != value
            for key, value in {
                "name": "validation-ios-test-shards-app-0",
                "compression-level": 0,
                "include-hidden-files": True,
                "overwrite": True,
            }.items()
        )
        or set(diagnostic_path_list(app_steps, app_upload[0]).splitlines())
        != DIAGNOSTIC_PATHS["ios-app-tests"]
    ):
        errors.append(
            ".github/workflows/ci.yml: 同设备正式组装前需要顺序执行 App 库存并保留原始诊断上传"
        )
    for job, groups in (
        ("static-audit", ("audit", "modules")),
        ("release-build", ("build-archive", "network", "icloud")),
        ("catalyst-tests", ("catalyst", "catalyst-release-runtime")),
    ):
        timeout = mapping(jobs.get(job)).get("timeout-minutes")
        if type(timeout) is not int or timeout < workflow_timeout_seconds(groups) // 60 + 10:
            errors.append(f".github/workflows/ci.yml: {job} Job 需要覆盖所属执行及恢复预算")
    for job, minimum in (
        ("ios-app-tests", workflow_timeout_seconds(("all", "release-runtime")) // 60 + 10),
        ("ios-tests", 10),
    ):
        timeout = mapping(jobs.get(job)).get("timeout-minutes")
        if type(timeout) is not int or timeout < minimum:
            errors.append(f".github/workflows/ci.yml: {job} Job 需要覆盖所属执行及恢复预算")
    if mapping(workflow.get("permissions")).get("actions") != "read":
        errors.append(".github/workflows/ci.yml: 提交证据读取需要 Actions 读取权限")
    cache_condition = (
        "${{ github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name "
        "== 'workflow_dispatch')"
    )
    for name, flavor in {
        "release-build": "release-build",
        "catalyst-tests": "catalyst-tests",
        "ios-app-tests": "simulator-app",
    }.items():
        steps = mapping(jobs.get(name)).get("steps", [])
        restore = [
            step for step in steps if step_has_role(step, "Restore native compilation cache")
        ]
        prepare = [
            step for step in steps if step_has_role(step, "Prepare native compilation cache")
        ]
        save = [step for step in steps if step_has_role(step, "Preserve native compilation cache")]
        condition = "${{ (" + cache_condition.removeprefix("${{ ") + ") && " + CI_EXECUTE + " }}"
        save_condition = "${{ steps.native-cache.outcome == 'success' && " + condition.removeprefix(
            "${{ "
        )
        if (
            len(restore) != 1
            or not command_matches(
                str(restore[0].get("run") or ""),
                f'python3 Scripts/ci_evidence.py cache-restore "{flavor}"',
            )
            or restore[0].get("if") != CI_EXECUTION
            or mapping(restore[0].get("env")).get("GH_TOKEN") != "${{ github.token }}"
        ):
            errors.append(f".github/workflows/ci.yml: {name} 需要实际恢复所属原生编译缓存")
        if name == "ios-app-tests":
            boot = [step for step in steps if step_has_role(step, "Prepare full iOS Simulator")]
            network = [
                step
                for step in steps
                if (
                    step_has_role(step, "Restore native compilation cache")
                    or step_has_role(step, "Load target branch coverage baseline")
                )
            ]
            inventory = [
                step for step in steps if step_has_role(step, "Run complete App behavior inventory")
            ]
            if (
                len(boot) != 1
                or not command_matches(
                    str(boot[0].get("run") or ""), "Scripts/run-extended-tests.sh simulator prepare"
                )
                or len(network) != 2
                or len(inventory) != 1
                or not max(map(steps.index, network))
                < steps.index(boot[0])
                < steps.index(inventory[0])
            ):
                errors.append(
                    f".github/workflows/ci.yml: {name} 需要完成缓存与基准请求后启动完整模拟器，再执行测试库存"
                )
        if (
            len(prepare) != 1
            or prepare[0].get("if") != condition
            or not command_matches(
                str(prepare[0].get("run") or ""),
                f'python3 Scripts/ci_evidence.py cache-export "{flavor}"',
            )
            or prepare[0].get("id") != "native-cache"
            or len(save) != 1
            or save[0].get("if") != save_condition
        ):
            errors.append(
                f".github/workflows/ci.yml: {name} 的缓存发布需要来自 main 运行及唯一生产者"
            )
        if len(save) == 1 and any(
            mapping(save[0].get("with")).get(key) != value
            for key, value in {
                "name": "compilation-cache-" + flavor,
                "compression-level": 0,
                "overwrite": True,
                "include-hidden-files": True,
                "if-no-files-found": "error",
                "path": (
                    ".build/compiler-cache/CompilationCache.noindex\n.build/compiler-cache/compila"
                    "tion-cache.json\n.build/compiler-cache/swift-syntax-indexer\n.build/compiler-"
                    "cache/swift-syntax-indexer-inputs.json\n"
                ),
            }.items()
        ):
            errors.append(f".github/workflows/ci.yml: {name} 需要沿固定目录零压缩保存原生缓存")
        if any(step.get("continue-on-error") is not True for step in prepare + save):
            errors.append(f".github/workflows/ci.yml: {name} 的缓存准备与上传需要独立于验证结果")
    cleanup = mapping(jobs.get("compiler-cache-cleanup"))
    if (
        cleanup.get("if")
        != (
            "${{ always() && github.ref == 'refs/heads/main' && github.event_name == 'workflow_dis"
            "patch' && (inputs.full_check || inputs.release_check) }}"
        )
        or mapping(cleanup.get("permissions")) != {"contents": "read", "actions": "write"}
        or cleanup.get("needs") != ["release-build", "catalyst-tests", "ios-app-tests", "ios-tests"]
        or not any(
            command_matches(
                str(step.get("run") or ""), "python3 Scripts/ci_evidence.py cache-prune"
            )
            for step in cleanup.get("steps", [])
        )
    ):
        errors.append(".github/workflows/ci.yml: 缓存替换需要 main 专用的清理任务")
    if any(
        mapping(job.get("permissions")).get("actions", "read") != "read"
        for name, job in jobs.items()
        if name != "compiler-cache-cleanup"
    ):
        errors.append(".github/workflows/ci.yml: 验证任务沿 Actions 读取权限执行")
    for job, step_name, key, expression, expected in (
        (
            acceptance,
            "Download release validation evidence",
            "BIT101_RELEASE_TAG",
            "${{ inputs.validation_tag || github.ref_name }}",
            ["Scripts/ci_evidence.py", "release", "fixture"],
        ),
        (
            merge,
            "Check current CI results",
            "BIT101_REQUIRED_RESULTS",
            "${{ toJSON(needs) }}",
            ["Scripts/ci_evidence.py", "current", "--results", "fixture"],
        ),
        (
            mapping(jobs.get("static-audit")),
            "Load target branch coverage baseline",
            "BIT101_BASE_COMMIT",
            "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
            [
                "Scripts/ci_evidence.py",
                "baseline",
                "fixture",
                "Scripts/validation_evidence.py",
                "baseline",
                "fixture",
            ],
        ),
        (
            mapping(jobs.get("catalyst-tests")),
            "Load target branch coverage baseline",
            "BIT101_BASE_COMMIT",
            "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
            [
                "Scripts/ci_evidence.py",
                "baseline",
                "fixture",
                "Scripts/validation_evidence.py",
                "baseline",
                "fixture",
            ],
        ),
        (
            simulator,
            "Load target branch coverage baseline",
            "BIT101_BASE_COMMIT",
            "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
            [
                "Scripts/ci_evidence.py",
                "baseline",
                "fixture",
                "Scripts/validation_evidence.py",
                "baseline",
                "fixture",
            ],
        ),
        (
            formal_job,
            "Load target branch coverage baseline",
            "BIT101_BASE_COMMIT",
            "${{ github.event.pull_request.base.sha || steps.review.outputs.base_sha }}",
            [
                "Scripts/ci_evidence.py",
                "baseline",
                "fixture",
                "Scripts/validation_evidence.py",
                "baseline",
                "fixture",
            ],
        ),
    ):
        candidates = [
            step
            for step in job.get("steps", [])
            if isinstance(step, dict) and step_has_role(step, step_name)
        ]
        if (
            len(candidates) != 1
            or mapping(candidates[0].get("env")).get(key) != expression
            or mapping(candidates[0].get("env")).get("GH_TOKEN") != "${{ github.token }}"
        ):
            errors.append(".github/workflows/ci.yml: 合并与覆盖率证据请求需要所属提交身份")
            continue
        expected_condition = (
            CI_EXECUTION
            if mapping(job.get("env")).get("BIT101_CI_GROUP") in CI_PLANNED_GROUPS.values()
            else None
        )
        if job is jobs.get("static-audit"):
            expected_condition = CI_NATIVE_CONTEXT
        if (
            step_name == "Load target branch coverage baseline"
            and candidates[0].get("if") != expected_condition
        ):
            errors.append(".github/workflows/ci.yml: 每个执行入口需要设置所属覆盖率基准")
        step = candidates[0]
        if (
            step.get("continue-on-error", False) is not False
            or step.get("if") != expected_condition
        ):
            errors.append(".github/workflows/ci.yml: 提交证据读取失败需要传播")
        errors.extend(evidence_execution_findings(shell(step), key, expected))
    from validation_policy import REVIEW_JOB_NAMES

    if {
        mapping(jobs.get(name)).get("name")
        for name in ("static-audit", "release-build", "catalyst-tests", "ios-tests")
    } != REVIEW_JOB_NAMES:
        errors.append(".github/workflows/ci.yml: 审查证据需要核对四个实际 Job 名称")
    inputs = mapping(mapping(mapping(workflow.get("on")).get("workflow_dispatch")).get("inputs"))
    full_check = mapping(inputs.get("full_check"))
    if (
        full_check.get("type") != "boolean"
        or full_check.get("default") is not False
        or full_check.get("required") is not False
    ):
        errors.append(".github/workflows/ci.yml: 手动全量验收需要默认关闭的可选布尔输入 full_check")
    if (
        mapping(inputs.get("review_pr")).get("type") != "number"
        or mapping(inputs.get("review_pr")).get("default") != 0
        or workflow.get("run-name")
        != (
            "${{ inputs.review_pr && format('iOS CI review PR {0}', inputs.review_pr) || github.re"
            "f_name }}"
        )
    ):
        errors.append(".github/workflows/ci.yml: fork 审查需要 PR 输入与运行身份")
    for name in ("static-audit", "catalyst-tests", "ios-tests", "ios-app-tests"):
        steps = mapping(jobs.get(name)).get("steps", [])
        review = [
            (i, step)
            for i, step in enumerate(steps)
            if isinstance(step, dict) and step_has_role(step, "Verify maintainer review commit")
        ]
        next_step = "Load target branch coverage baseline"
        baseline = next(
            (
                i
                for i, step in enumerate(steps)
                if isinstance(step, dict) and step_has_role(step, next_step)
            ),
            -1,
        )
        if len(review) != 1:
            errors.append(".github/workflows/ci.yml: 审查提交验证需要唯一入口")
            continue
        position, step = review[0]
        if (
            position >= baseline
            or step.get("id") != "review"
            or step.get("if") != "github.event_name == 'workflow_dispatch' && inputs.review_pr > 0"
            or mapping(step.get("env"))
            != {"GH_TOKEN": "${{ github.token }}", "BIT101_REVIEW_PR": "${{ inputs.review_pr }}"}
            or step.get("continue-on-error", False) is not False
        ):
            errors.append(".github/workflows/ci.yml: 审查提交与基准需要沿所属 PR 顺序处理")
        if name == "static-audit" and any(
            shell(prior).strip() == "npm ci" for prior in steps[:position]
        ):
            errors.append(".github/workflows/ci.yml: 审查提交核对需要先于依赖安装")
        errors.extend(review_execution_findings(shell(step)))
    return errors
