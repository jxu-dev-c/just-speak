#!/usr/bin/env bash
# Download sherpa-onnx prebuilt libs (into vendor/), the Fun-ASR-Nano int8 model and Silero VAD.
set -euo pipefail

SHERPA_VERSION="2.0.0"
LIB_NAME="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared-no-tts-lib"
MODEL_NAME="sherpa-onnx-funasr-nano-int8-2025-12-30"
MMAP_NAME="funasr-nano-int8-mmap"   # what config.json's asr.modelDir points at

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/sherpa-onnx"
MODELS="$HOME/Library/Application Support/just-speak/models"

mkdir -p "$VENDOR" "$MODELS"

if [ ! -f "$VENDOR/lib/libsherpa-onnx-c-api.dylib" ]; then
  echo "==> downloading $LIB_NAME"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar -o "$tmp/lib.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${LIB_NAME}.tar.bz2"
  tar -xjf "$tmp/lib.tar.bz2" -C "$tmp"
  rm -rf "$VENDOR"/*
  cp -R "$tmp/$LIB_NAME"/* "$VENDOR"/
  rm -rf "$tmp"
fi

# the -lib tarball ships dylibs only; take the C header from the matching tag
if [ ! -f "$VENDOR/include/sherpa-onnx/c-api/c-api.h" ]; then
  mkdir -p "$VENDOR/include/sherpa-onnx/c-api"
  curl -fsSL -o "$VENDOR/include/sherpa-onnx/c-api/c-api.h" \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${SHERPA_VERSION}/sherpa-onnx/c-api/c-api.h"
fi

if [ ! -f "$MODELS/$MMAP_NAME/llm.int8.data" ]; then
  if [ ! -f "$MODELS/$MODEL_NAME/llm.int8.onnx" ]; then
    echo "==> downloading $MODEL_NAME (~950 MB)"
    tmp="$(mktemp -d)"
    curl -fL --progress-bar -o "$tmp/model.tar.bz2" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
    tar -xjf "$tmp/model.tar.bz2" -C "$MODELS"
    rm -rf "$tmp"
  fi

  # one-off conversion so onnxruntime mmaps the weights (see scripts/externalize_onnx.py)
  echo "==> converting model weights to mmap-able external data"
  if command -v uv >/dev/null; then
    uv run --quiet --no-project --with onnx python "$ROOT/scripts/externalize_onnx.py" \
      "$MODELS/$MODEL_NAME" "$MODELS/$MMAP_NAME"
  else
    venv="$(mktemp -d)/venv"
    python3 -m venv "$venv" && "$venv/bin/pip" install -q onnx
    "$venv/bin/python" "$ROOT/scripts/externalize_onnx.py" "$MODELS/$MODEL_NAME" "$MODELS/$MMAP_NAME"
    rm -rf "$(dirname "$venv")"
  fi
  rm -rf "${MODELS:?}/$MODEL_NAME"
fi

# Silero VAD (~2 MB): splits long dictation at pauses so each chunk fits Fun-ASR-Nano's 512-token context
if [ ! -f "$MODELS/silero_vad.onnx" ]; then
  echo "==> downloading silero_vad.onnx"
  curl -fsSL -o "$MODELS/silero_vad.onnx.partial" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
  mv "$MODELS/silero_vad.onnx.partial" "$MODELS/silero_vad.onnx"
fi

for f in "$MODELS/silero_vad.onnx" "$VENDOR/lib/libsherpa-onnx-c-api.dylib" "$VENDOR/include/sherpa-onnx/c-api/c-api.h" \
         "$MODELS/$MMAP_NAME/llm.int8.data" "$MODELS/$MMAP_NAME/encoder_adaptor.int8.data" \
         "$MODELS/$MMAP_NAME/embedding.int8.data" "$MODELS/$MMAP_NAME/Qwen3-0.6B/tokenizer.json"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
echo "==> deps ok"
echo "    libs:  $VENDOR"
echo "    model: $MODELS/$MMAP_NAME"
