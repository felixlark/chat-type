#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${CHATTYPE_DIST_PATH:-$ROOT/dist}"
APP="$DIST_ROOT/ChatType.app"
PLIST="$APP/Contents/Info.plist"

EXISTING=0
IDENTITY_PROFILE="${CHATTYPE_IDENTITY_PROFILE:-}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --existing) EXISTING=1; shift ;;
    --identity-profile) [[ "$#" -ge 2 ]] || exit 64; IDENTITY_PROFILE="$2"; shift 2 ;;
    *) echo "Usage: $0 [--existing] [--identity-profile /absolute/profile.json]" >&2; exit 64 ;;
  esac
done
IDENTITY_ARGS=()
if [[ -n "$IDENTITY_PROFILE" ]]; then IDENTITY_ARGS=(--profile "$IDENTITY_PROFILE"); fi
if [[ "$EXISTING" == 0 ]]; then
  CHATTYPE_IDENTITY_PROFILE="$IDENTITY_PROFILE" "$ROOT/scripts/package_app.sh" >/dev/null
fi
if [[ ! -f "$PLIST" ]]; then
  echo "Missing packaged app at $APP" >&2
  exit 1
fi

# --existing must inspect the candidate selected by this checkout, not an older package.
source "$ROOT/version.env"
for field in CFBundleShortVersionString CFBundleVersion; do
  actual="$(/usr/bin/plutil -extract "$field" raw -o - "$PLIST")"
  if [[ "$field" == CFBundleVersion ]]; then expected="$CHATTYPE_BUILD"; else expected="$CHATTYPE_VERSION"; fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Packaged $field=$actual does not match version.env ($expected)." >&2
    exit 1
  fi
done
/usr/bin/codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/build_identity.py" check "${IDENTITY_ARGS[@]}" --plist "$PLIST"
if [[ -e "$APP/Contents/Resources/Omni" ]]; then
  echo "Research-only Omni model metadata must stay outside the production app bundle." >&2
  exit 1
fi

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

if [[ "$ENTITLEMENTS" != *"com.apple.security.personal-information.addressbook"* ]]; then
  echo "Packaged app is missing hardened runtime Contacts entitlement." >&2
  exit 1
fi

for sound in recording-start.wav recording-stop.wav; do
  if [[ ! -f "$APP/Contents/Resources/Sounds/$sound" ]]; then
    echo "Packaged app is missing feedback sound resource: $sound" >&2
    exit 1
  fi
done

echo "Packaged app metadata looks correct."
