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
  local output_path="$1"
  local label="$2"
  shift 2
  BIT101_COMMAND_DIAGNOSTICS="$ROOT_DIR/.build/extended-automation/diagnostics" python3 /dev/fd/3 "$output_path" "$label" "$@" 3<<'PY'
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import signal
from collections import deque

signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
report_path = Path(sys.argv[1])
label = sys.argv[2]
started = time.monotonic()
report_path.parent.mkdir(parents=True, exist_ok=True)
process = subprocess.Popen(sys.argv[3:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
diagnostics = []
diagnostic_seen = set()
errors = []
error_seen = set()
display_limit = 40
recent_details = deque(maxlen=display_limit)
detail_count = diagnostic_count = module_scan_count = 0
summary_count = summary_tests = 0
summary = ""
temporary_results = set()
def useful_line(line):
    if not line.strip(): return False
    if re.match(r"^\s*t =\s*(?:[\d.]+s|nans)\s", line) and not re.search(r"error:|failed", line, re.IGNORECASE): return False
    if line.startswith("UI control inventory: "): return False
    if re.match(r"warning: '.+' is missing a dependency on '.+' because dependency scan of Swift module", line): return False
    if line.startswith(("Test case ", "Test Case ")) and re.search(r"\bpassed(?: on | \(|$)", line): return False
    if line.startswith(("◇ ", "✔ ")): return False
    if line.startswith(("Test case ", "Test suite ", "Test Case ", "Test Suite ")) and "failed" not in line.lower(): return False
    if line.rstrip().endswith(" seconds)") and "failed" not in line.lower(): return False
    if line.startswith(("note: Removed stale file ", "Failed frontend command:", "[Pre-planning", "[Computing dependencies]", "[Using on-disk description]", "[Planning deferred tasks]", "[Starting]")): return False
    if line.startswith("[") and line[1:2].isdigit(): return False
    if "Executed 0 tests, with 0 failures" in line or "IDETestOperationsObserverDebug:" in line: return False
    if "IDELaunchParametersSnapshot:" in line and ("debugger version lookup failed" in line or "no debugger version" in line): return False
    return "swift-frontend -frontend" not in line and not line.lstrip().startswith("builtin-SwiftDriver -- ")
with report_path.open("w", encoding="utf-8") as report:
    for line in process.stdout:
        report.write(line)
        report.flush()
        if label == "模拟器测试" and os.environ.get("GITHUB_ACTIONS") == "true" \
                and re.match(r"Test Case .+ (?:passed|failed) \([\d.]+ seconds\)\.", line):
            print("[用例] " + line.strip(), flush=True)
        if sys.argv[3] == "xcodebuild":
            match = re.search(r"Writing error result bundle to (.+\.xcresult)\s*$", line)
            if match:
                path = Path(match[1])
                if path.parent.resolve() == Path(tempfile.gettempdir()).resolve() and path.name.startswith("ResultBundle_"):
                    temporary_results.add(path)
                    continue
        if not line.strip():
            continue
        if "error:" in line.lower() or useful_line(line) and (line.lstrip().startswith("✘") or "failed" in line.lower()):
            if line not in error_seen and len(errors) < display_limit:
                errors.append(line)
                error_seen.add(line)
        if "error:" in line or "warning:" in line or useful_line(line) and (line.lstrip().startswith("✘") or "failed" in line.lower()):
            if re.match(r"warning: '.+' is missing a dependency on '.+' because dependency scan of Swift module", line):
                module_scan_count += 1
            elif line not in diagnostic_seen:
                diagnostic_count += 1
                if len(diagnostics) < display_limit:
                    diagnostics.append(line)
                    diagnostic_seen.add(line)
        if "Test run with" in line:
            summary = line.strip()
            summary_count += 1
            summary_tests += int(re.search(r"Test run with (\d+) tests?", line)[1])
        if useful_line(line):
            recent_details.append(line)
            detail_count += 1
exit_code = process.wait()
for path in temporary_results:
    if exit_code and path.is_dir():
        destination = Path(os.environ['BIT101_COMMAND_DIAGNOSTICS']) / 'test-results.xcresult'
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(destination, ignore_errors=True)
        shutil.move(str(path), str(destination))
        print(f"[诊断] 构建失败结果包 · {destination}")
    else:
        shutil.rmtree(path, ignore_errors=True)
output = list(dict.fromkeys([*errors, *diagnostics, *recent_details]))[:display_limit] if exit_code else diagnostics
output_count = detail_count if exit_code else diagnostic_count
if not exit_code and module_scan_count:
    print(f"[提示] 编译器模块依赖扫描 · {module_scan_count} 条 · {report_path}")
if exit_code and os.environ.get("GITHUB_ACTIONS") == "true":
    with report_path.open(encoding="utf-8") as report:
        for line in report:
            if useful_line(line): sys.stdout.write(line)
elif output_count <= display_limit:
    sys.stdout.writelines(output)
else:
    sys.stdout.writelines(output)
    print(f"[输出] {label} 共 {output_count} 行诊断 · {report_path}")
if not exit_code and summary_count:
    if summary_count == 1:
        print(summary)
    else:
        print(f"Swift Testing：{summary_tests} 项通过 · {summary_count} 个测试进程")
state = "失败" if exit_code else "完成"
print(f"[{state}] {label} · {time.monotonic() - started:.1f} 秒")
raise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)
PY
}

bit101_catalyst_signing_arguments() {
  if [[ "${GITHUB_ACTIONS:-false}" == true || "${BIT101_CATALYST_UNSIGNED_TESTS:-0}" == 1 ]]; then
    print -r -- CODE_SIGNING_ALLOWED=NO
  else
    print -r -- -allowProvisioningUpdates
  fi
}

bit101_build_cache() {
  python3 - "$ROOT_DIR" "$@" <<'PY' || return $?
import fcntl
from contextlib import nullcontext
import os
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import signal

signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
root = Path(sys.argv[1])
sys.path.insert(0, str(root / "Scripts"))
from validation_artifacts import clear_diagnostic_exports
arguments = sys.argv[2:]
maintenance = arguments == ["--maintenance"]
shared = root / ".build/compiler-cache"
shared.mkdir(parents=True, exist_ok=True)
cache_names = ("SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "Index.noindex")
derived_roots = [root / name for name in (
    ".build/extended-automation", "build/DeviceInstall", ".build/release-network-smoke",
    ".build/icloud-cross-device-smoke/Phone", ".build/icloud-cross-device-smoke/Mac",
    ".build/extended-automation/out",
)]

def occupied_kib():
    paths = [str(root / name) for name in (".build", "build") if (root / name).exists()]
    return sum(int(line.split()[0]) for line in subprocess.check_output(["du", "-sk", *paths], text=True).splitlines())

def share_cache(source, destination):
    if source.is_symlink():
        if source.resolve() != destination.resolve():
            raise SystemExit(f"缓存链接目标需要核对：{source}")
        return
    if source.exists():
        if not source.is_dir():
            raise SystemExit(f"编译缓存应为目录：{source}")
        if source.name == "CompilationCache.noindex":
            def occupied_blocks(path):
                return sum(item.stat().st_blocks for item in path.rglob("*") if item.is_file())
            # CAS 的索引、动作与数据属于同一命名空间，整体保留已有内容较多的目录。
            if occupied_blocks(source) > occupied_blocks(destination):
                shutil.rmtree(destination)
                source.replace(destination)
            else:
                shutil.rmtree(source)
            source.symlink_to(destination, target_is_directory=True)
            return
        for directory, children, files in os.walk(source, topdown=False):
            directory = Path(directory)
            target = destination / directory.relative_to(source)
            target.mkdir(parents=True, exist_ok=True)
            for name in files:
                original, retained = directory / name, target / name
                if retained.exists() and retained.stat().st_mtime_ns >= original.stat().st_mtime_ns:
                    original.unlink()
                else:
                    original.replace(retained)
            for name in children:
                child = directory / name
                if child.is_symlink():
                    raise SystemExit(f"缓存内部链接需要核对：{child}")
            directory.rmdir()
    source.symlink_to(destination, target_is_directory=True)

with ((root / ".build/extended-automation.lock").open("a")
      if maintenance and os.environ.get("BIT101_EXTENDED_TESTS_LOCK_HELD") != "1" else nullcontext()) as results_lock, \
        (shared / "cache.lock").open("a") as lock:
    if results_lock is not None:
        fcntl.flock(results_lock, fcntl.LOCK_EX)
    fcntl.flock(lock, fcntl.LOCK_EX)
    before = occupied_kib() if maintenance else 0
    if not maintenance:
        command = arguments[2:]
        if command[0] == "xcodebuild" and any(action in command for action in ("build", "build-for-testing", "test", "archive")):
            defaults = ["SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "GCC_TREAT_WARNINGS_AS_ERRORS=YES", "COMPILATION_CACHE_ENABLE_CACHING=YES",
                        "SWIFT_ENABLE_PREFIX_MAPPING=YES", "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES",
                        "CLANG_ENABLE_PREFIX_MAPPING=YES", "CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES"]
            for setting in defaults:
                if not any(value.startswith(setting.split("=", 1)[0] + "=") for value in command):
                    arguments.append(setting)
        if command[:2] == ["xcrun", "swift"] and command[2:3] in (["build"], ["test"]):
            for option, value in (("-Xswiftc", "-warnings-as-errors"), ("-Xcc", "-Werror")):
                if value not in command: arguments.extend((option, value))
        for option in ("-derivedDataPath", "--scratch-path"):
            if option in command:
                requested = Path(command[command.index(option) + 1])
                if requested not in derived_roots:
                    raise SystemExit(f"构建缓存入口需要登记：{requested}")
                requested.mkdir(parents=True, exist_ok=True)
                if command[0] == "xcodebuild":
                    # SwiftPM 的静态与框架布局共用中间产物，旧平面模块会遮蔽框架内的新模块。
                    for framework in (requested / "Build/Products").glob("*/PackageFrameworks/*.framework"):
                        flat_module = framework.parent.parent / f"{framework.stem}.swiftmodule"
                        if flat_module.is_dir():
                            shutil.rmtree(flat_module)
                            flat_module.with_suffix(".o").unlink(missing_ok=True)
    for name in cache_names:
        (shared / name).mkdir(exist_ok=True)
    for derived in derived_roots:
        if derived.is_dir():
            for name in cache_names:
                share_cache(derived / name, shared / name)
    for name in ("testPhoneUpload.log", "testPhoneVerifyAndCleanup.log"):
        (root / ".build/icloud-cross-device-smoke" / name).unlink(missing_ok=True)
    if maintenance:
        shutil.rmtree(root / ".build/static-audit/package-build", ignore_errors=True)
        shutil.rmtree(root / ".build/ui-authorization.logarchive", ignore_errors=True)
        clear_diagnostic_exports(root / ".build/extended-automation/diagnostics")
        (shared / "compression-stage").unlink(missing_ok=True)
        for derived in derived_roots:
            for build in (derived / "Build", derived):
                for parent in (build / "Products", build / "Intermediates.noindex"):
                    if parent.is_dir():
                        if parent.name == "Products":
                            for symbols in parent.rglob("*.dSYM"):
                                bundled = any(path.suffix in (".app", ".appex", ".framework", ".xctest")
                                              for path in symbols.relative_to(parent).parents)
                                if symbols.is_dir() and not bundled:
                                    shutil.rmtree(symbols)
            for diagnostic in (derived / 'Logs/Test').glob('*'):
                if diagnostic.name == 'test-results.xcresult': continue
                if diagnostic.is_dir(): shutil.rmtree(diagnostic)
                else: diagnostic.unlink()
        referenced = set()
        maps_complete = True
        for derived in derived_roots:
            for source in derived.rglob("*dependencies*.json"):
                try:
                    dependency_map = json.loads(source.read_text())
                except (ValueError, UnicodeError):
                    maps_complete = False
                    continue
                pending = [dependency_map]
                while pending:
                    value = pending.pop()
                    if isinstance(value, dict):
                        pending.extend(value.values())
                    elif isinstance(value, list):
                        pending.extend(value)
                    elif isinstance(value, str) and value.endswith(".pcm"):
                        path = Path(value).resolve()
                        if path.is_relative_to(shared / "SDKExplicitPrecompiledModules"):
                            referenced.add(path)
        if maps_complete and referenced:
            for module in (shared / "SDKExplicitPrecompiledModules").glob("*.pcm"):
                if module not in referenced:
                    module.unlink()
        after = occupied_kib()
        print(f"缓存整理：{before / 1048576:.2f} → {after / 1048576:.2f} GiB；释放 {(before - after) / 1048576:.2f} GiB")
    else:
        result = subprocess.run(["zsh", "-c",
            'ROOT_DIR="$1"; source "$ROOT_DIR/Scripts/script-support.sh"; shift; bit101_log_command "$@"',
            "cache-build", str(root), *arguments])
        raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
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
