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

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log(N)

run_group() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  local started=$SECONDS
  if "$@" > "$log" 2>&1; then
    if [[ "$name" == checkers ]]; then
      local line_count="$(wc -l < "$log")"
      if (( line_count <= 1000 )); then
        cat "$log"
      else
        echo "[输出] $name 共 $line_count 行 · $log"
      fi
    fi
    return 0
  else
    local line_count="$(wc -l < "$log")"
    if (( line_count <= 1000 )); then
      cat "$log" >&2
    else
      echo "[输出] $name 共 $line_count 行 · $log" >&2
    fi
    echo "[失败] $name · $(( SECONDS - started )) 秒" >&2
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
  (cd "$ROOT_DIR" && python3 Scripts/check_stale_docs.py --all) || return 1
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py "${version_args[@]}")
}
checker_audit() { python3 "$ROOT_DIR/Scripts/check-code-quality.py" --combined; }
module_boundary_audit() { python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"; }
artifact_hygiene() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
allowed_root_files = {
  ".build/extended-automation.lock",
  ".build/code-quality-report.txt",
  ".build/explanatory-text-report.txt",
  ".build/stale-docs-report.txt",
  ".build/ui-consistency-report.txt",
  ".build/screenshot.png",
}
allowed_dirs = {
    "build/DeviceInstall",
    "build/Tests",
    "build/CI",
    "build/DeviceReview",
    "build/UpdatePromptTest",
    ".build/static-audit",
    ".build/extended-automation",
    ".build/icloud-cross-device-smoke",
    ".build/release-" + "network-smoke",
    ".build/issue-report-inbox",
    ".build/ui-authorization.logarchive",
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
if violations:
    print("[失败] 产物目录不符合固定路径规则：")
    print("\n".join(violations))
    raise SystemExit(1)
PY
}

failed_groups=()
run_group swift-parse swift_parse || failed_groups+=(swift-parse)
run_group shell-parse shell_parse || failed_groups+=(shell-parse)
run_group python-parse python_parse || failed_groups+=(python-parse)
run_group worker-parse worker_parse || failed_groups+=(worker-parse)
run_group dependency-audit dependency_audit || failed_groups+=(dependency-audit)
run_group module-boundary module_boundary_audit || failed_groups+=(module-boundary)
run_group git-diff git_check || failed_groups+=(git-diff)
run_group docs docs_check || failed_groups+=(docs)
run_group checkers checker_audit || failed_groups+=(checkers)
run_group artifact-hygiene artifact_hygiene || failed_groups+=(artifact-hygiene)
if (( ${#failed_groups[@]} > 0 )); then
  printf '[失败汇总] %s\n' "${(j:, :)failed_groups}" >&2
  exit 1
fi
echo "静态审计通过 · 10 组 · $(( SECONDS - AUDIT_STARTED )) 秒"
