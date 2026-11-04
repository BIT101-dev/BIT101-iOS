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
from ci_workflow_rules import ci_wiring_findings as ci_wiring_findings


def ci_trigger_shell_self_test(workflow_source: str) -> list[str]:
    source = workflow_source
    for name in ("validation-plan", *CI_PLANNED_GROUPS, "ios-tests"):
        block = re.search(r"(?ms)^  " + name + r":\n.*?(?=^  [\w-]+:|\Z)", source)[0]
        for condition in ("", "    if: true\n", "    if: github.event_name == 'pull_request'\n"):
            changed = block.replace("    if: " + CI_NATIVE_CONTEXT + "\n", condition, 1)
            assert changed != block and ci_wiring_findings(source.replace(block, changed, 1)), name
    for before, after in (
        (CI_STATIC_GATE, "${{ success() }}"),
        (CI_NATIVE_EXECUTION, CI_EXECUTION),
        (CI_STATIC_EXECUTION, "${{ !" + CI_EXECUTE + " }}"),
        ("BIT101_NATIVE_CHECK: ${{ " + CI_NATIVE_CONTEXT + " }}", "BIT101_NATIVE_CHECK: false"),
    ):
        assert ci_wiring_findings(source.replace(before, after)), before
    for before, after in (
        (
            "      - name: Preserve native compilation cache\n        continue-on-error: true",
            "      - name: Preserve native compilation cache",
        ),
        (
            (
                "BIT101_FULL_CHECK: ${{ github.event_name == 'workflow_dispatch' && inputs.full_ch"
                "eck }}"
            ),
            "BIT101_FULL_CHECK: false",
        ),
        ("      full_check:", "      unused_check:"),
        (
            (
                "description: Run full compilation, module and behavior validation\n        requir"
                "ed: false\n        default: false\n        type: boolean"
            ),
            (
                "description: Run full compilation, module and behavior validation\n        requir"
                "ed: false\n        default: false\n        type: string"
            ),
        ),
        ("run: python3 Scripts/ci_evidence.py plan", "run: true"),
        ("${{ steps.plan.outputs.plan }}", "${{ steps.unused.outputs.plan }}"),
        ("BIT101_CI_GROUP: app", "BIT101_CI_GROUP: ui"),
        ('run: python3 Scripts/ci_evidence.py reuse "$BIT101_CI_GROUP"', "run: true"),
        ("BIT101_CI_PLAN: ${{ needs.validation-plan.outputs.plan }}", 'BIT101_CI_PLAN: "{}"'),
        ("run: Scripts/run-static-audit.sh", "run: true"),
        (CI_EXECUTION, "${{ false }}"),
    ):
        assert ci_wiring_findings(source.replace(before, after)), before
    for selector in ('"xcode-27"', "'xcode-27'"):
        assert not ci_wiring_findings(source.replace("runs-on: xcode-27", "runs-on: " + selector))
    for selector in ("macos-latest", "[self-hosted, macOS, bit101-xcode-27, bit101-ci]"):
        assert any(
            "隔离运行器" in row
            for row in ci_wiring_findings(
                source.replace("runs-on: xcode-27", "runs-on: " + selector, 1)
            )
        )
    assert runner_expression(CI_CANCELLATION.replace(" && ", "  && ")) == runner_expression(
        CI_CANCELLATION
    )
    assert runner_expression(CI_CANCELLATION.replace("!(", "! =(")) != runner_expression(
        CI_CANCELLATION
    )
    for replacement in ("xcodebuild -version", "echo skipped"):
        assert any(
            "工具链版本核对" in row
            for row in ci_wiring_findings(
                source.replace("Scripts/build-install-device.sh toolchain", replacement, 1)
            )
        )
    for cancellation in ("true", "[]", "{}", "0", "${{ github.event_name == 'pull_request' }}"):
        assert any(
            "完整恢复时间" in row
            for row in ci_wiring_findings(source.replace(CI_CANCELLATION, cancellation))
        )
    assert not ci_wiring_findings(source.replace(CI_CANCELLATION, "false"))
    assert any(
        "完整恢复时间" in row
        for row in ci_wiring_findings(
            source.replace(CI_CONCURRENCY_GROUP, "ios-ci-${{ github.ref }}")
        )
    )
    catalyst_start = source.index("  catalyst-tests:")
    baseline_start = source.index(
        "      - name: Load target branch coverage baseline", catalyst_start
    )
    baseline_end = source.index("      - ", baseline_start + 8)
    baseline = source[baseline_start:baseline_end]
    removed = source[:baseline_start] + source[baseline_end:]
    assert any("catalyst-tests 基准载入" in row for row in ci_wiring_findings(removed))
    execution = removed.index(
        "run: Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime",
        catalyst_start,
    )
    after = removed.index("\n", execution) + 1
    assert any(
        "catalyst-tests 基准载入" in row
        for row in ci_wiring_findings(removed[:after] + baseline + removed[after:])
    )
    conditional = source.replace(
        "      - name: Load target branch coverage baseline\n        if: "
        + CI_NATIVE_CONTEXT
        + "\n",
        (
            "      - name: Load target branch coverage baseline\n        if: github.event_name == "
            "'pull_request'\n"
        ),
        1,
    )
    assert any("每个执行入口" in row for row in ci_wiring_findings(conditional))
    tag_store_check = source.replace(
        (
            "BIT101_RELEASE_CHECK: ${{ github.event_name == 'workflow_dispatch' && inputs.release_"
            "check }}"
        ),
        (
            "BIT101_RELEASE_CHECK: ${{ startsWith(github.ref, 'refs/tags/v') || (github.event_name"
            " == 'workflow_dispatch' && inputs.release_check) }}"
        ),
    )
    assert any("App Store 版本前进核对" in row for row in ci_wiring_findings(tag_store_check))
    for action in re.findall(r"actions/(?:checkout|upload-artifact)@[0-9a-f]{40}", source):
        for reference in ("v7", "1234567"):
            changed = source.replace(action, action.split("@")[0] + "@" + reference, 1)
            assert any("完整提交 SHA" in item for item in ci_wiring_findings(changed))
    checkout = re.search(r"actions/checkout@[0-9a-f]{40}", source)[0]
    if not any(
        "采用记录环境" in item
        for item in ci_wiring_findings(
            source.replace("summary --recorded-environment", "summary", 1)
        )
    ):
        return ["代码质量规则界限自检失败：CI 证据汇总的执行环境标准"]
    review_start = source.index("      - name: Verify maintainer review commit")
    review_end = source.index("      - name: Show toolchain", review_start)
    review = source[review_start:review_end]
    reordered = source[:review_start] + source[review_end:]
    position = reordered.index("      - name: Load target branch coverage baseline")
    reordered = reordered[:position] + review + reordered[position:]
    if not any("先于依赖安装" in item for item in ci_wiring_findings(reordered)):
        return ["代码质量规则界限自检失败：审查提交核对与依赖安装顺序"]
    if not any(
        "诊断" in item
        for item in ci_wiring_findings(
            source.replace(
                ".build/extended-automation/test-results.xcresult",
                ".build/extended-automation/omitted",
            )
        )
    ):
        return ["代码质量规则界限自检失败：CI 原始附件留存门禁"]
    if not ci_wiring_findings(source.replace("          clean: false", "          clean: true")):
        return ["代码质量规则界限自检失败：CI 共享缓存保留门禁"]
    mutations = [
        re.sub(r"(?m)^  pull_request:.*\n", "", source),
        re.sub(r"(?m)^  push:\n    branches:.*\n", "", source),
        source.replace("jobs:", "defaults:\n  run:\n    shell: echo {0}\njobs:", 1),
        source.replace(
            "    steps:", "    defaults:\n      run:\n        shell: echo {0}\n    steps:", 1
        ),
        source.replace("  pull_request:\n", "  pull_request:\n    branches: [unused-branch]\n"),
        source.replace("  pull_request:\n", "  pull_request:\n    branches-ignore: ['**']\n"),
        source.replace("  pull_request:\n", "  pull_request:\n    types: [closed]\n"),
        source.replace("    branches: [main]", "    branches: [unused-branch]"),
        source.replace("    branches: [main]", "    branches-ignore: ['**']"),
    ]
    for types in (
        "[opened, synchronize, reopened]",
        "[opened, synchronize, reopened, ready_for_review]",
    ):
        assert not ci_wiring_findings(
            source.replace("  pull_request:\n", f"  pull_request:\n    types: {types}\n")
        )
    findings = [
        "代码质量规则界限自检失败：CI 自动触发与 shell 继承门禁"
        for changed in mutations
        if not ci_wiring_findings(changed)
    ]
    for name in DIAGNOSTIC_PATHS:
        for required_path in DIAGNOSTIC_PATHS[name]:
            omitted = re.sub(
                (
                    f"(?s)(  "
                    f"{name}"
                    f":.*?- name: Select validation diagnostics.*?          BIT101_DIAGNOSTIC_PA"
                    f"THS: \\|\\n)(.*?)(?=\\n  [a-z]|\\Z)"
                ),
                lambda match: (
                    match[1] + match[2].replace("            " + required_path + "\n", "")
                ),
                workflow_source,
                count=1,
            )
            if not any("诊断上传" in item for item in ci_wiring_findings(omitted)):
                findings.append(f"代码质量规则界限自检失败：{name} 的必要诊断文件")
        compressed = re.sub(
            (
                f"(?s)(  "
                f"{name}"
                f":.*?      - name: Preserve validation diagnostics.*?)          compression-lev"
                f"el: 0"
            ),
            r"\1          compression-level: 9",
            workflow_source,
            count=1,
        )
        if not any("始终保存原始文件" in item for item in ci_wiring_findings(compressed)):
            findings.append(f"代码质量规则界限自检失败：{name} 的原始诊断上传")
        private_paths = {
            ".build/extended-automation/validation-evidence.json",
            ".build/extended-automation/**",
            ".build/extended-automation/test-results.xcresult",
        } - DIAGNOSTIC_PATHS[name]
        for private_path in sorted(private_paths):
            exposed = re.sub(
                (
                    f"(?s)(  "
                    f"{name}"
                    f":.*?      - name: Select validation diagnostics.*?          BIT101_DIAGNOS"
                    f"TIC_PATHS: \\|\\n)"
                ),
                lambda match: match[1] + "            " + private_path + "\n",
                workflow_source,
                count=1,
            )
            if not any("诊断上传" in item for item in ci_wiring_findings(exposed)):
                findings.append(f"代码质量规则界限自检失败：{name} 的历史附件隔离")
    cache_start = source.index("      - name: Preserve native compilation cache")
    cache_end = source.index("      - name: ", cache_start + 8)
    cache_step = source[cache_start:cache_end]
    for before, after in [
        ("compression-level: 0", "compression-level: 6"),
        ("overwrite: true", "overwrite: false"),
        ("include-hidden-files: true", "include-hidden-files: false"),
        ("CompilationCache.noindex", "**"),
        ("github.ref == 'refs/heads/main'", "true"),
    ]:
        assert any(
            "缓存" in row
            for row in ci_wiring_findings(
                source.replace(cache_step, cache_step.replace(before, after), 1)
            )
        ), before
    boot_step = (
        "      - name: Prepare full iOS Simulator\n        if: "
        + CI_EXECUTION
        + "\n        run: Scripts/run-extended-tests.sh simulator prepare\n"
    )
    for name in ("ios-app-tests",):
        block = re.search(r"(?ms)^  " + name + r":\n.*?(?=^  [\w-]+:|\Z)", source)[0]
        anchors = (
            "Restore native compilation cache",
            "Load target branch coverage baseline",
            "Prepare native compilation cache",
        )
        for anchor in anchors:
            reordered = block.replace(boot_step, "").replace(
                "      - name: " + anchor, boot_step + "      - name: " + anchor, 1
            )
            marker = "缓存与基准请求后"
            assert any(
                marker in row for row in ci_wiring_findings(source.replace(block, reordered, 1))
            ), (name, anchor)
    app_block = re.search(r"(?ms)^  ios-app-tests:\n.*?(?=^  [\w-]+:|\Z)", source)[0]
    upload = app_block[
        app_block.index("      - name: Select validation diagnostics") : app_block.index(
            "      - name: Run complete formal runtime inventory"
        )
    ]
    for replacement in (
        "",
        upload.replace("validation-ios-test-shards-app-0", "validation-unused"),
        upload.replace("compression-level: 0", "compression-level: 6"),
        upload.replace("            .build/extended-automation/test-results.xcresult\n", ""),
    ):
        assert any(
            "同设备" in row for row in ci_wiring_findings(source.replace(upload, replacement, 1))
        )
    reordered = app_block.replace(upload, "").replace(
        "      - name: Prepare native compilation cache",
        upload + "      - name: Prepare native compilation cache",
        1,
    )
    assert any(
        "同设备" in row for row in ci_wiring_findings(source.replace(app_block, reordered, 1))
    )
    for name in (
        "static-audit",
        "release-build",
        "catalyst-tests",
        "ios-tests",
        "release-acceptance",
        "merge-acceptance",
    ):
        for selector in (
            "[self-hosted, macOS, bit101-xcode-27, bit101-ci]",
            "macos-latest",
            "${{ github.event_name == 'push' && 'xcode-27' || 'macos-latest' }}",
        ):
            unsafe = re.sub(
                rf"(?s)(  {name}:.*?)runs-on: " + re.escape(CI_RUNNER),
                lambda match: match[1] + "runs-on: " + selector,
                workflow_source,
                count=1,
            )
            if not any("隔离运行器" in item for item in ci_wiring_findings(unsafe)):
                findings.append(f"代码质量规则界限自检失败：{name} 的运行器隔离")
        discarded = re.sub(
            rf"(?s)(  {name}:.*?)          clean: false",
            r"\1          clean: true",
            workflow_source,
            count=1,
        )
        if not any("保留公共缓存" in item for item in ci_wiring_findings(discarded)):
            findings.append(f"代码质量规则界限自检失败：{name} 的编译缓存保存")
    for name in (
        "static-audit",
        "release-build",
        "catalyst-tests",
        "ios-tests",
        "release-acceptance",
        "merge-acceptance",
    ):
        for before, after in (
            (f"      - uses: {checkout}", f"      - if: false\n        uses: {checkout}"),
            ("          fetch-depth: 0", "          fetch-depth: 1"),
            ("          clean: false", "          clean: false\n          ref: main"),
            (
                f"      - uses: {checkout}",
                f"      - continue-on-error: true\n        uses: {checkout}",
            ),
        ):
            changed = re.sub(
                rf"(?s)(  {name}:.*?)" + re.escape(before),
                lambda match: match[1] + after,
                workflow_source,
                count=1,
            )
            if not any("完整提交历史" in item for item in ci_wiring_findings(changed)):
                findings.append(f"代码质量规则界限自检失败：{name} 的完整仓库检出")
    if not ci_wiring_findings(workflow_source.replace("run: npm ci", "run: echo skipped", 1)):
        findings.append("代码质量规则界限自检失败：Worker 冷启动依赖准备")
    for command in (
        "Scripts/run-extended-tests.sh verify audit modules",
        "Scripts/run-extended-tests.sh build network-smoke",
        "Scripts/run-extended-tests.sh simulator release-runtime",
        "Scripts/run-extended-tests.sh simulator merge",
        "Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime",
    ):
        for modifier in (
            "if: false",
            "continue-on-error: true",
            "shell: echo {0}",
            "working-directory: Cloudflare",
        ):
            skipped = workflow_source.replace(
                f"        run: {command}", f"        {modifier}\n        run: {command}"
            )
            if not ci_wiring_findings(skipped):
                findings.append("代码质量规则界限自检失败：CI 步骤条件与失败传播门禁")
    downgraded_release = workflow_source.replace(
        "  release-acceptance:\n", "  release-acceptance:\n    continue-on-error: true\n"
    )
    if not ci_wiring_findings(downgraded_release):
        findings.append("代码质量规则界限自检失败：发布验收的失败传播")
    for job in ("release-build", "ios-app-tests"):
        serialized = re.sub(
            r"(?m)(^  " + job + r":\n)(?:    needs:.*\n)?",
            r"\1    needs: static-audit\n",
            workflow_source,
            count=1,
        )
        assert any("依赖图" in item for item in ci_wiring_findings(serialized))
    for dependency in (
        "",
        "    needs: release-build\n",
        "    needs: static-audit\n",
        "    needs: [validation-plan, release-build, static-audit]\n",
    ):
        changed = workflow_source.replace(
            "  catalyst-tests:\n    needs: [validation-plan]\n", "  catalyst-tests:\n" + dependency
        )
        assert any("依赖图" in row for row in ci_wiring_findings(changed))
    for dependency in ("    needs: release-build\n", "    needs: static-audit\n"):
        changed = workflow_source.replace(
            "  ios-app-tests:\n    needs: [validation-plan]\n", "  ios-app-tests:\n" + dependency
        )
        assert any("依赖图" in row for row in ci_wiring_findings(changed))
    detached = workflow_source.replace(
        "needs: [validation-plan, static-audit, ios-app-tests]", "needs: []", 1
    )
    assert any("依赖图" in item for item in ci_wiring_findings(detached))
    detached_formal = workflow_source.replace(
        "needs: [validation-plan, static-audit, ios-app-tests]", "needs: [static-audit]", 1
    )
    assert any("依赖图" in item for item in ci_wiring_findings(detached_formal))
    misplaced_audit = workflow_source.replace(
        "run: Scripts/run-extended-tests.sh verify audit modules", "run: echo skipped", 1
    )
    misplaced_audit += "\n# Scripts/run-extended-tests.sh verify audit modules\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则界限自检失败：CI 注释中的审计标记隔离")
    skipped_catalyst = workflow_source.replace(
        "run: Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime",
        "run: echo skipped",
        1,
    )
    if not any(
        "Catalyst 行为 Job 需要聚合执行" in item for item in ci_wiring_findings(skipped_catalyst)
    ):
        findings.append("代码质量规则界限自检失败：并行 Catalyst 行为用例执行门禁")
    for before, after in (
        ("timeout-minutes: 105", "timeout-minutes: 20"),
        ('baseline "$BIT101_BASE_COMMIT"', 'baseline "wrong-commit"'),
    ):
        assert ci_wiring_findings(workflow_source.replace(before, after))
    for before, after in (
        ("BIT101_SIMULATOR_AUTHORIZED: '1'", "BIT101_SIMULATOR_AUTHORIZED: '0'"),
        (
            "needs: [validation-plan, static-audit, release-build, catalyst-tests, ios-tests]",
            "needs: [validation-plan, static-audit, release-build, catalyst-tests]",
        ),
        (
            (
                "if: startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispa"
                "tch' && inputs.release_check"
            ),
            "if: github.event_name == 'push'",
        ),
    ):
        if not ci_wiring_findings(workflow_source.replace(before, after)):
            findings.append("代码质量规则界限自检失败：完整模拟器合并验收与发布真机分支")
    assert ci_wiring_findings(
        workflow_source.replace("run: Scripts/run-extended-tests.sh simulator merge", "run: true")
    )
    for before, after in (
        ("Scripts/build-install-device.sh toolchain", "Scripts/build-install-device.sh  toolchain"),
        (
            "Scripts/run-extended-tests.sh build network-smoke",
            "Scripts/run-extended-tests.sh build   network-smoke",
        ),
        ("npm ci", "npm  ci"),
    ):
        if ci_wiring_findings(workflow_source.replace(before, after)):
            findings.append("代码质量规则界限自检失败：CI 命令参数间距保持执行约定")
    for replacement in (
        "\"'Scripts/build-install-device.sh toolchain'\"",
        "Scripts/build-install-device.sh toolchain extra",
    ):
        if not ci_wiring_findings(
            workflow_source.replace(
                "run: Scripts/build-install-device.sh toolchain", "run: " + replacement
            )
        ):
            findings.append("代码质量规则界限自检失败：CI 可执行文件与参数界限")
    for job in ("static-audit", "release-build", "catalyst-tests", "ios-app-tests"):
        changed = re.sub(
            r"(?s)(  " + job + r":.*?timeout-minutes:) \d+", r"\1 20", workflow_source, count=1
        )
        if not any(
            job + " Job 需要覆盖所属执行及恢复预算" in item for item in ci_wiring_findings(changed)
        ):
            findings.append(f"代码质量规则界限自检失败：{job} 执行预算")
    release_minimum = workflow_timeout_seconds(("build-archive", "network", "icloud")) // 60 + 10
    for timeout, expected in ((45, True), (release_minimum - 1, True), (release_minimum, False)):
        changed = re.sub(
            r"(?s)(  release-build:.*?timeout-minutes:) \d+",
            lambda match: match[1] + " " + str(timeout),
            workflow_source,
            count=1,
        )
        actual = any(
            "release-build Job 需要覆盖所属执行及恢复预算" in item
            for item in ci_wiring_findings(changed)
        )
        if actual != expected:
            findings.append("代码质量规则界限自检失败：Release 多构建流程预算界限")
    return findings


def audit_wiring_findings(
    ROOT, scheme_inventory_findings, extension_dependency_findings
) -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    SCRIPT_ROOT = ROOT / "Scripts"
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    errors.extend(audit_callback_findings(audit_source))
    groups = re.search(r"(?ms)^group_names=\((.*?)\)(?=[ \t]*(?:\n|$))", audit_source)
    commands = re.search(r"(?ms)^group_commands=\((.*?)\)(?=[ \t]*(?:\n|$))", audit_source)
    group_names = shlex.split(groups[1].replace("\\\n", ""), comments=True) if groups else []
    group_commands = shlex.split(commands[1].replace("\\\n", ""), comments=True) if commands else []
    wiring = (
        dict(zip(group_names, group_commands)) if len(group_names) == len(group_commands) else {}
    )
    expected = {
        "swift-parse": "swift_parse",
        "shell-parse": "shell_parse",
        "python-parse": "python_parse",
        "worker-parse": "worker_parse",
        "dependency-audit": "dependency_audit",
        "module-boundary": "module_boundary_audit",
        "git-diff": "git_check",
        "docs": "docs_check",
        "checkers": "bit101_checker_audit",
    }
    if wiring != expected or len(group_names) != len(expected):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要逐组接入完整契约")
    if not re.search(
        r"(?m)^\s*bit101_run_audit_group\s+artifact-hygiene\s+artifact_hygiene(?:\s|$)",
        audit_source,
    ):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要接入产物清理检查")
    if "npm audit --audit-level=high" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 依赖漏洞审计门槛缺失")
    if "release-network-smoke" in audit_source:
        errors.append(
            "Scripts/run-static-audit.sh: 静态审计负责本地规则检查，网络 smoke 通过独立入口执行"
        )

    workflow_path = ROOT / ".github/workflows/ci.yml"
    if not workflow_path.is_file():
        errors.append(".github/workflows/ci.yml: CI 工作流不存在")
    else:
        errors.extend(ci_wiring_findings(workflow_path.read_text(encoding="utf-8")))
    for additional in sorted(workflow_path.parent.glob("*")):
        if additional != workflow_path and additional.suffix in {".yml", ".yaml"}:
            errors.extend(
                message.replace(".github/workflows/ci.yml", additional.relative_to(ROOT).as_posix())
                for message in ci_wiring_findings(
                    additional.read_text(encoding="utf-8"), ui_only=True
                )
            )
    project = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"),
            ],
            text=True,
        )
    )
    errors.extend(
        scheme_inventory_findings(
            {
                path.name: path.read_text()
                for path in (ROOT / "BIT101-iOS.xcodeproj/xcshareddata/xcschemes").glob(
                    "*.xcscheme"
                )
            }
        )
    )
    errors.extend(extension_dependency_findings(project))
    project_settings = project["objects"][
        project["objects"][project["rootObject"]]["buildConfigurationList"]
    ]["buildConfigurations"]
    for identifier in project_settings:
        configuration = project["objects"][identifier]
        if not (
            configuration.get(("isa")) == ("XCBuildConfiguration")
            and ("SWIFT_COMPILATION_MODE") in configuration.get(("buildSettings"), {})
        ):
            continue
        if "$(BIT101_WORKFLOW_CONDITIONS)" not in configuration["buildSettings"].get(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""
        ):
            errors.append("App 工程编译条件需要接入工作流变量")
    for name in (
        "run-extended-tests.sh",
        "run_icloud_cross_device_smoke.sh",
        "release-network-smoke.sh",
    ):
        if "SWIFT_ACTIVE_COMPILATION_CONDITIONS=" in (SCRIPT_ROOT / name).read_text():
            errors.append(f"{name}: 工作流条件需要限定在 App 工程")

    test_script = ROOT / "Scripts/run-extended-tests.sh"
    if not test_script.is_file():
        errors.append("Scripts/run-extended-tests.sh: 真机测试入口不存在")
    else:
        test_source = active_script_markers(test_script.read_text(encoding="utf-8"))
        if not check_test_results_native_coverage((SCRIPT_ROOT / "test_results.py").read_text()):
            errors.append("Scripts/test_results.py: 原生指标处理需要提取代码覆盖率")
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
