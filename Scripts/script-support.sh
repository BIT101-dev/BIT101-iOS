#!/bin/zsh

# 真机脚本共用设备快照，按有线、无线顺序选择，并提供同一设备的两种标识。

bit101_log_command() {
  local output_path="$1"
  local label="$2"
  shift 2
  python3 - "$output_path" "$label" "$@" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
import time

report_path = Path(sys.argv[1])
label = sys.argv[2]
started = time.monotonic()
report_path.parent.mkdir(parents=True, exist_ok=True)
process = subprocess.Popen(sys.argv[3:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
details = []
seen = set()
diagnostics = []
summaries = []
with report_path.open("w", encoding="utf-8") as report:
    for line in process.stdout:
        report.write(line)
        report.flush()
        if not line.strip():
            continue
        if "error:" in line or "warning:" in line:
            if line not in diagnostics:
                diagnostics.append(line)
        if "Test run with" in line:
            summaries.append(line.strip())
        if line.startswith(("Test case ", "Test suite ", "Test Case ", "Test Suite ", "◇ ", "✔ ")) and "failed" not in line.lower():
            continue
        if line.rstrip().endswith(" seconds)") and "failed" not in line.lower():
            continue
        if line.startswith(("note: Removed stale file ", "Failed frontend command:", "[Pre-planning", "[Computing dependencies]", "[Using on-disk description]", "[Planning deferred tasks]", "[Starting]")):
            continue
        if line.startswith("[") and line[1:2].isdigit():
            continue
        if "Executed 0 tests, with 0 failures" in line or "IDETestOperationsObserverDebug:" in line:
            continue
        if "IDELaunchParametersSnapshot:" in line and ("debugger version lookup failed" in line or "no debugger version" in line):
            continue
        if "swift-frontend -frontend" in line or line.lstrip().startswith("builtin-SwiftDriver -- "):
            continue
        if line not in seen:
            details.append(line)
            seen.add(line)
exit_code = process.wait()
output = details if exit_code else diagnostics
if len(output) <= 40:
    sys.stdout.writelines(output)
else:
    print(f"[输出] {label} 共 {len(output)} 行诊断 · {report_path}")
if not exit_code and summaries:
    if len(summaries) == 1:
        print(summaries[0])
    else:
        counts = [int(re.search(r"Test run with (\d+) tests?", line)[1]) for line in summaries]
        print(f"Swift Testing：{sum(counts)} 项通过 · {len(summaries)} 个测试进程")
state = "失败" if exit_code else "完成"
print(f"[{state}] {label} · {time.monotonic() - started:.1f} 秒")
raise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)
PY
}

bit101_build_cache() {
  python3 - "$ROOT_DIR" "$@" <<'PY'
import fcntl
from contextlib import nullcontext
import os
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
arguments = sys.argv[2:]
maintenance = arguments == ["--maintenance"]
shared = root / ".build/compiler-cache"
shared.mkdir(parents=True, exist_ok=True)
cache_names = ("SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex")
derived_roots = [root / name for name in (
    ".build/extended-automation", "build/DeviceInstall", ".build/release-network-smoke",
    ".build/icloud-cross-device-smoke/Phone", ".build/icloud-cross-device-smoke/Mac",
    ".build/extended-automation/out", ".build/static-audit/package-build/out",
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

with ((root / ".build/extended-automation.lock").open("a") if maintenance else nullcontext()) as results_lock, \
        (shared / "cache.lock").open("a") as lock:
    if results_lock is not None:
        fcntl.flock(results_lock, fcntl.LOCK_EX)
    fcntl.flock(lock, fcntl.LOCK_EX)
    before = occupied_kib() if maintenance else 0
    if not maintenance:
        command = arguments[2:]
        if command[0] == "xcodebuild" and any(action in command for action in ("build", "build-for-testing", "test")) \
                and "archive" not in command and not any(value.startswith("DEBUG_INFORMATION_FORMAT=") for value in command):
            arguments.append("DEBUG_INFORMATION_FORMAT=dwarf")
        for option in ("-derivedDataPath", "--scratch-path"):
            if option in command:
                requested = Path(command[command.index(option) + 1])
                if requested not in derived_roots:
                    raise SystemExit(f"构建缓存入口需要登记：{requested}")
                requested.mkdir(parents=True, exist_ok=True)
    for name in cache_names:
        (shared / name).mkdir(exist_ok=True)
    for derived in derived_roots:
        if derived.is_dir():
            for name in cache_names:
                share_cache(derived / name, shared / name)
    if maintenance:
        shutil.rmtree(root / ".build/ui-authorization.logarchive", ignore_errors=True)
        shutil.rmtree(root / ".build/extended-automation/diagnostics", ignore_errors=True)
        (shared / "compression-stage").unlink(missing_ok=True)
        implicit_removed = 0
        implicit_bytes = 0
        for context in (shared / "ModuleCache.noindex").iterdir():
            if not context.is_dir():
                continue
            module = next(context.glob("*.pcm"), None)
            if module is None:
                continue
            info = subprocess.run(["xcrun", "clang", "-module-file-info", str(module)],
                                  capture_output=True, text=True)
            triple = re.search(r"(?mi)^\s*(?:target )?triple:\s*(\S+)", info.stdout)
            if info.returncode == 0 and triple and triple[1].endswith("-simulator"):
                implicit_bytes += sum(path.stat().st_blocks * 512 for path in context.rglob("*") if path.is_file())
                shutil.rmtree(context)
                implicit_removed += 1
        if implicit_removed:
            print(f"失效平台模块：清理 {implicit_removed} 组 · {implicit_bytes / 1048576:.1f} MiB")
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
                        for path in sorted(parent.rglob("*simulator*"), key=lambda path: len(path.parts), reverse=True):
                            if path.is_dir() and path.name.endswith(("-iphonesimulator", "-watchsimulator")):
                                shutil.rmtree(path)
                            elif path.is_file() and path.suffix == ".xctestrun":
                                path.unlink()
            shutil.rmtree(derived / "Logs/Test", ignore_errors=True)
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
            'source "$1/Scripts/script-support.sh"; shift; bit101_log_command "$@"',
            "cache-build", str(root), *arguments])
        raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
}

bit101_run_logged() {
  if [[ "${3:-}" == xcodebuild || ( "${3:-}" == xcrun && "${4:-}" == swift ) ]]; then
    bit101_build_cache "$@"
  else
    bit101_log_command "$@"
  fi
}

bit101_device_snapshot() {
  xcrun devicectl list devices --quiet --json-output /dev/stdout
}

bit101_find_device() {
  local requested_device="${1:-}"
  if [[ -n "${BIT101_XCODE_DEVICE_ID:-}" && -n "${BIT101_DEVICETCL_DEVICE_ID:-}" && -n "${BIT101_DEVICE_TRANSPORT:-}" ]]; then
    if [[ -z "$requested_device" || "${(U)requested_device}" == "${(U)BIT101_XCODE_DEVICE_ID}" || "${(U)requested_device}" == "${(U)BIT101_DEVICETCL_DEVICE_ID}" ]]; then
      return 0
    fi
  fi
  local snapshot selection
  local -a identifiers
  BIT101_XCODE_DEVICE_ID=""
  BIT101_DEVICETCL_DEVICE_ID=""
  BIT101_DEVICE_TRANSPORT=""
  snapshot="$(bit101_device_snapshot)" || return 1
  selection="$(print -r -- "$snapshot" | python3 -c '
import json
import sys

requested = sys.argv[1].upper()
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
    if transport not in {"wired", "localNetwork"} or not identifier or not udid:
        continue
    if requested and requested not in {identifier.upper(), udid.upper()}:
        continue
    candidates.append((transport != "wired", identifier, udid, transport))

if candidates:
    selected = min(candidates, key=lambda candidate: candidate[0])
    print("\n".join(selected[1:]))
' "$requested_device")" || return 1
  [[ -n "$selection" ]] || return 1
  identifiers=("${(@f)selection}")
  BIT101_DEVICETCL_DEVICE_ID="${identifiers[1]}"
  BIT101_XCODE_DEVICE_ID="${identifiers[2]}"
  BIT101_DEVICE_TRANSPORT="${identifiers[3]}"
  export BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT
}

bit101_require_device() {
  if bit101_find_device "${1:-}"; then
    return 0
  fi
  echo "请将${1:+设备 $1 对应的}已配对 iPhone 通过 USB 或同一局域网连接到 Mac 后重新运行。" >&2
  return 1
}
