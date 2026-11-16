#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatType"
APP_DIR="/Applications/ChatType.app"
APP_BINARY="$APP_DIR/Contents/MacOS/$APP_NAME"
OUT_ROOT="${CHATTYPE_VISUAL_OUT_ROOT:-$HOME/Library/Logs/ChatType/visual-acceptance}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OUT_ROOT/$RUN_ID"

INSTALL_FIRST=0
if [[ "${1:-}" == "--install" ]]; then
  INSTALL_FIRST=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--install]" >&2
  exit 64
fi

mkdir -p "$OUT_DIR"

if [[ "$INSTALL_FIRST" == "1" ]]; then
  "$ROOT/scripts/package_app.sh" >/dev/null
  "$ROOT/scripts/install_app.sh" >/dev/null
fi

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Missing installed app binary at $APP_BINARY" >&2
  echo "Run: $ROOT/scripts/visual_acceptance.sh --install" >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.2

OPEN_PID=""

cleanup() {
  local status=$?
  trap - EXIT
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  # open -W exits only after its demo application has finished terminating.
  if [[ -n "$OPEN_PID" ]]; then wait "$OPEN_PID" >/dev/null 2>&1 || true; fi
  /usr/bin/open -n -g "$APP_DIR" || true
  if ! wait_for_installed_app; then
    echo "Could not restore the normal installed app after visual acceptance failed." >&2
    if [[ "$status" == 0 ]]; then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT

wait_for_installed_app() {
  local attempt
  for attempt in {1..50}; do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

capture_state() {
  local state="$1"
  local output_file="$2"
  local log_file="$OUT_DIR/chattype-overlay-demo-$state.log"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  CHATTYPE_OVERLAY_DEMO=1 open -W -n -g \
    --stdout "$log_file" \
    --stderr "$log_file" \
    "$APP_DIR" \
    --args --overlay-demo-state "$state" &
  OPEN_PID=$!

  local window_id
  window_id="$(swift "$ROOT/scripts/find_visual_acceptance_window.swift" "$APP_NAME" 5)"
  screencapture -x -l "$window_id" "$OUT_DIR/$output_file"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  wait "$OPEN_PID" >/dev/null 2>&1 || true
  OPEN_PID=""
}

capture_state "recording" "01-recording.png"
capture_state "processing" "02-processing.png"
capture_state "result" "03-result.png"
capture_state "error" "04-error.png"
capture_state "retryable-error" "05-retryable-error.png"

swift "$ROOT/scripts/verify_visual_acceptance.swift" \
  "$OUT_DIR/01-recording.png" \
  "$OUT_DIR/02-processing.png" \
  "$OUT_DIR/03-result.png" \
  "$OUT_DIR/04-error.png" \
  "$OUT_DIR/05-retryable-error.png" | tee "$OUT_DIR/verification.txt"

/usr/bin/open "$APP_DIR"
if ! wait_for_installed_app; then
  echo "Installed app did not remain running after launch: $APP_DIR" >&2
  exit 1
fi

RUNNING_PID="$(pgrep -x "$APP_NAME" | sed -n '1p')"
trap - EXIT

cat >"$OUT_DIR/summary.md" <<SUMMARY
# ChatType Visual Acceptance

- Run ID: \`$RUN_ID\`
- App: \`$APP_BINARY\`
- Demo flag: \`CHATTYPE_OVERLAY_DEMO=1\`
- Capture: CoreGraphics window discovery plus \`screencapture -l\`
- Final live state: normal installed app relaunched and left running as PID \`$RUNNING_PID\`
- Evidence:
  - \`01-recording.png\`
  - \`02-processing.png\`
  - \`03-result.png\`
  - \`04-error.png\`
  - \`05-retryable-error.png\`
  - \`verification.txt\`
  - \`chattype-overlay-demo-*.log\`

SUMMARY

echo "Visual acceptance artifacts: $OUT_DIR"
echo "Installed app left running: $APP_DIR (PID $RUNNING_PID)"
