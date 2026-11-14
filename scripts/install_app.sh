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

echo "Installed $TARGET_APP"
