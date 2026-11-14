#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:?usage: build_omni_runtime.sh SOURCE_CHECKOUT [OUTPUT_DIRECTORY]}"
OUTPUT="${2:-$HOME/Library/Caches/chat-type/voxt-evaluation/runtime}"
WORK="${CHATTYPE_OMNI_BUILD_PATH:-$HOME/Library/Caches/chat-type/voxt-evaluation/build}"
REVISION="4e03928295bba17c8196644f50d69e58facff6ea"
NATIVE="$SOURCE/sglang_omni_mlx/native"
PATCH="$(cd "$(dirname "$0")" && pwd)/omni-session-auth.patch"
[[ "$(uname -m)" == arm64 ]] || { echo "Omni requires Apple Silicon" >&2; exit 1; }
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$REVISION" ]] || { echo "Unexpected Omni source revision" >&2; exit 1; }
if git -C "$SOURCE" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "$PATCH"
elif ! git -C "$SOURCE" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "Omni authentication patch does not match the source" >&2
  exit 1
fi
mkdir -p "$WORK" "$OUTPUT/bin"
export UV_CACHE_DIR="$WORK/uv-cache"
export UV_PYTHON_INSTALL_DIR="$WORK/python"
export MACOSX_DEPLOYMENT_TARGET=15.0
uv venv --python 3.12 --allow-existing "$WORK/venv"
uv pip install --python "$WORK/venv/bin/python" --python-platform aarch64-apple-darwin -r "$NATIVE/scripts/build-tools.lock"
MLX_CONFIG_DIR="$("$WORK/venv/bin/python" -c 'from importlib.metadata import distribution; print(distribution("mlx").locate_file("mlx/share/cmake/MLX"))')"
export PATH="$WORK/venv/bin:$PATH"
cmake -S "$NATIVE" -B "$WORK/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DMLX_DIR="$MLX_CONFIG_DIR" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$WORK/cmake" --target qwen3_asr_server qwen3_asr_transcribe
cp "$WORK/cmake/qwen3_asr_server" "$WORK/cmake/qwen3_asr_transcribe" "$OUTPUT/bin/"
"$WORK/venv/bin/python" - "$MLX_CONFIG_DIR" "$OUTPUT/bin" <<'PY'
import pathlib, shutil, sys
library_root = pathlib.Path(sys.argv[1]).parents[2] / "lib"
destination = pathlib.Path(sys.argv[2])
for pattern in ("*.dylib", "mlx.metallib"):
    for source in library_root.glob(pattern):
        shutil.copy2(source.resolve(), destination / source.name)
PY
for binary in "$OUTPUT/bin/"*.dylib "$OUTPUT/bin/qwen3_asr_server" "$OUTPUT/bin/qwen3_asr_transcribe"; do
  codesign --force --sign - "$binary"
done
printf '%s\n' "$REVISION" > "$OUTPUT/source-revision.txt"
echo "Omni runtime ready: $OUTPUT/bin/qwen3_asr_server"
