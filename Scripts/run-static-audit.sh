#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

group_names=(swift-parse shell-parse python-parse worker-parse dependency-audit module-boundary git-diff docs checkers)
group_commands=(swift_parse shell_parse python_parse worker_parse dependency_audit module_boundary_audit git_check docs_check bit101_checker_audit)
requested_groups=()
self_tests_requested=0
for argument in "$@"; do
  case "$argument" in
  --help|-h)
    print -r -- "用法：Scripts/run-static-audit.sh [--self-test] [分组...]"
    print -r -- "运行 Swift、架构、界面、脚本、文档和依赖静态审计。"
    print -r -- "分组：${(j:, :)group_names}, artifact-hygiene"
    print -r -- "默认记录完整审计；显式分组执行定向检查，例如 docs、python-parse、dependency-audit。"
    exit 0
    ;;
  --self-test) self_tests_requested=1 ;;
  prepare) [[ $# -eq 1 ]] || { print -u2 -- "用法：Scripts/run-static-audit.sh [--help]"; exit 64; } ;;
  *)
    if (( ${group_names[(Ie)$argument]} == 0 )) && [[ "$argument" != artifact-hygiene ]]; then
      print -u2 -- "用法：Scripts/run-static-audit.sh [--self-test] [分组...]；分组见 --help。"
      exit 64
    fi
    if (( ${requested_groups[(Ie)$argument]} == 0 )); then requested_groups+=("$argument"); fi
    ;;
  esac
done
full_audit=1
if (( ${#requested_groups} )); then full_audit=0; fi
if (( ! full_audit )) && [[ "${GITHUB_ACTIONS:-false}" == true || "${BIT101_RELEASE_CHECK:-false}" == true ]]; then
  print -u2 -- "CI 与发布验收采用默认完整静态审计入口。"
  exit 64
fi
run_artifacts=$full_audit
if (( ${requested_groups[(Ie)artifact-hygiene]} )); then run_artifacts=1; fi
if (( ! full_audit )); then
  selected_names=() selected_commands=()
  for (( index = 1; index <= ${#group_names}; index++ )); do
    selected_group="$group_names[$index]"
    if (( ${requested_groups[(Ie)$selected_group]} )); then
      selected_names+=("$group_names[$index]")
      selected_commands+=("$group_commands[$index]")
    fi
  done
  group_names=("${selected_names[@]}") group_commands=("${selected_commands[@]}")
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/Scripts/script-support.sh"
if (( run_artifacts || ${group_names[(Ie)swift-parse]} || ${group_names[(Ie)module-boundary]} || ${group_names[(Ie)checkers]} )); then
  bit101_acquire_artifact_lock "$0" "$@"
fi
bit101_acquire_script_lock "$ROOT_DIR/.build/static-audit/audit.lock" BIT101_STATIC_AUDIT_LOCK_HELD "$0" "$@"
LOG_DIR="$ROOT_DIR/.build/static-audit"
if [[ "${1:-}" == prepare && $# -eq 1 ]]; then
  python3 "$ROOT_DIR/Scripts/validation_performance.py" recover-batch
  python3 "$ROOT_DIR/Scripts/validation_artifacts.py" "$ROOT_DIR"
  exit 0
fi
export BIT101_AUDIT_SELF_TESTS=0
if (( self_tests_requested )) || [[ "${GITHUB_ACTIONS:-false}" == true || "${BIT101_RELEASE_CHECK:-false}" == true ]]; then
  export BIT101_AUDIT_SELF_TESTS=1
fi
AUDIT_STARTED=$SECONDS
group_processes=()
BIT101_VALIDATION_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
export BIT101_VALIDATION_STARTED_AT
finish_audit() {
  local audit_status=$?
  trap - EXIT
  trap '' INT TERM
  python3 "$ROOT_DIR/Scripts/workflow_processes.py" terminate-groups "${group_processes[@]}"
  for pid in "${group_processes[@]}"; do if (( pid > 0 )); then wait "$pid" 2>/dev/null || true; fi; done
  local record_status=0
  if (( full_audit )); then
    export BIT101_VALIDATION_ELAPSED_SECONDS="$(( SECONDS - AUDIT_STARTED ))"
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" record audit "$audit_status" || record_status=$?
  fi
  if (( audit_status == 0 )); then audit_status=$record_status; fi
  if (( audit_status == 0 )); then
    if (( full_audit )); then echo "静态审计通过 · 10 组 · $(( SECONDS - AUDIT_STARTED )) 秒"
    else echo "定向静态审计通过 · ${(j:, :)requested_groups} · $(( SECONDS - AUDIT_STARTED )) 秒"; fi
  fi
  exit "$audit_status"
}
trap finish_audit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( ${group_names[(Ie)checkers]} )); then
  rm -f "$ROOT_DIR/.build/"{code-quality-report,ui-consistency-report,explanatory-text-report}.txt
fi

SWIFT_FRONTEND=""
if (( full_audit || ${group_names[(Ie)swift-parse]} || ${group_names[(Ie)module-boundary]} || ${group_names[(Ie)checkers]} )); then
  SWIFT_FRONTEND="$(xcrun --find swift-frontend 2>/dev/null || true)"
  if [[ -z "$SWIFT_FRONTEND" || ! -x "$SWIFT_FRONTEND" ]]; then
    echo "[失败] 找不到可用的 swift-frontend；请检查当前 Xcode 工具链" >&2
    exit 1
  fi
fi
if (( full_audit )) && [[ "${BIT101_AUDIT_ARTIFACTS_PREPARED:-0}" != 1 ]]; then
  python3 "$ROOT_DIR/Scripts/validation_performance.py" recover-batch
fi
if (( full_audit )); then
  BIT101_VALIDATION_INPUT_IDENTITY="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest audit)"
  BIT101_VALIDATION_RUN_ID="$(uuidgen)"
  export BIT101_VALIDATION_INPUT_IDENTITY BIT101_VALIDATION_RUN_ID
fi

mkdir -p "$LOG_DIR"
if (( full_audit )); then rm -f "$LOG_DIR"/*.log(N)
else
  for name in "${group_names[@]}"; do rm -f "$LOG_DIR/$name.log"; done
fi


swift_parse() {
  find "$ROOT_DIR/Modules" "$ROOT_DIR/BIT101-iOS" "$ROOT_DIR/BIT101ScheduleWidgets" \
    "$ROOT_DIR/BIT101Watch" "$ROOT_DIR/BIT101WatchWidgets" \
    -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG || return 1
  find "$ROOT_DIR/BIT101-iOSTests" "$ROOT_DIR/BIT101-iOSUITests" "$ROOT_DIR/ModuleTests" -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG -D EXTENDED_AUTOMATION
}

shell_parse() {
  python3 "$ROOT_DIR/Scripts/check-shell-syntax.py"
}
python_parse() {
  if [[ "$BIT101_AUDIT_SELF_TESTS" == 1 ]]; then
    python3 "$ROOT_DIR/Scripts/check-python-syntax.py" "$ROOT_DIR" --self-test
  else
    python3 "$ROOT_DIR/Scripts/check-python-syntax.py" "$ROOT_DIR"
  fi
}
worker_parse() {
  find "$ROOT_DIR/Cloudflare" \
    \( -name node_modules -o -name .wrangler -o -name .git \) -prune -o \
    -type f -name '*.js' -print0 \
    | xargs -0 -n 1 node --check
}
dependency_audit() {
  (cd "$ROOT_DIR/Cloudflare/EmergencyUpdateWorker" && npm audit --audit-level=high)
}
git_check() {
  git -C "$ROOT_DIR" diff --check || return 1
  git -C "$ROOT_DIR" diff --cached --check
}
docs_check() {
  local version_args=()
  local docs_args=()
  if [[ -n "${BIT101_VERSION_BASE_REF:-}" ]]; then
    version_args+=(--compare-git-ref "$BIT101_VERSION_BASE_REF")
  fi
  if [[ "${BIT101_RELEASE_CHECK:-false}" == "true" ]]; then
    version_args+=(--check-app-store)
  fi
  if [[ "$BIT101_AUDIT_SELF_TESTS" == 1 ]]; then docs_args+=(--self-test); fi
  (cd "$ROOT_DIR" && python3 Scripts/check-docs.py "${docs_args[@]}") || return 1
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py "${version_args[@]}")
}

module_boundary_audit() {
  if [[ "$BIT101_AUDIT_SELF_TESTS" == 1 ]]; then
    python3 "$ROOT_DIR/Scripts/check-module-boundaries.py" --self-test
  else
    python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"
  fi
}
artifact_hygiene() { python3 "$ROOT_DIR/Scripts/validation_artifacts.py" "$ROOT_DIR"; }


failed_groups=()
export BIT101_SOURCE_FACTS_CACHE="$LOG_DIR/source-facts.sqlite"
rm -f "$LOG_DIR/source-facts.json"
if (( run_artifacts )) && [[ "${BIT101_AUDIT_ARTIFACTS_PREPARED:-0}" != 1 ]]; then
  bit101_run_audit_group artifact-hygiene artifact_hygiene || failed_groups+=(artifact-hygiene)
fi
for (( index = 1; index <= ${#group_names}; index++ )); do
  bit101_start_audit_group "$group_names[$index]" "$group_commands[$index]"
done
bit101_wait_audit_groups
if (( ${#failed_groups[@]} > 0 )); then
  printf '[失败汇总] %s\n' "${(j:, :)failed_groups}" >&2
  exit 1
fi
exit 0
