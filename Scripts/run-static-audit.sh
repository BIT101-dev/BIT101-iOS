#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_FRONTEND="${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
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
  find "$ROOT_DIR/BIT101-iOS" "$ROOT_DIR/BIT101ScheduleWidget" \
    "$ROOT_DIR/BIT101Watch" "$ROOT_DIR/BIT101WatchWidgets" \
    -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG
  find "$ROOT_DIR/BIT101-iOSTests" -type f -name '*.swift' -print0 \
    | xargs -0 "$SWIFT_FRONTEND" -frontend -parse -D DEBUG -D EXTENDED_AUTOMATION
}

shell_parse() { zsh -n "$ROOT_DIR"/Scripts/*.sh; }
python_parse() { python3 -m py_compile "$ROOT_DIR"/Scripts/*.py; }
worker_parse() {
  node --check "$ROOT_DIR/Cloudflare/ErrorReportWorker/worker.js"
  node --check "$ROOT_DIR/Cloudflare/EmergencyUpdateWorker/src/index.js"
}
git_check() { git -C "$ROOT_DIR" diff --check; }
docs_check() {
  (cd "$ROOT_DIR" && python3 Scripts/check_stale_docs.py --all)
  (cd "$ROOT_DIR" && Scripts/check-error-report-coverage.sh)
  (cd "$ROOT_DIR" && python3 Scripts/validate_versions.py)
}

run_group swift-parse swift_parse
run_group shell-parse shell_parse
run_group python-parse python_parse
run_group worker-parse worker_parse
run_group git-diff git_check
run_group docs docs_check
echo "静态审计全部通过。"
