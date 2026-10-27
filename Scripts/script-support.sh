#!/bin/zsh

# 真机脚本共用设备快照，优先选择已连接设备，并提供同一设备的两种标识。
export BIT101_SCRIPTS_DIR="${${(%):-%x}:A:h}"
unset PYTHONOPTIMIZE
if command -v brew >/dev/null 2>&1; then
  bit101_python_prefix="$(brew --prefix)/opt/python@3"
  if [[ -x "$bit101_python_prefix/libexec/bin/python3" ]]; then
    export PATH="$bit101_python_prefix/libexec/bin:$PATH"
  fi
  unset bit101_python_prefix
fi

bit101_set_workflow_budget() {
  if [[ -z "${BIT101_WORKFLOW_TIMEOUT_SECONDS:-}" ]]; then
    export BIT101_WORKFLOW_TIMEOUT_SECONDS="$(python3 - "$ROOT_DIR/Scripts" "$@" <<'PYBUDGET'
import sys
sys.path.insert(0, sys.argv[1])
from validation_policy import workflow_timeout_seconds
print(workflow_timeout_seconds(tuple(sys.argv[2:])))
PYBUDGET
)"
  fi
}

bit101_acquire_workflow_lock() {
  bit101_acquire_artifact_lock "$@"
  bit101_acquire_script_lock "$HOME/Library/Caches/BIT101-iOS/device-workflow.lock" BIT101_DEVICE_WORKFLOW_LOCK_HELD "$@"
}

bit101_acquire_artifact_lock() {
  bit101_acquire_script_lock "$ROOT_DIR/.build/extended-automation.lock" BIT101_EXTENDED_TESTS_LOCK_HELD "$@"
}

bit101_invalidate_restore() {
  python3 "$ROOT_DIR/Scripts/validation_restore.py" invalidate
}

bit101_install_mac_app() {
  python3 - "$1" "$2" <<'PYMACINSTALL'
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, installed = map(Path, sys.argv[1:])
staged = installed.with_name('.BIT101-iOS.install.app')
if os.path.lexists(staged): shutil.rmtree(staged)
try:
    subprocess.run(['ditto', str(source), str(staged)], check=True)
    if installed.exists():
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        library.renamex_np.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        library.renamex_np.restype = ctypes.c_int
        # RENAME_SWAP 在同一目录原子交换完整 App，旧安装留在事务路径。
        if library.renamex_np(os.fsencode(staged), os.fsencode(installed), 0x00000002):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(installed))
    else:
        staged.rename(installed)
finally:
    if os.path.lexists(staged): shutil.rmtree(staged)
PYMACINSTALL
}

bit101_acquire_script_lock() {
  local workflow_lock="$1"
  local workflow_flag="$2"
  shift 2
  if [[ "${${(P)workflow_flag}:-0}" != "1" ]]; then
    exec python3 "$BIT101_SCRIPTS_DIR/workflow_processes.py" "$workflow_lock" "$workflow_flag" "$@"
  fi
}

bit101_log_command() {
  BIT101_COMMAND_DIAGNOSTICS="$ROOT_DIR/.build/extended-automation/diagnostics" \
    python3 "$ROOT_DIR/Scripts/command_output.py" "$@"
}

bit101_catalyst_signing_arguments() {
  if [[ "${GITHUB_ACTIONS:-false}" == true || "${BIT101_CATALYST_UNSIGNED_TESTS:-0}" == 1 ]]; then
    print -r -- CODE_SIGNING_ALLOWED=NO
  else
    print -r -- -allowProvisioningUpdates
  fi
}

bit101_build_cache() {
  python3 "$ROOT_DIR/Scripts/compiler_cache.py" "$ROOT_DIR" "$@" || return $?
  if [[ "${1:-}" == --maintenance ]]; then
    python3 "$ROOT_DIR/Scripts/validation_performance.py" recover-batch
  fi
}

bit101_run_logged() {
  if [[ "${3:-}" == xcodebuild && "${4:-}" == test-without-building ]]; then
    bit101_log_command "$@"
  elif [[ "${3:-}" == xcodebuild || ( "${3:-}" == xcrun && "${4:-}" == swift ) ]]; then
    bit101_build_cache "$@"
  else
    bit101_log_command "$@"
  fi
}

bit101_xcode_test_selections() {
  python3 - "$ROOT_DIR/Scripts" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from validation_evidence import xcode_test_selections
try:
    print('\n'.join(xcode_test_selections(sys.argv[2], sys.argv[3:])))
except ValueError as error:
    raise SystemExit(str(error))
PY
}

bit101_ui_test_selections() {
  python3 - "$ROOT_DIR/Scripts" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from validation_evidence import normalized_test_id, test_inventory
tests = sorted(normalized_test_id(test) for test in test_inventory("ui"))
selected = []
for keyword in sys.argv[2:]:
    name = keyword.removesuffix("()").casefold()
    matches = [test for test in tests if name and (
        name == test.casefold() or name in test.split("/", 1)[0].casefold()
        or name in test.split("/", 1)[1].casefold()
    )]
    if not matches:
        raise SystemExit(f"请核对 UI 用例关键词：{keyword}")
    selected.extend(matches)
print("\n".join(dict.fromkeys(selected)))
PY
}

bit101_device_snapshot() {
  xcrun devicectl list devices --quiet --json-output /dev/stdout
}

bit101_find_device() {
  if [[ -z "${1:-}" && -n "${BIT101_XCODE_DEVICE_ID:-}" && -n "${BIT101_DEVICETCL_DEVICE_ID:-}" && -n "${BIT101_DEVICE_TRANSPORT:-}" && -n "${BIT101_DEVICE_NAME:-}" ]]; then
    return 0
  fi
  local snapshot selection requested="${1:-${BIT101_XCODE_DEVICE_ID:-}}"
  local -a identifiers
  BIT101_XCODE_DEVICE_ID=""
  BIT101_DEVICETCL_DEVICE_ID=""
  BIT101_DEVICE_TRANSPORT=""
  BIT101_DEVICE_NAME=""
  snapshot="$(bit101_device_snapshot)" || return 1
  selection="$(print -r -- "$snapshot" | python3 -c '
import json
import sys

candidates = []
for device in json.load(sys.stdin)["result"]["devices"]:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    identifier = device.get("identifier", "")
    udid = hardware.get("udid", "")
    transport = connection.get("transportType")
    if hardware.get("reality") != "physical" or hardware.get("deviceType") not in {"iPhone", "iPad"}:
        continue
    if connection.get("pairingState") != "paired" or connection.get("tunnelState") not in {"connected", "disconnected"}:
        continue
    if transport not in {"wired", "localNetwork"} or not identifier or not udid or (sys.argv[1] and udid != sys.argv[1]):
        continue
    name = device.get("deviceProperties", {}).get("name") or hardware.get("deviceType", "iPhone")
    candidates.append((connection.get("tunnelState") != "connected", transport != "wired", identifier, udid, transport, name))

if candidates:
    selected = min(candidates, key=lambda candidate: (*candidate[:2], candidate[3], candidate[2]))
    print("\n".join(selected[2:]))
' "$requested")" || return 1
  [[ -n "$selection" ]] || return 1
  identifiers=("${(@f)selection}")
  BIT101_DEVICETCL_DEVICE_ID="${identifiers[1]}"
  BIT101_XCODE_DEVICE_ID="${identifiers[2]}"
  BIT101_DEVICE_TRANSPORT="${identifiers[3]}"
  BIT101_DEVICE_NAME="${identifiers[4]}"
  export BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT BIT101_DEVICE_NAME
}

bit101_require_device() {
  if bit101_find_device "${1:-}"; then
    return 0
  fi
  echo "请将已配对 iPhone 通过 USB 或同一局域网连接到 Mac 后重新运行。" >&2
  return 1
}

bit101_check_verification_audit() {
  local audit_status=0
  if [[ -n "${verification_audit_pid:-}" ]] && ! kill -0 "$verification_audit_pid" 2>/dev/null; then
    wait "$verification_audit_pid" || audit_status=$?
    verification_audit_pid=
  fi
  return "$audit_status"
}

bit101_finish_verification() {
  local verification_status=$?
  trap - EXIT ZERR
  trap '' INT TERM
  if [[ -n "$verification_audit_pid" ]]; then
    local audit_status=0
    wait "$verification_audit_pid" || audit_status=$?
    if (( verification_status == 0 )); then verification_status=$audit_status; fi
  fi
  local total_seconds="$(python3 "$ROOT_DIR/Scripts/test_results.py" elapsed)"
  echo "[完整验证总耗时] $total_seconds 秒（含等待、编译、测试及汇总）"
  exit "$verification_status"
}

bit101_verify_step() {
  local label="$1"
  shift
  bit101_check_verification_audit || return $?
  if [[ "$label" == audit && "${BIT101_AUDIT_BACKGROUND:-0}" != 1 ]]; then
    local audit_command="$1"
    "$audit_command" prepare || return $?
    (trap - EXIT ZERR INT TERM; BIT101_AUDIT_BACKGROUND=1 BIT101_AUDIT_ARTIFACTS_PREPARED=1 bit101_verify_step "$label" "$@") &
    verification_audit_pid=$!
    return 0
  fi
  local started_at=$SECONDS
  if [[ "$label" == modules ]] && python3 "$ROOT_DIR/Scripts/validation_evidence.py" check-group modules >/dev/null 2>&1; then
    echo "[验证通过] modules · 复用当前源码和执行环境的完整证据"
    return 0
  fi
  local step_status=0
  local result_step=false
  case "$label" in
    all|release-runtime|ui|catalyst|catalyst-release-runtime)
      result_step=true
      if (( ${#completed_result_groups[@]} == 0 )); then
        completed_result_groups=("${(@f)$(python3 "$ROOT_DIR/Scripts/validation_performance.py" begin-full "$label")}") || return $?
        completed_result_groups=("${(@)completed_result_groups:#}")
      else
        python3 "$ROOT_DIR/Scripts/validation_performance.py" begin-batch append || return $?
      fi
      ;;
  esac
  BIT101_VALIDATION_RESULT_BATCH_HELD=1 "$@" || step_status=$?
  if (( step_status == 130 || step_status == 143 )); then exit "$step_status"; fi
  if $result_step; then
    completed_result_groups+=("$label")
    python3 "$ROOT_DIR/Scripts/validation_performance.py" retain-batch "${completed_result_groups[@]}" || step_status=$?
  fi
  if (( step_status == 0 )); then bit101_check_verification_audit || step_status=$?; fi
  if (( step_status == 0 )); then
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" check-group "$label" || step_status=$?
  fi
  if (( step_status == 0 )); then
    echo "[验证通过] $label · $(( SECONDS - started_at )) 秒"
  else
    echo "[验证失败] $label · $(( SECONDS - started_at )) 秒" >&2
    exit 1
  fi
}

bit101_prepare_simulator_test_host() {
  simulator_prepare_pid=
  if [[ "${GITHUB_ACTIONS:-false}" == true || "$mode" == ui ]]; then
    bit101_run_logged "$DERIVED_ROOT/simulator.log" "模拟器测试环境就绪" python3 - "$ROOT_DIR/Scripts" "$SIMULATOR_DEVICE" "$ROOT_DIR" "$mode" "${GITHUB_ACTIONS:-false}" <<'PYREADY' &
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from validation_coverage import prepare_simulator_photos, prepare_simulator_system
if sys.argv[5] == 'true':
    prepare_simulator_system(sys.argv[2], Path(sys.argv[3]), ui=sys.argv[4] == 'ui')
else:
    prepare_simulator_photos(sys.argv[2], Path(sys.argv[3]))
PYREADY
    simulator_prepare_pid=$!
  fi
  simulator_build_status=0
  if [[ "$mode" == ui && "${BIT101_REUSE_UI_HOST:-0}" == 1 ]]; then
    python3 - "$ROOT_DIR/Scripts" "$DERIVED_ROOT/Build/Products" <<'PYHOST'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from validation_coverage import restore_test_host_permissions
restore_test_host_permissions(Path(sys.argv[2]))
PYHOST
    echo "[复用] 共享 UI 测试宿主"
  else
  bit101_run_logged "$DERIVED_ROOT/$mode.log" "模拟器测试宿主编译" xcodebuild build-for-testing -quiet \
    -project "$ROOT_DIR/BIT101-iOS.xcodeproj" -scheme "$scheme" -configuration "$configuration" -derivedDataPath "$DERIVED_ROOT" \
    -destination "$destination" ONLY_ACTIVE_ARCH=YES "BIT101_WORKFLOW_CONDITIONS=$conditions" ENABLE_TESTABILITY=YES \
    -enableCodeCoverage YES ENABLE_CODE_COVERAGE=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_IDENTITY=- "${only_testing[@]}" || simulator_build_status=$?
  fi
  simulator_prepare_status=0
  if [[ -n "$simulator_prepare_pid" ]]; then wait "$simulator_prepare_pid" || simulator_prepare_status=$?; fi
  if (( simulator_build_status )); then return "$simulator_build_status"; fi
  if (( simulator_prepare_status )); then return "$simulator_prepare_status"; fi
  if [[ "${GITHUB_ACTIONS:-false}" == true && "$mode" == ui ]]; then
    simulator_app_started=$SECONDS
    simulator_app_status=0
    python3 - "$ROOT_DIR/Scripts" "$SIMULATOR_DEVICE" "$DERIVED_ROOT/Build/Products" >> "$DERIVED_ROOT/simulator.log" 2>&1 <<'PYAPPREADY' || simulator_app_status=$?
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from validation_coverage import prepare_simulator_ui
prepare_simulator_ui(sys.argv[2], Path(sys.argv[3]))
PYAPPREADY
    if (( simulator_app_status )); then tail -40 "$DERIVED_ROOT/simulator.log" >&2; return "$simulator_app_status"; fi
    echo "[完成] 模拟器 App 就绪 · $(( SECONDS - simulator_app_started )) 秒"
  fi
}

bit101_run_audit_group() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  local started=$SECONDS
  local group_status=0
  if "$@" > "$log" 2>&1; then
    if [[ "$name" == checkers ]]; then bit101_show_audit_log "$log" false; fi
  else
    group_status=1
    echo "[失败] $name · $(( SECONDS - started )) 秒" >> "$log"
    bit101_show_audit_log "$log" true
  fi
  return "$group_status"
}

bit101_show_audit_log() {
  python3 "$ROOT_DIR/Scripts/command_output.py" show-log "$1" "$2"
}

bit101_start_audit_group() {
  local name="$1"
  local delegate="$2"
  local worker=$'set -euo pipefail\n'"$(typeset -f bit101_run_audit_group bit101_show_audit_log "$delegate")"$'\n''bit101_run_audit_group "$1" "$2"'
  ROOT_DIR="$ROOT_DIR" LOG_DIR="$LOG_DIR" SWIFT_FRONTEND="$SWIFT_FRONTEND" command python3 -c \
    'import os, sys; os.setsid(); os.execvp("zsh", ["zsh", "-c", sys.argv[1], "audit-group", *sys.argv[2:]])' \
    "$worker" "$name" "$delegate" &
  group_processes+=($!)
}

bit101_wait_audit_groups() {
  local remaining=${#group_processes}
  local index pid
  while (( remaining )); do
    for (( index = 1; index <= ${#group_processes}; index++ )); do
      pid=$group_processes[$index]
      if (( pid > 0 )) && ! kill -0 "$pid" 2>/dev/null; then
        local group_status=0
        wait "$pid" || group_status=$?
        python3 "$ROOT_DIR/Scripts/workflow_processes.py" finish-group "$pid" || group_status=1
        group_processes[$index]=0
        (( remaining -= 1 )) || true
        if (( group_status == 0 )); then continue; fi
        failed_groups+=("$group_names[$index]")
        if [[ "${BIT101_AUDIT_BACKGROUND:-0}" == 1 ]]; then return 0; fi
      fi
    done
    if (( remaining )); then sleep 1; fi
  done
}

bit101_checker_audit() {
  local checker_status=0
  python3 "$ROOT_DIR/Scripts/check-file-lengths.py" || checker_status=1
  python3 "$ROOT_DIR/Scripts/check-file-lengths.py" --staged || checker_status=1
  local evidence_process=
  if [[ "$BIT101_AUDIT_SELF_TESTS" == 1 ]]; then
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" self-test &
    evidence_process=$!
    python3 "$ROOT_DIR/Scripts/check-code-quality.py" --combined --self-test &
  else
    python3 "$ROOT_DIR/Scripts/check-code-quality.py" --combined &
  fi
  local quality_process=$!
  if [[ -n "$evidence_process" ]]; then wait "$evidence_process" || checker_status=1; fi
  wait "$quality_process" || checker_status=1
  return "$checker_status"
}
