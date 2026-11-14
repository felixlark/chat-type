#!/usr/bin/env bash
set -euo pipefail

# Fixed upstream Xiph release, also independently pinned by Homebrew's opus formula.
VERSION=1.6.1
SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
CACHE="$HOME/Library/Caches/chat-type/opus-$VERSION-$(uname -m)"
PREFIX="$CACHE/install"
if [[ ! -f "$PREFIX/lib/libopus.0.dylib" ]]; then
  mkdir -p "$CACHE"
  chmod 700 "$CACHE"
  ARCHIVE="$CACHE/opus-$VERSION.tar.gz"
  if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location "https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz" -o "$ARCHIVE.part"
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check --status
  tar -xzf "$ARCHIVE" -C "$CACHE"
  (
    cd "$CACHE/opus-$VERSION"
    MACOSX_DEPLOYMENT_TARGET=13.0 ./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-doc --disable-extra-programs
    make -j2
    make install
  ) > "$CACHE/build.log" 2>&1
fi
mkdir -p "$PREFIX/share/licenses/opus"
cp "$CACHE/opus-$VERSION/COPYING" "$PREFIX/share/licenses/opus/COPYING"
printf '%s\n' "$PREFIX"
