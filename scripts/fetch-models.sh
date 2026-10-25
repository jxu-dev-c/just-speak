#!/usr/bin/env bash
# Download the Fun-ASR-Nano int8 model (converted for mmap) and Silero VAD into Application Support.
# Ships inside JustSpeak.app as `just-speak setup`; also run by fetch-deps.sh for source builds.
set -euo pipefail

MODEL_NAME="sherpa-onnx-funasr-nano-int8-2025-12-30"
MMAP_NAME="funasr-nano-int8-mmap"   # what config.json's asr.modelDir points at

HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS="$HOME/Library/Application Support/just-speak/models"

mkdir -p "$MODELS"

if [ ! -f "$MODELS/$MMAP_NAME/llm.int8.data" ]; then
  if [ ! -f "$MODELS/$MODEL_NAME/llm.int8.onnx" ]; then
    echo "==> downloading $MODEL_NAME (~950 MB)"
    tmp="$(mktemp -d)"
    curl -fL --progress-bar -o "$tmp/model.tar.bz2" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
    tar -xjf "$tmp/model.tar.bz2" -C "$MODELS"
    rm -rf "$tmp"
  fi

  # one-off conversion so onnxruntime mmaps the weights (see externalize_onnx.py)
  echo "==> converting model weights to mmap-able external data"
  if command -v uv >/dev/null; then
    uv run --quiet --no-project --with onnx python "$HERE/externalize_onnx.py" \
      "$MODELS/$MODEL_NAME" "$MODELS/$MMAP_NAME"
  else
    venv="$(mktemp -d)/venv"
    python3 -m venv "$venv" && "$venv/bin/pip" install -q onnx
    "$venv/bin/python" "$HERE/externalize_onnx.py" "$MODELS/$MODEL_NAME" "$MODELS/$MMAP_NAME"
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

for f in "$MODELS/silero_vad.onnx" \
         "$MODELS/$MMAP_NAME/llm.int8.data" "$MODELS/$MMAP_NAME/encoder_adaptor.int8.data" \
         "$MODELS/$MMAP_NAME/embedding.int8.data" "$MODELS/$MMAP_NAME/Qwen3-0.6B/tokenizer.json"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
echo "==> models ok: $MODELS/$MMAP_NAME"
