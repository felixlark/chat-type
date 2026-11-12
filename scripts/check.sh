#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift build --package-path "$ROOT" --scratch-path "${CHATTYPE_SCRATCH_PATH:-$HOME/Library/Caches/chat-type/swiftpm}" --cache-path "$HOME/Library/Caches/chat-type/swiftpm-cache"
swift test --package-path "$ROOT" --scratch-path "${CHATTYPE_SCRATCH_PATH:-$HOME/Library/Caches/chat-type/swiftpm}" --cache-path "$HOME/Library/Caches/chat-type/swiftpm-cache"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/Tests/ToolTests"
bash -n "$ROOT/scripts/doctor.sh"
bash "$ROOT/scripts/check_policy.sh"
node "$ROOT/scripts/check_landing_page.mjs"
bash "$ROOT/scripts/check_packaged_app.sh"
