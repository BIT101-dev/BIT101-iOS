"""Check reusable CI command and evidence rules."""

import json
import ast
import os
import re
import subprocess
import shlex
from functools import cache


CI_RUNNER = "xcode-27"


CI_RELEASE_CONTEXT = (
    "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && inputs.r"
    "elease_check"
)


CI_NATIVE_CONTEXT = (
    "startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch' && (inputs."
    "full_check || inputs.release_check)"
)


CI_STATIC_GATE = (
    "${{ !cancelled() && (needs.validation-plan.result == 'success' || needs.validation-plan.resul"
    "t == 'skipped') }}"
)


CI_CANCELLATION = "${{ !(" + CI_RELEASE_CONTEXT + ") }}"


CI_CONCURRENCY_GROUP = "ios-ci-${{ github.ref }}-${{ " + CI_RELEASE_CONTEXT + " }}"


CI_PLANNED_GROUPS = {
    "release-build": "release",
    "catalyst-tests": "catalyst",
    "ios-app-tests": "app",
}


CI_EXECUTE = "fromJSON(env.BIT101_CI_PLAN).jobs[env.BIT101_CI_GROUP].execute"


CI_EXECUTION = "${{ " + CI_EXECUTE + " }}"


CI_NATIVE_EXECUTION = "${{ (" + CI_NATIVE_CONTEXT + ") && " + CI_EXECUTE + " }}"


CI_NATIVE_REUSE = "${{ (" + CI_NATIVE_CONTEXT + ") && !" + CI_EXECUTE + " }}"


CI_STATIC_EXECUTION = "${{ !(" + CI_NATIVE_CONTEXT + ") || !" + CI_EXECUTE + " }}"


CI_DIAGNOSTICS = "${{ always() && " + CI_EXECUTE + " }}"


DIAGNOSTIC_PATHS = {
    "static-audit": {
        ".build/static-audit/*.log",
        ".build/code-quality-report.txt",
        ".build/ui-consistency-report.txt",
        ".build/compiler-cache/swift-syntax-indexer",
        ".build/compiler-cache/swift-syntax-indexer-inputs.json",
        ".build/static-audit/compilation-conditions.json",
        ".build/explanatory-text-report.txt",
        ".build/extended-automation/modules.log",
        ".build/extended-automation/module-events.jsonl",
        ".build/extended-automation/test-metrics.txt",
    },
    "release-build": {
        ".build/extended-automation/build-network-smoke.log",
        ".build/extended-automation/build-icloud-smoke.log",
        ".build/extended-automation/diagnostics/test-results.xcresult",
        "build/DeviceInstall/build.log",
    },
    "catalyst-tests": {
        ".build/extended-automation/catalyst.log",
        ".build/extended-automation/catalyst-release-runtime.log",
        ".build/extended-automation/test-metrics.txt",
        ".build/extended-automation/test-failures.txt",
        ".build/extended-automation/test-results.xcresult",
    },
    "ios-tests": {
        ".build/extended-automation/simulator.log",
        ".build/extended-automation/all.log",
        ".build/extended-automation/release-runtime.log",
        "build/DeviceInstall/build.log",
        ".build/extended-automation/restore.log",
        ".build/extended-automation/test-metrics.txt",
        ".build/extended-automation/test-results.xcresult",
        ".build/screenshot.png",
    },
}


DIAGNOSTIC_PATHS["ios-app-tests"] = DIAGNOSTIC_PATHS["ios-tests"]


def hook_documents_checked(source: str) -> bool:
    controls = {
        "if",
        "then",
        "else",
        "elif",
        "fi",
        "for",
        "while",
        "until",
        "case",
        "esac",
        "function",
        "{",
        "}",
    }
    prefixes = [
        ["source", "Scripts/script-support.sh"],
        ["git", "diff", "--cached", "--check"],
        ["python3", "Scripts/check-python-syntax.py", ".", "--staged", "--changed"],
        ["python3", "Scripts/check-file-lengths.py", "--staged"],
    ]
    for line in source.replace("\\\n", " ").splitlines():
        try:
            words = shlex.split(line, comments=True)
        except ValueError:
            return False
        if not words:
            continue
        if words[-3:] == ["||", "exit", "$?"]:
            words = words[:-3]
        if any(word in controls for word in words):
            return False
        if words == ["exec", "python3", "Scripts/check-docs.py", "--staged"]:
            return True
        if words[:1] in (["exit"], ["return"]) or line.lstrip().startswith("exec "):
            return False
        if words not in prefixes:
            return False
    return False


def active_script_markers(source: str) -> str:
    lines = []
    for line in source.splitlines():
        try:
            lines.append(" ".join(shlex.split(line, comments=True, posix=False)))
        except ValueError:
            lines.append(line if not line.lstrip().startswith("#") else "")
    return "\n".join(lines)


def command_matches(actual: str, expected: str) -> bool:
    if not isinstance(actual, str) or not isinstance(expected, str):
        return False
    try:
        commands = [
            shlex.split(line, comments=True) for line in actual.replace("\\\n", " ").splitlines()
        ]
        commands = [words for words in commands if words]
        return len(commands) == 1 and commands[0] == shlex.split(expected, comments=True)
    except ValueError:
        return False


def runner_expression(value):
    if isinstance(value, list):
        return (
            ("labels", tuple(sorted(value)))
            if all(isinstance(label, str) for label in value)
            else None
        )
    if not isinstance(value, str):
        return None
    tokens = re.findall(
        r"'(?:[^']|'')*'|\"(?:[^\"\\]|\\.)*\"|==|!=|&&|\|\||\$\{\{|\}\}|[A-Za-z_]\w*|[^\s]", value
    )
    for position, token in enumerate(tokens):
        if not (token.startswith("'[") and token.endswith("]'")):
            continue
        try:
            labels = json.loads(token[1:-1])
        except ValueError:
            return None
        normalized = runner_expression(labels)
        if normalized is None:
            return None
        tokens[position] = normalized
    return tuple(tokens)


def ci_result_wiring_findings(jobs: dict) -> list[str]:
    errors = []

    def configuration(step):
        value = step.get("with")
        return value if isinstance(value, dict) else {}

    for name, group, condition, producer in (
        (
            "static-audit",
            "modules",
            CI_NATIVE_EXECUTION,
            "Scripts/run-extended-tests.sh verify audit modules",
        ),
        (
            "release-build",
            "release",
            CI_EXECUTION,
            "Scripts/run-extended-tests.sh build icloud-smoke",
        ),
        (
            "catalyst-tests",
            "catalyst",
            CI_EXECUTION,
            "Scripts/run-extended-tests.sh verify catalyst catalyst-release-runtime",
        ),
        (
            "ios-tests",
            "ios",
            "${{ fromJSON(env.BIT101_CI_PLAN).jobs.app.execute }}",
            "Scripts/run-extended-tests.sh simulator merge",
        ),
    ):
        job = jobs.get(name)
        steps = job.get("steps", []) if isinstance(job, dict) else []
        steps = (
            [step for step in steps if isinstance(step, dict)] if isinstance(steps, list) else []
        )
        exports = [
            step
            for step in steps
            if command_matches(
                step.get("run"), "python3 Scripts/ci_evidence.py export-result " + group
            )
        ]
        uploads = [
            step for step in steps if configuration(step).get("name") == "verified-result-" + group
        ]
        producers = [step for step in steps if command_matches(step.get("run"), producer)]
        if len(exports) != 1 or len(uploads) != 1 or len(producers) != 1:
            errors.append(f".github/workflows/ci.yml: {name} 需要独立的完整成功记录")
            continue
        export, upload = exports[0], uploads[0]
        settings = configuration(upload)
        if (
            not steps.index(producers[0]) < steps.index(export) < steps.index(upload)
            or any(
                step.get("if") != condition or step.get("continue-on-error", False)
                for step in (export, upload)
            )
            or not str(upload.get("uses", "")).startswith("actions/upload-artifact@")
            or settings.get("path") != ".build/extended-automation/ci-validation-result.json"
            or settings.get("compression-level") != 0
            or settings.get("overwrite") is not True
            or settings.get("include-hidden-files") is not True
            or settings.get("if-no-files-found") != "error"
        ):
            errors.append(
                f".github/workflows/ci.yml: {name} 的完整成功记录需要绑定实际验收与固定产物"
            )
    return errors


def check_command_forbidden_ui(words: list[str]) -> bool:
    for index, word in enumerate(words):
        if word.endswith("run-extended-tests.sh"):
            arguments = words[index + 1 :]
            if any(value in {"ui", "build-ui", "preview"} for value in arguments):
                return True
            if arguments[:1] == ["verify"] and not any(
                not value.startswith("-") for value in arguments[1:]
            ):
                return True
            if arguments[:2] == ["simulator", "verify"]:
                return True
        elif word.endswith("xcodebuild"):
            if any("UITests" in value or "UIAutomation" in value for value in words[index + 1 :]):
                return True
    return False


def ci_ui_execution_findings(jobs: dict) -> list[str]:
    errors = []

    def values(value):
        if isinstance(value, dict):
            return [item for child in value.values() for item in values(child)]
        if isinstance(value, list):
            return [item for child in value for item in values(child)]
        return [value] if isinstance(value, str) else []

    for name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        forbidden = any(value in {"ui", "build-ui", "preview"} for value in values(job))
        for step in job.get("steps", []):
            if not isinstance(step, dict):
                continue
            for line in str(step.get("run", "")).replace("\\\n", " ").splitlines():
                try:
                    words = shlex.split(line, comments=True)
                except ValueError:
                    continue
                if check_command_forbidden_ui(words):
                    forbidden = True
        if forbidden:
            errors.append(
                f".github/workflows/ci.yml: {name} 禁止执行 UITest；UI 测试由本地真机验收。"
            )
    return errors


@cache
def review_execution_findings(command: str) -> tuple[str, ...]:
    harness = (
        'python3() { printf "%s\\0" "$@" >&2; [[ "$fail_at" == 0 ]] || return 73; printf "fixture-'
        'base"; };\n'
    )
    for failure in ("0", "1"):
        env = dict(os.environ, BIT101_REVIEW_PR="12", GITHUB_OUTPUT="/dev/stdout", fail_at=failure)
        result = subprocess.run(
            ["bash", "-eo", "pipefail", "-c", harness + command],
            env=env,
            capture_output=True,
            text=True,
        )
        if (
            result.stderr.split("\0")[:-1] != ["Scripts/ci_evidence.py", "review-pr", "12"]
            or result.returncode != (73 if failure == "1" else 0)
            or result.stdout != ("" if failure == "1" else "base_sha=fixture-base\n")
        ):
            return (".github/workflows/ci.yml: 审查需要核对原 PR 合并提交并传播失败",)
    return ()


def evidence_execution_findings(command: str, key: str, expected: list[str]) -> list[str]:
    return list(_evidence_execution_findings(command, key, tuple(expected)))


@cache
def _evidence_execution_findings(
    command: str, key: str, expected: tuple[str, ...]
) -> tuple[str, ...]:
    harness = (
        'call=0; python3() { ((call+=1)); printf "%s\\0" "$@"; [[ "$call" != "$fail_at" ]] || retu'
        "rn 73; return 0; };\n"
    )
    environment = dict(os.environ, **{key: "fixture", "fail_at": "0"})
    result = subprocess.run(
        ["bash", "-eo", "pipefail", "-c", harness + command],
        env=environment,
        capture_output=True,
        text=True,
    )
    if result.returncode or tuple(result.stdout.split("\0")[:-1]) != expected:
        return (".github/workflows/ci.yml: 证据交换需要所属提交或运行的完整命令",)
    for index in range(1, sum(argument.endswith(".py") for argument in expected) + 1):
        failed = subprocess.run(
            ["bash", "-eo", "pipefail", "-c", harness + command],
            env=dict(environment, fail_at=str(index)),
            capture_output=True,
            text=True,
        )
        if failed.returncode != 73:
            return (".github/workflows/ci.yml: 证据交换失败需要结束所属步骤",)
    return ()


def check_test_results_native_coverage(metrics_source: str) -> bool:
    metrics = ast.parse(metrics_source)
    handlers = []
    for node in ast.walk(metrics):
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if (
                    isinstance(key, ast.Constant)
                    and key.value == "native-metrics"
                    and isinstance(value, ast.Name)
                ):
                    handlers.append(value.id)
    return any(
        isinstance(node, ast.Constant) and node.value == "xccov"
        for function in metrics.body
        if isinstance(function, ast.FunctionDef) and function.name in handlers
        for node in ast.walk(function)
    )


for job, paths in DIAGNOSTIC_PATHS.items():
    if job != "static-audit":
        paths.add(".build/extended-automation/diagnostics/test-results.xcresult")
