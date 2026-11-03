#!/usr/bin/env python3
"""Exchange fixed validation evidence through commit-scoped GitHub Actions and release assets."""

import argparse
import ast
import json
import os
import re
import subprocess
import sys
import shutil
import zipfile
from types import SimpleNamespace
from pathlib import Path
from functools import cache
from validation_publication import RECEIPT, release_receipt, receipt_findings
from validate_versions import PROJECT_PATH, extract_versions, validate_release_tag
from ci_cache_evidence import (
    read_validation_result as read_validation_result,
    cache_identity as cache_identity,
    export_cache as export_cache,
    extract_cache_member as extract_cache_member,
    restore_cache_payload as restore_cache_payload,
    trusted_cache_run as trusted_cache_run,
    native_cache_available as native_cache_available,
    restore_cache as restore_cache,
    restore_remote_cache as restore_remote_cache,
    cache_result_matches as cache_result_matches,
    prune_caches as prune_caches,
    download_cache_payload as download_cache_payload,
    stream_cache_range as stream_cache_range,
    cache_download_self_test as cache_download_self_test,
    cache_self_test as cache_self_test,
    repository as repository,
    api_pages as api_pages,
)


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
REQUIRED_JOBS = {"validation-plan", "static-audit", "release-build", "catalyst-tests", "ios-tests"}
CACHE_FLAVORS = {"release-build", "catalyst-tests", "simulator-app"}
CACHE_ROOT = ROOT / ".build/compiler-cache"
CACHE_STORE = "CompilationCache.noindex"
CACHE_METADATA = "compilation-cache.json"
CACHE_TOOLS = frozenset({"swift-syntax-indexer", "swift-syntax-indexer-inputs.json"})
RESULT_FILE = ROOT / ".build/extended-automation/ci-validation-result.json"


@cache
def ci_validation_environment(group: str) -> dict:
    from validation_environment import environment_context, toolchain_identity

    context = environment_context("modules" if group == "modules" else "build-release")
    identity = dict(host=context["host"], toolchain=toolchain_identity(context))
    if group == "app":
        data = json.loads(
            subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"], text=True)
        )
        identity["runtimes"] = [
            {"systemVersion": row["version"], "systemBuild": row["buildversion"]}
            for row in data["runtimes"]
            if row.get("isAvailable") and ".iOS-" in row["identifier"]
        ]
    return identity


def result_environment_matches(group: str, environment: dict) -> bool:
    current = dict(ci_validation_environment(group))
    runtimes = current.pop("runtimes", [])
    recorded = dict(environment)
    platform = recorded.pop("platform", None)
    return recorded == current and (platform in runtimes if group == "app" else platform is None)


def validation_result(candidate: dict, group: str) -> dict | None:
    from validation_inputs import CI_RESULT_ARTIFACTS

    artifact = next(
        (
            row
            for row in candidate["artifacts"]
            if row["name"] == CI_RESULT_ARTIFACTS[group] and not row.get("expired")
        ),
        {},
    )
    if type(artifact.get("id")) is not int:
        return None
    return read_validation_result(repository(), artifact["id"])


def reusable_validation_result(candidate: dict, group: str) -> bool:
    from validation_inputs import CI_VALIDATION_GROUPS

    result = validation_result(candidate, group)
    if (
        not isinstance(result, dict)
        or result.get("schemaVersion") != 1
        or result.get("commit") != candidate["head_sha"]
        or result.get("run") != str(candidate["id"])
    ):
        return False
    groups = result.get("groups")
    if not isinstance(groups, dict):
        return False
    row = groups.get(group, {})
    scopes = CI_VALIDATION_GROUPS[group][0]
    return (
        isinstance(row, dict)
        and row.get("passed") is True
        and row.get("scopes") == list(scopes)
        and isinstance(row.get("environment"), dict)
        and result_environment_matches(group, row["environment"])
    )


def export_validation_result(group: str) -> None:
    from validation_environment import ci_commit_findings, toolchain_identity
    from validation_inputs import CI_VALIDATION_GROUPS
    from validation_evidence import group_complete
    from validation_provenance import complete_group_row

    plan = read_validation_plan()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if errors := ci_commit_findings(commit):
        raise ValueError("\n".join(errors))
    report = json.loads(REPORT.read_text())
    from validation_simulator import result_rows

    rows = (
        result_rows(report, plan, commit, os.environ["GITHUB_RUN_ID"], result_environment_matches)
        if group == "ios"
        else {}
    )
    for name in () if group == "ios" else (group,):
        if not plan["jobs"][name]["execute"]:
            continue
        scopes = CI_VALIDATION_GROUPS[name][0]
        environments = []
        for scope in scopes:
            if not group_complete(report, scope, recorded_environment=True):
                raise ValueError(f"{scope} 需要当前输入的完整成功证据。")
            row = complete_group_row(report["groups"][scope])
            context = row["environment"]
            environment = dict(host=context["host"], toolchain=toolchain_identity(context))
            current = dict(ci_validation_environment(name))
            current.pop("runtimes", None)
            if environment != current:
                raise ValueError(f"{scope} 的工具链与 SDK 需要对应当前任务。")
            environments.append(environment)
        if any(value != environments[0] for value in environments):
            raise ValueError("同组验收需要同一执行环境。")
        rows[name] = dict(passed=True, scopes=list(scopes), environment=environments[0])
    if not rows:
        raise ValueError("结果记录需要本次完整验收的验证组。")
    RESULT_FILE.parent.mkdir(parents=True, exist_ok=True)
    RESULT_FILE.write_text(
        json.dumps(
            dict(schemaVersion=1, commit=commit, run=os.environ["GITHUB_RUN_ID"], groups=rows)
        )
        + "\n"
    )


def select_validation_plan(
    commit: str, run_id: str, candidates, changed_files, *, full: bool = False
) -> dict:
    from validation_inputs import CI_VALIDATION_GROUPS, ci_validation_affected

    jobs = {
        group: {"execute": True, "reason": "完整验收" if full else "建立当前输入的成功结果"}
        for group in CI_VALIDATION_GROUPS
    }
    pending = set() if full else set(jobs)
    for candidate in () if full else candidates:
        changed = changed_files(candidate["head_sha"])
        observed = {job["name"]: job for job in candidate["jobs"]}
        artifacts = {row["name"] for row in candidate["artifacts"] if not row.get("expired")}
        for group in tuple(pending):
            _, names, required = CI_VALIDATION_GROUPS[group]
            sources = [observed.get(name, {}) for name in names]
            if any(
                job.get("conclusion") not in {"success", "cancelled", "skipped", None}
                for job in sources
            ):
                jobs[group]["reason"] = "上次任务需要复验"
                pending.remove(group)
            elif any(job.get("conclusion") != "success" for job in sources):
                continue
            elif ci_validation_affected(changed, group):
                jobs[group]["reason"] = "验证输入发生变化"
                pending.remove(group)
            elif set(required) <= artifacts and reusable_validation_result(candidate, group):
                jobs[group] = {
                    "execute": False,
                    "run": str(candidate["id"]),
                    "commit": candidate["head_sha"],
                    "reason": "输入内容一致，复用成功结果",
                }
                pending.remove(group)
        if not pending:
            break
    return {"commit": commit, "run": run_id, "jobs": jobs}


def validation_plan() -> None:
    from validation_environment import ci_commit_findings

    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if errors := ci_commit_findings(commit):
        raise ValueError("\n".join(errors))
    repo, run_id = repository(), os.environ["GITHUB_RUN_ID"]
    full = os.getenv("BIT101_FULL_CHECK") == "true"

    def candidates():
        runs = (run for page in workflow_run_pages(repo) for run in page["workflow_runs"])
        for run in runs:
            if (
                run.get("event") != "workflow_dispatch"
                or str(run["id"]) == run_id
                or run.get("status") != "completed"
                or not trusted_cache_run(run, repo)
            ):
                continue
            if subprocess.run(
                ["git", "merge-base", "--is-ancestor", run["head_sha"], commit],
                cwd=ROOT,
                capture_output=True,
            ).returncode:
                continue
            yield run | {
                "jobs": [
                    job
                    for page in api_pages(f"repos/{repo}/actions/runs/{run['id']}/jobs")
                    for job in page["jobs"]
                ],
                "artifacts": [
                    row
                    for page in api_pages(f"repos/{repo}/actions/runs/{run['id']}/artifacts")
                    for row in page["artifacts"]
                ],
            }

    def changed_files(source):
        return [
            name
            for name in subprocess.check_output(
                ["git", "diff", "--name-only", "-z", "--no-renames", source, commit], cwd=ROOT
            )
            .decode()
            .split("\0")
            if name
        ]

    plan = select_validation_plan(commit, run_id, candidates(), changed_files, full=full)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("plan=" + json.dumps(plan) + "\n")
    for group, row in plan["jobs"].items():
        print(f"{group}：{row['reason']}")


def read_validation_plan() -> dict:
    plan = json.loads(os.environ["BIT101_CI_PLAN"])
    from validation_inputs import CI_VALIDATION_GROUPS

    if (
        plan.get("commit") != os.environ["GITHUB_SHA"]
        or plan.get("run") != os.environ["GITHUB_RUN_ID"]
        or set(plan.get("jobs", {})) != set(CI_VALIDATION_GROUPS)
    ):
        raise ValueError("增量计划需要绑定当前提交、运行及完整验证组。")
    for row in plan["jobs"].values():
        if (
            type(row.get("execute")) is not bool
            or not row["execute"]
            and (
                not re.fullmatch("[0-9a-f]{40}", row.get("commit", ""))
                or not re.fullmatch("[1-9][0-9]*", row.get("run", ""))
            )
        ):
            raise ValueError("复用结果需要有效的来源提交与运行。")
    return plan


def reuse_validation(group: str) -> None:
    row = read_validation_plan()["jobs"][group]
    if row["execute"]:
        raise ValueError("当前验证组需要执行测试。")
    candidate = dict(
        id=int(row["run"]),
        head_sha=row["commit"],
        artifacts=[
            item
            for page in api_pages(f"repos/{repository()}/actions/runs/{row['run']}/artifacts")
            for item in page["artifacts"]
        ],
    )
    if not reusable_validation_result(candidate, group):
        raise ValueError(f"{group} 的成功记录与当前执行环境需要重新验收。")
    message = (
        f"{group}"
        f"：复用提交 "
        f"{row['commit']}"
        f" 的成功结果：https://github.com/"
        f"{repository()}"
        f"/actions/runs/"
        f"{row['run']}"
    )
    print(message)
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(message + "\n")


def workflow_run_pages(repo: str):
    page = 1
    while True:
        endpoint = (
            f"repos/"
            f"{repo}"
            f"/actions/workflows/ci.yml/runs?branch=main&event=workflow_dispatch&per_page=100&pa"
            f"ge="
            f"{page}"
        )
        payload = json.loads(subprocess.check_output(["gh", "api", endpoint], cwd=ROOT, text=True))
        yield payload
        if len(payload["workflow_runs"]) < 100:
            return
        page += 1


def check_release() -> None:
    receipt = json.loads(RECEIPT.read_text())
    tag = receipt.get("tag", "") if isinstance(receipt, dict) else ""
    version_tag(tag)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    from validation_provenance import committed_input_identity

    errors = receipt_findings(receipt, tag, commit, committed_input_identity)
    if errors:
        raise ValueError("\n".join(errors))
    print("公开发布回执通过：维护者确认、源码、工具链及采样时间。")


def baseline(commit: str) -> None:
    if not commit:
        from validation_provenance import report_lock, write_report

        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
            report.update(coverageBaseCommit="", coveragePolicy={})
            write_report(report)
        return
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", commit):
        raise ValueError("覆盖率基准需要目标提交 SHA。")
    source = subprocess.check_output(
        ["git", "show", f"{commit}:Scripts/validation_policy.py"], cwd=ROOT, text=True
    )
    names = {"MODULE_COVERAGE_FLOORS": "modules", "IOS_MODULE_COVERAGE_FLOORS": "all"}
    policy = {}
    app_floor = 35
    for node in ast.parse(source).body:
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id == "APP_COVERAGE_FLOOR"
        ):
            app_floor = ast.literal_eval(node.value)
            if type(app_floor) is not int or not 0 <= app_floor <= 100:
                raise ValueError("目标提交需要有效的 App 覆盖率阈值。")
        if not (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and (node.targets[0].id in names)
        ):
            continue
        value = ast.literal_eval(node.value)
        if (
            not isinstance(value, dict)
            or not value
            or any(
                not isinstance(key, str)
                or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", key)
                or type(floor) is not int
                or not 0 <= floor <= 100
                for key, floor in value.items()
            )
        ):
            raise ValueError("目标提交需要有效的模块覆盖率阈值。")
        policy[names[node.targets[0].id]] = value
    if set(policy) != set(names.values()):
        raise ValueError("目标提交需要 macOS 与 iOS 两组覆盖率基准。")
    policy["all"]["BIT101-iOS.app"] = app_floor
    from validation_provenance import report_lock, write_report

    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        report.update(coverageBaseCommit=commit, coveragePolicy=policy)
        write_report(report)


def review_pr(number: int, commit: str | None = None) -> str:
    if type(number) is not int or number <= 0:
        raise ValueError("审查验收需要有效 PR 编号。")
    commit = (
        commit or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    )
    pull = api_pages(f"repos/{repository()}/pulls/{number}")[0]
    if pull.get("state") != "open" or pull.get("merge_commit_sha") != commit:
        raise ValueError(
            "审查分支需要指向当前 PR 的 GitHub 合并提交；请重新获取 refs/pull/编号/merge。"
        )
    return pull["base"]["sha"]


def current(results: str) -> None:
    from validation_environment import ci_commit_findings

    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if errors := ci_commit_findings(commit):
        raise ValueError("\n".join(errors))
    jobs = json.loads(results)
    native = os.environ["BIT101_NATIVE_CHECK"] == "true"
    expected = {
        name: "success" if native or name == "static-audit" else "skipped" for name in REQUIRED_JOBS
    }
    if (
        not isinstance(jobs, dict)
        or {
            name: job.get("result") if isinstance(job, dict) else None for name, job in jobs.items()
        }
        != expected
    ):
        raise ValueError("CI 验收需要静态审计通过，并按所选范围核对完整验收任务状态。")
    print("编译、模块与行为验收通过。" if native else "静态审计验收通过。")


def version_tag(tag: str) -> None:
    version, _ = extract_versions(PROJECT_PATH.read_text())
    validate_release_tag(tag, version)
    commit = subprocess.check_output(
        ["git", "rev-list", "-n", "1", tag], cwd=ROOT, text=True
    ).strip()
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if commit != head:
        raise ValueError("发布证据标签需要指向当前验收提交。")


def release(tag: str, *, publish: bool = False) -> None:
    version_tag(tag)
    import validation_evidence

    if publish:
        with validation_evidence.report_lock():
            if validation_evidence.inspect_report(
                SimpleNamespace(action="check", recorded_environment=False)
            ):
                raise ValueError("发布证据需要完整发布验收与提交绑定。")
            from validation_provenance import committed_input_identity

            receipt = release_receipt(json.loads(REPORT.read_text()), tag, committed_input_identity)
            RECEIPT.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
            subprocess.run(
                ["gh", "release", "upload", tag, str(RECEIPT), "--repo", repository(), "--clobber"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
        return
    with validation_evidence.report_lock():
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        RECEIPT.unlink(missing_ok=True)
        command = [
            "gh",
            "release",
            "download",
            tag,
            "--repo",
            repository(),
            "--pattern",
            RECEIPT.name,
            "--dir",
            str(REPORT.parent),
            "--clobber",
        ]
        subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True)


def read_native_summary(bundle: Path, group: str) -> dict:
    from validation_evidence import native_case_summary

    def read(kind):
        return json.loads(
            subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(bundle)],
                text=True,
            )
        )

    raw, tree = read("summary"), read("tests")
    cases = native_case_summary(tree, group, simulator=True)
    return {
        "passed": raw.get("result") == "Passed",
        "totalTests": raw.get("totalTestCount"),
        "passedTests": raw.get("passedTests"),
        "failedTests": raw.get("failedTests"),
        "skippedTests": raw.get("skippedTests"),
        "executedTests": sorted(cases["byTest"]),
        "testCases": cases,
    }


def download_simulator_shard(run: str, operation: str, index: int) -> None:
    root = ROOT / ".build/extended-automation"
    shutil.rmtree(root / "test-results.xcresult", ignore_errors=True)
    for name in (
        "simulator.log",
        "all.log",
        "release-runtime.log",
        "ui.log",
        "build-release.log",
        "restore.log",
        "test-metrics.txt",
    ):
        (root / name).unlink(missing_ok=True)
    (ROOT / ".build/screenshot.png").unlink(missing_ok=True)
    artifact = (
        "validation-ios-app-tests"
        if operation == "release-runtime"
        else f"validation-ios-test-shards-{operation}-{index}"
    )
    subprocess.run(
        ["gh", "run", "download", run, "--name", artifact, "--dir", str(ROOT)],
        check=True,
        capture_output=True,
        text=True,
    )


def merge_simulator_ci() -> None:
    from validation_simulator import merge_ci_results

    merge_ci_results(sys.modules[__name__])


def self_test() -> None:
    from unittest.mock import patch
    from ci_plan_tests import acceptance_self_test

    with patch.dict(os.environ, GITHUB_ACTIONS="false", GITHUB_SHA=""):
        acceptance_self_test(sys.modules[__name__])
        cache_self_test()
        validation_plan_self_test()


def validation_plan_self_test() -> None:
    from ci_plan_tests import self_test

    self_test(sys.modules[__name__])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "baseline",
            "current",
            "review-pr",
            "release",
            "publish",
            "check-release",
            "export-result",
            "simulator-merge",
            "cache-restore",
            "cache-export",
            "cache-prune",
            "plan",
            "reuse",
        ),
    )
    parser.add_argument("identity", nargs="?", default="")
    parser.add_argument("--results", default="")
    args = parser.parse_args()
    try:
        if args.action == "baseline":
            baseline(args.identity)
        elif args.action == "current":
            current(args.results)
        elif args.action == "review-pr":
            print(review_pr(int(args.identity)))
        elif args.action == "check-release":
            check_release()
        elif args.action == "export-result":
            export_validation_result(args.identity)
        elif args.action == "simulator-merge":
            merge_simulator_ci()
        elif args.action == "cache-restore":
            restore_cache(args.identity)
        elif args.action == "cache-export":
            export_cache(args.identity)
        elif args.action == "cache-prune":
            prune_caches()
        elif args.action == "plan":
            validation_plan()
        elif args.action == "reuse":
            reuse_validation(args.identity)
        else:
            release(args.identity, publish=args.action == "publish")
        return 0
    except (
        ValueError,
        SyntaxError,
        KeyError,
        OSError,
        zipfile.BadZipFile,
        subprocess.CalledProcessError,
    ) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else None
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        print(detail.strip() if detail else str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
