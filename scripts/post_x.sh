#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/post_x.sh [--print] "post text"
  echo "post text" | scripts/post_x.sh [--print]

Options:
  --print         Print the approved xurl-ops workflow without sending the post.
  -h, --help      Show this help message.

Notes:
  - Reads post text from the first positional argument or stdin.
  - Live posting uses longbiao-x-post-workflow / xurl-ops after explicit publish authorization.
  - This CLI only prints the approved workflow and does not publish by itself.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

print_only=0
text=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      print_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      text="$1"
      shift
      if [[ $# -gt 0 ]]; then
        echo "unexpected extra arguments" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$text" && $# -gt 0 ]]; then
  text="$1"
fi

if [[ -z "$text" && ! -t 0 ]]; then
  text="$(cat)"
fi

if [[ -z "$text" ]]; then
  echo "missing post text" >&2
  usage >&2
  exit 1
fi

if [[ "$print_only" -eq 1 ]]; then
  cat <<EOF
Resolved workflow:
  transport: longbiao-x-post-workflow / xurl-ops
  preflight: xurl-ops status (must resolve to felixlark)
  publish: xurl-ops post "POST_TEXT"
  post_text: $text
  verification: read back the created post and confirm a fresh /status/ URL containing the post text
EOF
  exit 0
fi

cat >&2 <<'EOF'
Live X posting from scripts/post_x.sh is disabled.
Use longbiao-x-post-workflow / xurl-ops with explicit publish authorization; it must preflight identity and read the created post back.
EOF
exit 2
