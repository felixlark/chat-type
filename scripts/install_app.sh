#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${CHATTYPE_DIST_PATH:-$ROOT/dist}"
SOURCE_APP="$DIST_ROOT/ChatType.app"
TARGET_APP="/Applications/ChatType.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$ROOT/scripts/package_app.sh" >/dev/null
fi

# The optional user-owned pin lives outside the replaceable app bundle.
python3 "$ROOT/scripts/preserve_local_keyboard.py"
pkill -x ChatType >/dev/null 2>&1 || true
rm -rf "$TARGET_APP"
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/xattr -cr "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"

# Supported Sublime package, outside the vendor-signed app bundle.
if [[ -d "/Applications/Sublime Text.app" ]]; then
  EDITOR_PACKAGE="$HOME/Library/Application Support/Sublime Text/Packages/ChatType"
  mkdir -p "$EDITOR_PACKAGE"
  cp "$TARGET_APP/Contents/Resources/Sublime/ChatType.py" "$EDITOR_PACKAGE/ChatType.py"
fi

echo "Installed $TARGET_APP"
