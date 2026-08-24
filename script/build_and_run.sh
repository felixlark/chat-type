#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatType"
APP_DIR="/Applications/$APP_NAME.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

"$ROOT/scripts/package_app.sh" >/dev/null
"$ROOT/scripts/install_app.sh" >/dev/null

open -n "$APP_DIR"
sleep 1
pgrep -x "$APP_NAME" >/dev/null
