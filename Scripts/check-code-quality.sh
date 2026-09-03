#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT_DIR/Scripts/check-code-quality.py"
