#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="/Applications/ChatType.app"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <audio-file-1> [audio-file-2 ...]"
  echo "Example: $0 ~/bench/3s.wav ~/bench/10s.wav ~/bench/30s.wav"
  exit 1
fi

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/ChatType" ]]; then
  "$ROOT_DIR/scripts/package_app.sh" >/dev/null
  "$ROOT_DIR/scripts/install_app.sh" >/dev/null
fi

audio_csv=""
for path in "$@"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing audio file: $path" >&2
    exit 1
  fi
  if [[ -n "$audio_csv" ]]; then
    audio_csv+=","
  fi
  audio_csv+="$(python3 - <<'PY' "$path"
import os, sys
print(os.path.abspath(sys.argv[1]), end="")
PY
)"
done

output_directory="$(mktemp -d /tmp/ChatTypeBenchmark.XXXXXX)"
stdout_file="$output_directory/stdout.log"
stderr_file="$output_directory/stderr.log"

/usr/bin/open -n -W \
  -o "$stdout_file" \
  --stderr "$stderr_file" \
  --env CHATTYPE_BENCHMARK=1 \
  --env "CHATTYPE_BENCHMARK_AUDIO_FILES=$audio_csv" \
  --env "CHATTYPE_BENCHMARK_RUNS=${CHATTYPE_BENCHMARK_RUNS:-5}" \
  "$APP_BUNDLE"

if [[ -s "$stdout_file" ]]; then
  sed -n '1,400p' "$stdout_file"
fi
if [[ -s "$stderr_file" ]]; then
  sed -n '1,400p' "$stderr_file" >&2
fi
