#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSCRIBER="$ROOT/Sources/ChatType/ChatGPTTranscriber.swift"
BENCHMARK="$ROOT/scripts/benchmark_stt.sh"
STATUS_MENU="$ROOT/Sources/ChatType/StatusMenuController.swift"

if rg -q 'api\.openai\.com' "$TRANSCRIBER"; then
  echo "Managed ChatGPT transcriber must not contain a metered OpenAI Platform endpoint." >&2
  exit 1
fi

if ! rg -q 'ChatGPT-Account-ID' "$TRANSCRIBER"; then
  echo "Managed ChatGPT requests must preserve the OAuth account context header." >&2
  exit 1
fi

if rg -n 'import Speech|OnDeviceSpeech|SystemOnDevice|requiresOnDeviceRecognition' "$ROOT/Sources/ChatType"; then
  echo "ChatType source must not add a third on-device Speech transcription route." >&2
  exit 1
fi

if rg -n 'ChatGPTStoredCookie|HTTPCookie' "$ROOT/Sources/ChatType"; then
  echo "ChatType device authorization must not retain browser Cookie session code." >&2
  exit 1
fi

if rg -q 'NSSpeechRecognitionUsageDescription' "$ROOT/scripts/package_app.sh"; then
  echo "ChatType package must not declare Speech Recognition without an approved Speech provider." >&2
  exit 1
fi

if rg -q 'APP_BIN=' "$BENCHMARK"; then
  echo "Benchmark must launch the installed app through LaunchServices, not a raw bundle executable." >&2
  exit 1
fi

if ! rg -q '/usr/bin/open -n -W' "$BENCHMARK"; then
  echo "Benchmark is missing its LaunchServices launch contract." >&2
  exit 1
fi

if rg -q 'connectionProxyDictionary|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|SOCKS_PROXY' "$ROOT/Sources/ChatType"; then
  echo "ChatType source must not add application-level proxy configuration." >&2
  exit 1
fi

if rg -q 'button\.title\s*=\s*"CT"' "$STATUS_MENU"; then
  echo "The approved dynamic menu-bar icon must not be replaced by a text label." >&2
  exit 1
fi

if ! rg -q 'ChatTypeStatusIconRenderer\.image\(for: state\)' "$STATUS_MENU"; then
  echo "The approved ChatType menu-bar icon renderer is no longer connected to status presentation." >&2
  exit 1
fi

echo "Operational policy checks passed."
