#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ONLY=0
case "${1:-}" in
  --source) SOURCE_ONLY=1 ;;
  "") ;;
  *) echo "Usage: $0 [--source]" >&2; exit 64 ;;
esac
bash "$ROOT/scripts/build_opus.sh" >/dev/null

swift test --package-path "$ROOT" --scratch-path "${CHATTYPE_SCRATCH_PATH:-$HOME/Library/Caches/chat-type/swiftpm}" --cache-path "$HOME/Library/Caches/chat-type/swiftpm-cache"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/Tests/ToolTests"
for script in "$ROOT"/scripts/*.sh "$ROOT"/script/*.sh; do bash -n "$script"; done
bash "$ROOT/scripts/check_policy.sh"
node "$ROOT/scripts/check_landing_page.mjs"
if [[ "$SOURCE_ONLY" == 0 ]]; then bash "$ROOT/scripts/check_packaged_app.sh"; fi
