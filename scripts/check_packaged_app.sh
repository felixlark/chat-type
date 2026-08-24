#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/ChatType.app"
PLIST="$APP/Contents/Info.plist"

"$ROOT/scripts/package_app.sh" >/dev/null

LSUI_ELEMENT="$(/usr/bin/plutil -extract LSUIElement raw -o - "$PLIST" 2>/dev/null || true)"
if [[ "$LSUI_ELEMENT" != "true" ]]; then
  echo "Packaged app must declare LSUIElement=true so normal launch has no Dock icon." >&2
  exit 1
fi

CONTACTS_DESCRIPTION="$(/usr/bin/plutil -extract NSContactsUsageDescription raw -o - "$PLIST" 2>/dev/null || true)"
if [[ -z "$CONTACTS_DESCRIPTION" ]]; then
  echo "Packaged app is missing NSContactsUsageDescription for contact nickname import." >&2
  exit 1
fi

if /usr/bin/plutil -extract NSSpeechRecognitionUsageDescription raw -o - "$PLIST" >/dev/null 2>&1; then
  echo "Packaged app must not declare Speech Recognition; the product design has no Speech provider." >&2
  exit 1
fi

ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
if [[ "$ENTITLEMENTS" != *"com.apple.security.device.audio-input"* ]]; then
  echo "Packaged app is missing hardened runtime audio input entitlement." >&2
  exit 1
fi

for sound in recording-start.wav recording-stop.wav; do
  if [[ ! -f "$APP/Contents/Resources/Sounds/$sound" ]]; then
    echo "Packaged app is missing feedback sound resource: $sound" >&2
    exit 1
  fi
done

echo "Packaged app metadata looks correct."
