#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/Scripts/script-support.sh"
bit101_acquire_artifact_lock "$0" "$@"
bit101_acquire_script_lock "$ROOT_DIR/.build/static-audit/audit.lock" BIT101_STATIC_AUDIT_LOCK_HELD "$0" "$@"
LOG_DIR="$ROOT_DIR/.build/static-audit"
AUDIT_STARTED=$SECONDS
group_processes=()
BIT101_VALIDATION_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
export BIT101_VALIDATION_STARTED_AT
finish_audit() {
  local audit_status=$?
  trap - EXIT INT TERM
  for pid in "${group_processes[@]}"; do if (( pid > 0 )); then kill "$pid" 2>/dev/null || true; fi; done
  for pid in "${group_processes[@]}"; do if (( pid > 0 )); then wait "$pid" 2>/dev/null || true; fi; done
  local record_status=0
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record audit "$audit_status" || record_status=$?
  if (( audit_status == 0 )); then audit_status=$record_status; fi
  if (( audit_status == 0 )); then echo "静态审计通过 · 10 组 · $(( SECONDS - AUDIT_STARTED )) 秒"; fi
  exit "$audit_status"
}
trap finish_audit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SWIFT_FRONTEND="$(xcrun --find swift-frontend 2>/dev/null || true)"
if [[ -z "$SWIFT_FRONTEND" || ! -x "$SWIFT_FRONTEND" ]]; then
  echo "[失败] 找不到可用的 swift-frontend；请检查当前 Xcode 工具链" >&2
  exit 1
fi
BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest audit)"
BIT101_VALIDATION_RUN_ID="$(uuidgen)"
export BIT101_VALIDATION_SOURCE_DIGEST BIT101_VALIDATION_RUN_ID

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log(N)

run_group() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  local started=$SECONDS
  if "$@" > "$log" 2>&1; then
    return 0
  else
    echo "[失败] $name · $(( SECONDS - started )) 秒" >> "$log"
    return 1
  fi
}

show_group_log() {
  local log="$1"
  local failed="$2"
  local line_count="$(wc -l < "$log")"
  if (( line_count <= 1000 )) || [[ "$failed" == true && "${GITHUB_ACTIONS:-false}" == true ]]; then
    cat "$log"
  else
    echo "[输出] ${log:t:r} 共 $line_count 行 · $log"
  fi
}

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
  python3 "$ROOT_DIR/Scripts/check-python-syntax.py" "$ROOT_DIR"
}
worker_parse() {
  find "$ROOT_DIR/Cloudflare" \
    -path '*/node_modules' -prune -o \
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
  if [[ -n "${BIT101_VERSION_BASE_REF:-}" ]]; then
    version_args+=(--compare-git-ref "$BIT101_VERSION_BASE_REF")
  fi
  if [[ "${BIT101_RELEASE_CHECK:-false}" == "true" ]]; then
    version_args+=(--check-app-store)
  fi
  (cd "$ROOT_DIR" && python3 Scripts/check-docs.py --all) || return 1
  (cd "$ROOT_DIR" && python3 Scripts/check-docs.py --staged) || return 1
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py "${version_args[@]}")
}
checker_audit() {
  python3 "$ROOT_DIR/Scripts/check-file-lengths.py" || return 1
  python3 "$ROOT_DIR/Scripts/check-file-lengths.py" --staged || return 1
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" self-test || return 1
  python3 "$ROOT_DIR/Scripts/check-code-quality.py" --combined
}
module_boundary_audit() { python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"; }
artifact_hygiene() { python3 "$ROOT_DIR/Scripts/validation_artifacts.py" "$ROOT_DIR"; }

failed_groups=()
run_group artifact-hygiene artifact_hygiene || failed_groups+=(artifact-hygiene)
if (( ${#failed_groups} )); then cat "$LOG_DIR/artifact-hygiene.log" >&2; fi
group_names=(swift-parse shell-parse python-parse worker-parse dependency-audit module-boundary git-diff docs checkers)
group_commands=(swift_parse shell_parse python_parse worker_parse dependency_audit module_boundary_audit git_check docs_check checker_audit)
for (( index = 1; index <= ${#group_names}; index++ )); do
  run_group "$group_names[$index]" "$group_commands[$index]" &
  group_processes+=($!)
done
for (( index = 1; index <= ${#group_names}; index++ )); do
  name="$group_names[$index]"
  group_failed=false
  if wait "$group_processes[$index]"; then
    group_processes[$index]=0
    [[ "$name" == checkers ]] || continue
  else
    group_processes[$index]=0
    failed_groups+=($name)
    group_failed=true
  fi
  log="$LOG_DIR/$name.log"
  show_group_log "$log" "$group_failed"
done
if (( ${#failed_groups[@]} > 0 )); then
  printf '[失败汇总] %s\n' "${(j:, :)failed_groups}" >&2
  exit 1
fi
exit 0
