#!/usr/bin/env bash
# Downloads the sherpa-onnx iOS frameworks and the ASR/TTS models into vendor/.
# Everything in vendor/ is gitignored; run this once after cloning.
set -euo pipefail

SHERPA_VERSION="1.12.21"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
MODELS="$VENDOR/models"

mkdir -p "$VENDOR" "$MODELS"
cd "$VENDOR"

echo "==> Prebuilt sherpa-onnx iOS frameworks (v$SHERPA_VERSION)"
if [ ! -d build-ios ]; then
  curl -L -o sherpa-onnx-ios.tar.bz2 \
    "https://huggingface.co/csukuangfj/sherpa-onnx-libs/resolve/main/sherpa-onnx-v$SHERPA_VERSION-ios.tar.bz2"
  tar xjf sherpa-onnx-ios.tar.bz2
  rm sherpa-onnx-ios.tar.bz2
fi

echo "==> Streaming Zipformer ASR model (English, 20M, int8)"
if [ ! -d "$MODELS/asr-zipformer-en-20M" ]; then
  curl -L -o asr.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17-mobile.tar.bz2"
  tar xjf asr.tar.bz2
  SRC="sherpa-onnx-streaming-zipformer-en-20M-2023-02-17-mobile"
  mkdir -p "$MODELS/asr-zipformer-en-20M" "$MODELS/demo-voice"
  cp "$SRC/encoder-epoch-99-avg-1.int8.onnx" \
     "$SRC/decoder-epoch-99-avg-1.onnx" \
     "$SRC/joiner-epoch-99-avg-1.int8.onnx" \
     "$SRC/tokens.txt" \
     "$MODELS/asr-zipformer-en-20M/"
  # Built-in demo reference voice (LibriSpeech) so TTS works before enrollment.
  cp "$SRC/test_wavs/0.wav" "$MODELS/demo-voice/demo.wav"
  printf "After early nightfall the yellow lamps would light up here and there the squalid quarter of the brothels." \
    > "$MODELS/demo-voice/demo.txt"
  rm -rf "$SRC" asr.tar.bz2
fi

echo "==> ZipVoice-Distill TTS model (int8) + vocos vocoder"
if [ ! -d "$MODELS/zipvoice" ]; then
  curl -L -o zipvoice.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2"
  tar xjf zipvoice.tar.bz2
  SRC="sherpa-onnx-zipvoice-distill-int8-zh-en-emilia"
  mkdir -p "$MODELS/zipvoice"
  cp -R "$SRC/encoder.int8.onnx" "$SRC/decoder.int8.onnx" \
        "$SRC/tokens.txt" "$SRC/lexicon.txt" "$SRC/espeak-ng-data" \
        "$MODELS/zipvoice/"
  rm -rf "$SRC" zipvoice.tar.bz2
  curl -L -o "$MODELS/zipvoice/vocos_24khz.onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx"
fi

echo "==> Done. Now run: xcodegen generate"
