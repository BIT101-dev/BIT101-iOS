"""Exercise each static-audit delegate with successful and failing commands."""
import re
import subprocess


def audit_callback_findings(source: str) -> list[str]:
    callbacks = {
        "swift_parse": [
            "find|/audit/Modules|/audit/BIT101-iOS|/audit/BIT101ScheduleWidgets|/audit/BIT101Watch|/audit/BIT101WatchWidgets|-type|f|-name|*.swift|-print0",
            "frontend|-frontend|-parse|-D|DEBUG|fixture.swift",
            "find|/audit/BIT101-iOSTests|/audit/BIT101-iOSUITests|/audit/ModuleTests|-type|f|-name|*.swift|-print0",
            "frontend|-frontend|-parse|-D|DEBUG|-D|EXTENDED_AUTOMATION|fixture.swift"],
        "shell_parse": ["python3|/audit/Scripts/check-shell-syntax.py"],
        "python_parse": ["python3|/audit/Scripts/check-python-syntax.py|/audit"],
        "worker_parse": ["find|/audit/Cloudflare|-path|*/node_modules|-prune|-o|-type|f|-name|*.js|-print0", "node|--check|fixture.swift"],
        "dependency_audit": ["cd|/audit/Cloudflare/EmergencyUpdateWorker", "npm|audit|--audit-level=high"],
        "git_check": ["git|-C|/audit|diff|--check", "git|-C|/audit|diff|--cached|--check"],
        "docs_check": ["cd|/audit", "python3|Scripts/check-docs.py|--all", "cd|/audit", "python3|Scripts/validate_versions.py|--compare-git-ref|base|--check-app-store"],
        "checker_audit": ["python3|/audit/Scripts/check-file-lengths.py", "python3|/audit/Scripts/validation_evidence.py|self-test", "python3|/audit/Scripts/check-code-quality.py|--combined"],
        "module_boundary_audit": ["python3|/audit/Scripts/check-module-boundaries.py"],
        "artifact_hygiene": ["python3|/audit/Scripts/validation_artifacts.py|/audit"],
    }
    harness = r'''
set -o pipefail
ROOT_DIR=/audit
SWIFT_FRONTEND=frontend
BIT101_VERSION_BASE_REF=base
BIT101_RELEASE_CHECK=true
emit() { local call="${(j:|:)@}"; print -r -- "$call" >&2; [[ "$call" != "$FAIL_CALL" ]]; }
python3() { emit python3 "$@"; }
git() { emit git "$@"; }
npm() { emit npm "$@"; }
cd() { emit cd "$@"; }
frontend() { emit frontend "$@"; }
node() { emit node "$@"; }
find() { emit find "$@" || return 7; printf 'fixture.swift\0'; }
xargs() {
  local payload
  read -r -d '' payload || return 0
  [[ "$1" == -0 ]] || return 8
  shift
  if [[ "$1" == -n ]]; then [[ "$2" == 1 ]] || return 8; shift 2; fi
  "$@" "$payload"
}
'''
    errors = []
    for callback, expected in callbacks.items():
        declarations = re.findall(r"(?m)^[ \t]*(?:function[ \t]+)?" + callback + r"(?:[ \t]*\(\))?[ \t]*\{", source)
        definition = re.search(r"(?ms)^" + callback + r"\(\)\s*\{(?:[^\n]*\}|.*?^\})", source)
        if len(declarations) != 1 or definition is None:
            errors.append(f"Scripts/run-static-audit.sh: {callback} 需要唯一的审计委托声明")
            continue
        for failure in [""] + list(dict.fromkeys(expected)):
            script = harness + "\nFAIL_CALL=" + "'" + failure.replace("'", "'\\''") + "'\n" + definition[0]
            script += f"\n{callback}\n"
            result = subprocess.run(["zsh", "-c", script], capture_output=True, text=True)
            calls = result.stderr.splitlines()
            # Pipelines may emit both delegates before a failure reaches the parent.
            valid = sorted(calls) == sorted(expected) if not failure else failure in calls and all(call in expected for call in calls)
            if not valid or (result.returncode == 0) != (not failure):
                errors.append(f"Scripts/run-static-audit.sh: {callback} 需要执行所属命令并传播结果")
                break
    return errors


def self_test() -> None:
    from pathlib import Path
    source = Path(__file__).with_name("run-static-audit.sh").read_text()
    assert not audit_callback_findings(source)
    for callback in ("checker_audit", "swift_parse", "worker_parse", "module_boundary_audit", "artifact_hygiene"):
        pattern = r"(?ms)^" + callback + r"\(\)\s*\{(?:[^\n]*\}|.*?^\})"
        assert audit_callback_findings(re.sub(pattern, callback + "() { return 0; }", source))
        assert audit_callback_findings(source + "\n" + callback + "() { return 0; }\n")
