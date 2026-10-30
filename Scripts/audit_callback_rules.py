"""Exercise each static-audit delegate with successful and failing commands."""
import re
import subprocess
import shlex
from functools import cache
from pathlib import Path


def audit_call_identity(call: str) -> tuple:
    command, *arguments = call.split('|')
    if command in {'find', 'rg'}:
        roots = tuple(sorted(value for value in arguments if value.startswith('/audit')))
        selectors = [value for value in arguments if not value.startswith('/audit')]
        if command == 'find':
            pruning = selectors[:4] if selectors[:1] == ['-path'] else []
            if pruning and pruning[2:] != ['-prune', '-o']: return tuple(call.split('|'))
            selectors = selectors[len(pruning):]
            try:
                pattern = selectors[selectors.index('-name') + 1]
                kind = selectors[selectors.index('-type') + 1]
            except (ValueError, IndexError): return tuple(call.split('|'))
            if sorted(selectors) != sorted(['-type', 'f', '-name', pattern, '-print0']): return tuple(call.split('|'))
            return ('scan', roots, pattern, kind, tuple(pruning[1:2]))
        globs, flags = [], []
        while selectors:
            value = selectors.pop(0)
            if value in {'--glob', '-g'} and selectors: globs.append(selectors.pop(0))
            else: flags.append(value)
        positive = [value for value in globs if not value.startswith('!')]
        excluded = [value for value in globs if value.startswith('!')]
        if len(positive) != 1 or sorted(flags) not in [sorted(['--files', '--null', '--no-ignore']),
                sorted(['--files', '-0', '--no-ignore'])] or excluded not in [[], ['!**/node_modules/**']]:
            return tuple(call.split('|'))
        return ('scan', roots, positive[0], 'f', ('*/node_modules',) if excluded else ())
    positional, options = [], []
    while arguments:
        value = arguments.pop(0)
        if value in {'-D', '-C', '--compare-git-ref', '--audit-level'} and arguments:
            options.append((value, arguments.pop(0)))
        elif value.startswith('-'):
            options.append(tuple(value.split('=', 1)))
        else: positional.append(value)
    return (command, tuple(positional), tuple(sorted(options)))


def audit_callback_findings(source: str, *, support_source: str | None = None) -> list[str]:
    if support_source is None: support_source = Path(__file__).with_name("script-support.sh").read_text()
    declarations_source = source + "\n" + support_source
    callbacks = {
        "swift_parse": [
            "find|/audit/Modules|/audit/BIT101-iOS|/audit/BIT101ScheduleWidgets|/audit/BIT101Watch|/audit/BIT101WatchWidgets|-type|f|-name|*.swift|-print0",
            "frontend|-frontend|-parse|-D|DEBUG|fixture.swift",
            "find|/audit/BIT101-iOSTests|/audit/BIT101-iOSUITests|/audit/ModuleTests|-type|f|-name|*.swift|-print0",
            "frontend|-frontend|-parse|-D|DEBUG|-D|EXTENDED_AUTOMATION|fixture.swift"],
        "shell_parse": ["python3|/audit/Scripts/check-shell-syntax.py"],
        "python_parse": ["python3|/audit/Scripts/check-python-syntax.py|/audit|--self-test"],
        "worker_parse": ["find|/audit/Cloudflare|(|-name|node_modules|-o|-name|.wrangler|-o|-name|.git|)|-prune|-o|-type|f|-name|*.js|-print0", "node|--check|fixture.swift"],
        "dependency_audit": ["cd|/audit/Cloudflare/EmergencyUpdateWorker", "npm|audit|--audit-level=high"],
        "git_check": ["git|-C|/audit|diff|--check", "git|-C|/audit|diff|--cached|--check"],
        "docs_check": ["cd|/audit", "python3|Scripts/check-docs.py|--self-test", "cd|/audit", "python3|Scripts/validate_versions.py|--compare-git-ref|base|--check-app-store"],
        "bit101_checker_audit": ["python3|/audit/Scripts/check-file-lengths.py", "python3|/audit/Scripts/check-file-lengths.py|--staged", "python3|/audit/Scripts/validation_evidence.py|self-test", "python3|/audit/Scripts/check-code-quality.py|--combined|--self-test"],
        "module_boundary_audit": ["python3|/audit/Scripts/check-module-boundaries.py|--self-test"],
        "artifact_hygiene": ["python3|/audit/Scripts/validation_artifacts.py|/audit"],
    }
    harness = r'''
set -o pipefail
ROOT_DIR=/audit
SWIFT_FRONTEND=frontend
BIT101_VERSION_BASE_REF=base
BIT101_RELEASE_CHECK=true
emit() { local call="${(j:|:)@}"; print -r -- "CALL $call" >&2; [[ "$call" != "$FAIL_CALL" ]]; }
python3() { emit python3 "$@"; }
git() { emit git "$@"; }
npm() { emit npm "$@"; }
cd() { emit cd "$@"; }
frontend() { emit frontend "$@"; }
node() { emit node "$@"; }
find() { emit find "$@" || return 7; printf 'fixture.swift\0'; }
rg() { emit rg "$@" || return 7; printf 'fixture.swift\0'; }
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
    for callback, complete in callbacks.items():
        declarations = re.findall(r"(?m)^[ \t]*(?:function[ \t]+)?" + callback + r"(?:[ \t]*\(\))?[ \t]*\{", declarations_source)
        definition = re.search(r"(?ms)^[ \t]*(?:function[ \t]+)?" + callback + r"(?:[ \t]*\(\))?[ \t]*\{(?:[^\n]*\}|.*?^\})", declarations_source)
        if len(declarations) != 1 or definition is None:
            errors.append(f"Scripts/run-static-audit.sh: {callback} 需要唯一的审计委托声明")
            continue
        modes = ('0', '1') if callback in {'python_parse', 'docs_check', 'bit101_checker_audit', 'module_boundary_audit'} else ('1',)
        for enabled in modes:
            expected = complete if enabled == '1' else [call.removesuffix('|--self-test') for call in complete
                if call != 'python3|/audit/Scripts/validation_evidence.py|self-test']
            identities = tuple(sorted(audit_call_identity(call) for call in expected))
            if not valid_callback(definition[0], callback, identities, harness, enabled):
                errors.append(f"Scripts/run-static-audit.sh: {callback} 需要执行所属命令并传播结果")
                break
    return errors


@cache
def valid_callback(definition: str, callback: str, expected: tuple, harness: str, enabled: str) -> bool:
    failures = ['']
    for failure in failures:
        script = harness + "\nBIT101_AUDIT_SELF_TESTS=" + enabled + "\nFAIL_CALL=" + shlex.quote(failure) + "\n" + definition
        result = subprocess.run(["zsh", "-c", script + f"\n{callback}\n"], capture_output=True, text=True)
        calls = [line.removeprefix('CALL ') for line in result.stderr.splitlines() if line.startswith('CALL ')]
        identities = [audit_call_identity(call) for call in calls]
        valid = tuple(sorted(identities)) == expected if not failure else failure in calls and all(call in expected for call in identities)
        if callback == 'bit101_checker_audit': valid = valid and tuple(sorted(identities)) == expected
        if not valid or (result.returncode == 0) != (not failure): return False
        if not failure: failures.extend(dict.fromkeys(calls))
    return True


def self_test() -> None:
    from pathlib import Path
    source = Path(__file__).with_name("run-static-audit.sh").read_text()
    from script_test_support import shell_function
    logger = shell_function(Path(__file__).with_name('script-support.sh'), 'bit101_show_audit_log')
    for count, failed, ci in ((1000, False, False), (1001, False, True), (1001, True, False), (1001, True, True)):
        harness = 'ROOT_DIR=' + shlex.quote(str(Path(__file__).resolve().parents[1])) \
            + f'; export GITHUB_ACTIONS={str(ci).lower()};\n'
        payload = ''.join(f'diagnostic {index}\n' for index in range(count - 1)) + 'error: decisive cause\n'
        result = subprocess.run(['zsh', '-c', harness + logger + f'\nbit101_show_audit_log /dev/stdin {str(failed).lower()}'],
            capture_output=True, text=True, input=payload)
        assert result.returncode == 0, result.stderr
        assert 'diagnostic 0\n' in result.stdout and 'error: decisive cause\n' in result.stdout
        assert '[输出]' in result.stdout and len(result.stdout.splitlines()) <= 41
    assert not audit_callback_findings(source)
    assert audit_callback_findings(source.replace('Scripts/check-docs.py "${docs_args[@]}"',
        'Scripts/check-docs.py --staged "${docs_args[@]}"'))
    support = Path(__file__).with_name("script-support.sh").read_text()
    assert not audit_callback_findings(source, support_source=support.replace('[失败]', '[诊断]'))
    assert audit_callback_findings(source, support_source=support.replace("|| checker_status=1", "|| return 1"))
    reordered = source.replace('-frontend -parse -D DEBUG -D EXTENDED_AUTOMATION',
        '-D EXTENDED_AUTOMATION -parse -D DEBUG -frontend').replace('diff --cached --check', 'diff --check --cached')
    assert not audit_callback_findings(reordered)
    for declaration in ('function module_boundary_audit()', 'function module_boundary_audit', '  module_boundary_audit ()'):
        assert not audit_callback_findings(source.replace('module_boundary_audit()', declaration))
    traversal = re.sub(r'find ("\$ROOT_DIR/[^\n]+)\\\n\s*("\$ROOT_DIR/[^\n]+)\\\n\s*-type f -name \'\*\.swift\' -print0',
        r"rg --files --null --no-ignore --glob '*.swift' \1 \2", source)
    assert traversal != source and not audit_callback_findings(traversal)
    for callback in ("bit101_checker_audit", "swift_parse", "worker_parse", "module_boundary_audit", "artifact_hygiene"):
        pattern = r"(?ms)^" + callback + r"\(\)\s*\{(?:[^\n]*\}|.*?^\})"
        if callback == "bit101_checker_audit":
            assert audit_callback_findings(source, support_source=re.sub(pattern, callback + "() { return 0; }", support))
            assert audit_callback_findings(source, support_source=support + "\n" + callback + "() { return 0; }\n")
        else:
            assert audit_callback_findings(re.sub(pattern, callback + "() { return 0; }", source))
            assert audit_callback_findings(source + "\n" + callback + "() { return 0; }\n")
