#!/usr/bin/env bash
# Download sherpa-onnx prebuilt libs (into vendor/), then the model and Silero VAD (fetch-models.sh).
#
#   scripts/fetch-deps.sh               libs + models
#   scripts/fetch-deps.sh --libs-only   libs only (CI: enough to build and test)
set -euo pipefail

SHERPA_VERSION="2.0.0"
LIB_NAME="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared-no-tts-lib"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/sherpa-onnx"

mkdir -p "$VENDOR"

if [ ! -f "$VENDOR/lib/libsherpa-onnx-c-api.dylib" ]; then
  echo "==> downloading $LIB_NAME"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar -o "$tmp/lib.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${LIB_NAME}.tar.bz2"
  tar -xjf "$tmp/lib.tar.bz2" -C "$tmp"
  rm -rf "${VENDOR:?}"/*
  cp -R "$tmp/$LIB_NAME"/* "$VENDOR"/
  rm -rf "$tmp"
fi

# the -lib tarball ships dylibs only; take the C header from the matching tag
if [ ! -f "$VENDOR/include/sherpa-onnx/c-api/c-api.h" ]; then
  mkdir -p "$VENDOR/include/sherpa-onnx/c-api"
  curl -fsSL -o "$VENDOR/include/sherpa-onnx/c-api/c-api.h" \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${SHERPA_VERSION}/sherpa-onnx/c-api/c-api.h"
fi

for f in "$VENDOR/lib/libsherpa-onnx-c-api.dylib" "$VENDOR/lib/libonnxruntime.dylib" \
         "$VENDOR/include/sherpa-onnx/c-api/c-api.h"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
echo "==> libs ok: $VENDOR"

[ "${1:-}" = "--libs-only" ] || "$ROOT/scripts/fetch-models.sh"
