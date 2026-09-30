#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${SWIFT_FRONTEND:-}" ]]; then
  SWIFT_FRONTEND="$(xcrun --find swift-frontend 2>/dev/null || true)"
fi
if [[ -z "$SWIFT_FRONTEND" || ! -x "$SWIFT_FRONTEND" ]]; then
  echo "[失败] 找不到可用的 swift-frontend；请检查当前 Xcode 工具链" >&2
  exit 1
fi
LOG_DIR="$ROOT_DIR/.build/static-audit"

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log(N)

run_group() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  local output
  local line_count
  local exit_code
  if output="$("$@" 2>&1)"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [[ -n "$output" ]]; then
    line_count="$(printf '%s\n' "$output" | wc -l | tr -d '[:space:]')"
  else
    line_count=0
  fi

  if (( line_count <= 1000 )); then
    if [[ -n "$output" ]]; then
      print -r -- "$output"
    fi
  else
    printf '%s\n' "$output" > "$log"
    echo "[输出] $name 共 $line_count 行，详情写入 $log"
  fi

  if (( exit_code == 0 )); then
    echo "[通过] $name"
  else
    echo "[失败] $name" >&2
    return 1
  fi
}

swift_parse() {
  find "$ROOT_DIR/Modules" "$ROOT_DIR/BIT101-iOS" "$ROOT_DIR/BIT101ScheduleWidgets" \
    "$ROOT_DIR/BIT101Watch" "$ROOT_DIR/BIT101WatchWidgets" \
    -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG
  find "$ROOT_DIR/BIT101-iOSTests" "$ROOT_DIR/ModuleTests" -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG -D EXTENDED_AUTOMATION
}

shell_parse() {
  local script
  for script in "$ROOT_DIR"/Scripts/*.sh; do
    zsh -n "$script" || return 1
  done
}
python_parse() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]) / "Scripts"
for path in sorted(root.glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
for path in sorted(root.glob("*.sh")):
    for block in re.finditer(r"<<'PY'\n(.*?)^PY$", path.read_text(encoding="utf-8"), re.MULTILINE | re.DOTALL):
        compile(block[1], str(path), "exec")
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
  git -C "$ROOT_DIR" diff --check
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
  (cd "$ROOT_DIR" && python3 Scripts/check_stale_docs.py --all)
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py "${version_args[@]}")
}
explanatory_text_report() { "$ROOT_DIR/Scripts/report-explanatory-text.sh"; }
checker_audit() { python3 "$ROOT_DIR/Scripts/check-code-quality.py" --combined; }
module_boundary_audit() { python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"; }
artifact_hygiene() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
allowed_root_files = {
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
run_group explanatory-text explanatory_text_report || failed_groups+=(explanatory-text)
run_group artifact-hygiene artifact_hygiene || failed_groups+=(artifact-hygiene)
if (( ${#failed_groups[@]} > 0 )); then
  printf '[失败汇总] %s\n' "${(j:, :)failed_groups}" >&2
  exit 1
fi
echo "静态审计全部通过。"
