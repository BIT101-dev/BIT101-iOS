#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIT101_NETWORK_SMOKE_SCOPE=school exec "$SCRIPT_DIR/release-network-smoke.sh" "$@"
