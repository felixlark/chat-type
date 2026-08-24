#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/ChatType.app"
PLIST="$APP/Contents/Info.plist"
CONFIG="$HOME/Library/Application Support/ChatType/config.json"

section() {
  printf '\n[%s]\n' "$1"
}

section "repository"
git -C "$ROOT" status --short --branch 2>/dev/null || echo "repository unavailable"

section "installed-app"
if [[ -x "$APP/Contents/MacOS/ChatType" ]]; then
  echo "path=$APP"
  printf 'bundle_id='
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST" 2>/dev/null || echo "missing"
  printf 'lsui_element='
  /usr/bin/plutil -extract LSUIElement raw -o - "$PLIST" 2>/dev/null || echo "missing"
  if /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    echo "signature=valid"
  else
    echo "signature=invalid"
  fi
else
  echo "path=missing"
fi

section "runtime"
runtime_lines="$(pgrep -fl "$APP/Contents/MacOS/ChatType" 2>/dev/null || true)"
if [[ -n "$runtime_lines" ]]; then
  printf '%s\n' "$runtime_lines"
else
  echo "process=not-running"
fi

section "safe-config"
if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  jq -r '[
    "provider=" + (.transcription.provider // "missing"),
    "chatgpt_host=" + ((.transcription.chatGPTURL // "missing") | try capture("https?://(?<host>[^/]+)").host catch "invalid"),
    "polish_host=" + ((.transcription.textPolish.chatGPTResponseURL // "missing") | try capture("https?://(?<host>[^/]+)").host catch "invalid"),
    "polish_model=" + (.transcription.textPolish.chatGPTResponseModel // "missing")
  ] | .[]' "$CONFIG" 2>/dev/null || echo "config=unreadable"
else
  echo "config=missing-or-jq-unavailable"
fi

section "keychain-metadata"
if /usr/bin/security find-generic-password -s me.longbiaochen.ChatType.ChatGPTSession >/dev/null 2>&1; then
  echo "chatgpt_session_entry=present"
else
  echo "chatgpt_session_entry=missing-or-inaccessible"
fi
echo "secret_read=not-attempted"

section "recent-http-status"
/usr/bin/log show --last 15m --style compact \
  --predicate 'process == "ChatType" AND eventMessage CONTAINS "received response, status"' \
  2>/dev/null | tail -20

section "latest-crash"
latest_crash="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -name 'ChatType-*.ips' -print 2>/dev/null | sort | tail -1)"
if [[ -n "$latest_crash" ]]; then
  echo "$latest_crash"
else
  echo "none"
fi
