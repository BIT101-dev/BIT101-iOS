#!/bin/zsh

# 真机脚本共用设备快照，优先选择已连接设备，并提供同一设备的两种标识。
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
    exec python3 - "$workflow_lock" "$workflow_flag" "$@" <<'PYLOCK'
import fcntl
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

lock_path = Path(sys.argv[1])
lock_path.parent.mkdir(parents=True, exist_ok=True)
with lock_path.open("a") as lock:
    timeout = float(os.environ.get("BIT101_WORKFLOW_TIMEOUT_SECONDS", 45 * 60))
    if not math.isfinite(timeout) or timeout <= 0:
        raise SystemExit("工作流执行预算需要有限正数。")
    deadline = float(os.environ.get("BIT101_WORKFLOW_DEADLINE", time.monotonic() + timeout))
    if not math.isfinite(deadline): raise SystemExit("工作流截止时间需要有限值。")
    announced = False
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if not announced:
                print("[等待] 既有工作流正在使用固定产物与设备。", flush=True)
                announced = True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print("[超时] 工作流锁等待已达到执行预算。", flush=True)
                raise SystemExit(124)
            time.sleep(min(0.1, remaining))
    environment = dict(os.environ)
    environment[sys.argv[2]] = "1"
    environment["BIT101_WORKFLOW_DEADLINE"] = str(deadline)
    script = Path(sys.argv[3])
    command = ["zsh", "-c", script.read_text(), str(script), *sys.argv[4:]]
    owns_process_group = not any(os.environ.get(flag) == "1"
        for flag in ("BIT101_DEVICE_WORKFLOW_LOCK_HELD", "BIT101_EXTENDED_TESTS_LOCK_HELD"))
    process = None
    pending_signal = None
    def interrupt(signum, _frame):
        global pending_signal
        if process is None:
            pending_signal = signum
            return
        try:
            if owns_process_group and process.poll() is None: os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)
    process = subprocess.Popen(command, env=environment, start_new_session=owns_process_group)
    if pending_signal is not None and process.poll() is None:
        if owns_process_group: interrupt(pending_signal, None)
        else: process.send_signal(pending_signal)
    try:
        status = process.wait(timeout=max(0, deadline - time.monotonic())) if owns_process_group else process.wait()
    except subprocess.TimeoutExpired:
        print("[超时] 工作流已达到执行预算，正在恢复与结束。", flush=True)
        os.killpg(process.pid if owns_process_group else os.getpgrp(), signal.SIGTERM)
        try: process.wait(timeout=5 * 60)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid if owns_process_group else os.getpgrp(), signal.SIGKILL)
            process.wait()
        raise SystemExit(124)
    raise SystemExit(status if status >= 0 else 128 - status)
PYLOCK
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
        name == test.casefold() or name == test.split("/", 1)[0].casefold()
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
