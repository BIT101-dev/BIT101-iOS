#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${BIT101_STATIC_AUDIT_LOCK_HELD:-0}" != "1" ]]; then
  exec python3 - "$ROOT_DIR/.build/static-audit/audit.lock" "$0" "$@" <<'PY'
import fcntl
import os
from pathlib import Path
import subprocess
import sys

lock_path = Path(sys.argv[1])
lock_path.parent.mkdir(parents=True, exist_ok=True)
with lock_path.open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    environment = dict(os.environ, BIT101_STATIC_AUDIT_LOCK_HELD="1")
    script = Path(sys.argv[2])
    command = ["zsh", "-c", script.read_text(), str(script), *sys.argv[3:]]
    result = subprocess.run(command, env=environment)
    raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
fi

if [[ -z "${SWIFT_FRONTEND:-}" ]]; then
  SWIFT_FRONTEND="$(xcrun --find swift-frontend 2>/dev/null || true)"
fi
if [[ -z "$SWIFT_FRONTEND" || ! -x "$SWIFT_FRONTEND" ]]; then
  echo "[失败] 找不到可用的 swift-frontend；请检查当前 Xcode 工具链" >&2
  exit 1
fi
LOG_DIR="$ROOT_DIR/.build/static-audit"
AUDIT_STARTED=$SECONDS
export BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest)"

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

swift_parse() {
  find "$ROOT_DIR/Modules" "$ROOT_DIR/BIT101-iOS" "$ROOT_DIR/BIT101ScheduleWidgets" \
    "$ROOT_DIR/BIT101Watch" "$ROOT_DIR/BIT101WatchWidgets" \
    -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG || return 1
  find "$ROOT_DIR/BIT101-iOSTests" "$ROOT_DIR/BIT101-iOSUITests" "$ROOT_DIR/ModuleTests" -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG -D EXTENDED_AUTOMATION
}

shell_parse() {
  find "$ROOT_DIR/Scripts" "$ROOT_DIR/Cloudflare" "$ROOT_DIR/.githooks" \
    -path '*/node_modules' -prune -o \
    -type f \( -name '*.sh' -o -path '*/.githooks/*' \) -print0 \
    | xargs -0 -n 1 zsh -n
}
python_parse() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
for path in sorted((root / "Scripts").glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
scripts = [*(root / "Scripts").glob("*.sh"), *(root / "Cloudflare/EmergencyUpdateWorker/Scripts").glob("*.sh")]
for path in sorted(scripts):
    for block in re.finditer(r"<<'(PY\w*)'\n(.*?)^\1$", path.read_text(encoding="utf-8"), re.MULTILINE | re.DOTALL):
        compile(block[2], str(path), "exec")
PY
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
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py "${version_args[@]}")
}
checker_audit() {
  python3 "$ROOT_DIR/Scripts/check-file-lengths.py" || return 1
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" self-test || return 1
  python3 "$ROOT_DIR/Scripts/check-code-quality.py" --combined
}
module_boundary_audit() { python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"; }
artifact_hygiene() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import fcntl
import os
import sys

root = Path(sys.argv[1])
allowed_root_files = {
  ".build/extended-automation.lock",
  ".build/code-quality-report.txt",
  ".build/explanatory-text-report.txt",
  ".build/ui-consistency-report.txt",
  ".build/screenshot.png",
}
allowed_dirs = {
    "build/DeviceInstall",
    ".build/compiler-cache",
    ".build/static-audit",
    ".build/extended-automation",
    ".build/icloud-cross-device-smoke",
    ".build/release-" + "network-smoke",
    ".build/issue-report-inbox",
}
violations = []
for parent in (root / "build", root / ".build"):
    if not parent.exists():
        continue
    for child in parent.iterdir():
        if child.name == ".DS_Store":
            continue
        relative = child.relative_to(root).as_posix()
        if child.is_file():
            if relative not in allowed_root_files:
                violations.append(f"{relative}: 根目录产物必须使用固定类别文件名")
        elif relative not in allowed_dirs:
            violations.append(f"{relative}: 同类产物不得创建第二个平行目录")
shared = root / ".build/compiler-cache"
cache_names = {"SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex"}
for parent in (root / ".build", root / "build"):
    for directory, children, files in os.walk(parent):
        for name in (set(children) | set(files)) & cache_names:
            cache = Path(directory) / name
            if name in children:
                children.remove(name)
            if cache == shared / name:
                continue
            if not cache.is_symlink() or cache.resolve() != (shared / name).resolve():
                violations.append(f"{cache.relative_to(root)}: 公共编译缓存应链接到唯一共享目录")
with (root / ".build/extended-automation.lock").open("a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        if (root / ".build/extended-automation/diagnostics").exists():
            violations.append(".build/extended-automation/diagnostics: 诊断处理完成后应清除导出副本")
if violations:
    print("[失败] 产物目录不符合固定路径规则：")
    print("\n".join(violations))
    raise SystemExit(1)
PY
}

failed_groups=()
run_group artifact-hygiene artifact_hygiene || failed_groups+=(artifact-hygiene)
if (( ${#failed_groups} )); then cat "$LOG_DIR/artifact-hygiene.log" >&2; fi
group_names=(swift-parse shell-parse python-parse worker-parse dependency-audit module-boundary git-diff docs checkers)
group_commands=(swift_parse shell_parse python_parse worker_parse dependency_audit module_boundary_audit git_check docs_check checker_audit)
group_processes=()
for (( index = 1; index <= ${#group_names}; index++ )); do
  run_group "$group_names[$index]" "$group_commands[$index]" &
  group_processes+=($!)
done
for (( index = 1; index <= ${#group_names}; index++ )); do
  name="$group_names[$index]"
  if wait "$group_processes[$index]"; then
    [[ "$name" == checkers ]] || continue
  else
    failed_groups+=($name)
  fi
  log="$LOG_DIR/$name.log"
  line_count="$(wc -l < "$log")"
  if (( line_count <= 1000 )); then
    cat "$log"
  else
    echo "[输出] $name 共 $line_count 行 · $log"
  fi
done
if (( ${#failed_groups[@]} > 0 )); then
  printf '[失败汇总] %s\n' "${(j:, :)failed_groups}" >&2
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record audit 1 || true
  exit 1
fi
python3 "$ROOT_DIR/Scripts/validation_evidence.py" record audit 0
echo "静态审计通过 · 10 组 · $(( SECONDS - AUDIT_STARTED )) 秒"
