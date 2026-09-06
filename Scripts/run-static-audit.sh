#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${SWIFT_FRONTEND:-}" ]]; then
  developer_dir="${DEVELOPER_DIR:-}"
  if [[ -z "$developer_dir" && -d "/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer" ]]; then
    developer_dir="/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer"
  fi
  if [[ -n "$developer_dir" && -x "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend" ]]; then
    SWIFT_FRONTEND="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
  else
    SWIFT_FRONTEND="$(xcrun --find swift-frontend 2>/dev/null || true)"
  fi
fi
if [[ -z "$SWIFT_FRONTEND" || ! -x "$SWIFT_FRONTEND" ]]; then
  echo "[失败] 找不到可用的 swift-frontend；请设置 SWIFT_FRONTEND 或 DEVELOPER_DIR" >&2
  exit 1
fi
LOG_DIR="$ROOT_DIR/.build/static-audit"

mkdir -p "$LOG_DIR"

run_group() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  if "$@" > "$log" 2>&1; then
    echo "[通过] $name"
  else
    echo "[失败] $name" >&2
    cat "$log" >&2
    exit 1
  fi
}

swift_parse() {
  find "$ROOT_DIR/BIT101-iOS" "$ROOT_DIR/BIT101ScheduleWidgets" \
    "$ROOT_DIR/BIT101Watch" "$ROOT_DIR/BIT101WatchWidgets" \
    -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG
  find "$ROOT_DIR/BIT101-iOSTests" -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG -D EXTENDED_AUTOMATION
}

shell_parse() { zsh -n "$ROOT_DIR"/Scripts/*.sh; }
python_parse() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "Scripts"
for path in sorted(root.glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
}
worker_parse() {
  find "$ROOT_DIR/Cloudflare" \
    -path '*/node_modules' -prune -o \
    -type f -name '*.js' -exec node --check {} +
}
git_check() { git -C "$ROOT_DIR" diff --check; }
docs_check() {
  (cd "$ROOT_DIR" && python3 Scripts/check_stale_docs.py --all)
  (cd "$ROOT_DIR" && Scripts/check-error-report-coverage.sh)
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py)
}
ui_consistency() { "$ROOT_DIR/Scripts/check-ui-consistency.sh"; }
haptic_consistency() { "$ROOT_DIR/Scripts/check-haptic-consistency.sh"; }
component_consistency() { "$ROOT_DIR/Scripts/check-component-consistency.sh"; }
explanatory_text_report() { "$ROOT_DIR/Scripts/report-explanatory-text.sh"; }
code_quality() { "$ROOT_DIR/Scripts/check-code-quality.sh"; }
artifact_hygiene() {
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
allowed_root_files = {
    ".build/code-quality-report.txt",
    ".build/explanatory-text-report.txt",
    ".build/screenshot.png",
}
allowed_dirs = {
    "build/DeviceInstall",
    "build/Tests",
    "build/DeviceReview",
    "build/UpdatePromptTest",
    ".build/static-audit",
    ".build/extended-automation",
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
if violations:
    print("[失败] 产物目录不符合固定路径规则：")
    print("\n".join(violations))
    raise SystemExit(1)
print("[通过] artifact-hygiene")
PY
}

run_group swift-parse swift_parse
run_group shell-parse shell_parse
run_group python-parse python_parse
run_group worker-parse worker_parse
run_group git-diff git_check
run_group docs docs_check
run_group ui-consistency ui_consistency
run_group haptic-consistency haptic_consistency
run_group component-consistency component_consistency
run_group code-quality code_quality
run_group explanatory-text explanatory_text_report
run_group artifact-hygiene artifact_hygiene
echo "静态审计全部通过。"
