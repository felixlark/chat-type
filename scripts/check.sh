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

SWIFT_TEST_ARGS=(--package-path "$ROOT" --scratch-path "${CHATTYPE_SCRATCH_PATH:-$HOME/Library/Caches/chat-type/swiftpm}" --cache-path "$HOME/Library/Caches/chat-type/swiftpm-cache")
TIMING_TESTS=(
  terminologyNormalizerKeepsLargeDictionaryWithinInteractiveBudget
  capturedBacklogDrainsAfterSlowHandshakeWithoutASecondMediaClock
)
# Swift Testing runs unrelated tests concurrently. Measure wall-clock budgets
# in separate processes so the rest of the suite cannot consume their budget.
# Keep both original assertions and run every other test normally.
TIMING_FILTER="$(IFS='|'; echo "${TIMING_TESTS[*]}")"
swift test "${SWIFT_TEST_ARGS[@]}" --skip "$TIMING_FILTER"
TEST_LIST="$(mktemp)"
trap 'rm -f "$TEST_LIST"' EXIT
# A file avoids waiting for inherited stdout pipes from test discovery helpers.
swift test "${SWIFT_TEST_ARGS[@]}" list --skip-build > "$TEST_LIST"
for test_name in "${TIMING_TESTS[@]}"; do
  if ! grep -Fxq "ChatTypeTests.$test_name()" "$TEST_LIST"; then
    echo "Missing timing test: $test_name" >&2
    exit 1
  fi
  # Swift Testing's filter IDs omit the parentheses shown by `test list`.
  swift test "${SWIFT_TEST_ARGS[@]}" --skip-build --filter "$test_name"
done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/Tests/ToolTests"
for script in "$ROOT"/scripts/*.sh "$ROOT"/script/*.sh; do bash -n "$script"; done
bash "$ROOT/scripts/check_policy.sh"
node "$ROOT/scripts/check_landing_page.mjs"
if [[ "$SOURCE_ONLY" == 0 ]]; then bash "$ROOT/scripts/check_packaged_app.sh"; fi
