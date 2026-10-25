# Third-party notices

just-speak's own source code is MIT licensed (see [LICENSE](LICENSE)). It does not vendor any
third-party code or models in this repository: `scripts/fetch-deps.sh` downloads them, and
`scripts/build-app.sh` copies the two runtime libraries into `JustSpeak.app/Contents/Frameworks`.
If you redistribute a built `JustSpeak.app`, include this file (the build script copies it into
`Contents/Resources`) and the upstream license texts linked below.

| Component | Used for | How it is obtained | License |
|---|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v2.0.0 (`libsherpa-onnx-c-api.dylib`, `c-api.h`) | ASR and VAD runtime | downloaded; dylib bundled in the app | [Apache-2.0](https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE) |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.28 (`libonnxruntime.dylib`, shipped with sherpa-onnx) | model inference | downloaded; dylib bundled in the app | [MIT](https://github.com/microsoft/onnxruntime/blob/main/LICENSE) |
| [Fun-ASR-Nano-2512](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512) (FunAudioLLM), int8 ONNX export by sherpa-onnx | speech recognition model | downloaded to `~/Library/Application Support/just-speak/models`, re-saved with external weights by `scripts/externalize_onnx.py` | [Apache-2.0](https://github.com/FunAudioLLM/Fun-ASR/blob/main/LICENSE) |
| [Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B) tokenizer files (part of the Fun-ASR-Nano package) | text tokenizer | downloaded with the model | [Apache-2.0](https://huggingface.co/Qwen/Qwen3-0.6B) |
| [Silero VAD](https://github.com/snakers4/silero-vad) (`silero_vad.onnx`) | splitting long dictation at pauses | downloaded | [MIT](https://github.com/snakers4/silero-vad/blob/master/LICENSE) |
| [onnx](https://github.com/onnx/onnx) (Python package) | one-off model conversion at install time; not shipped | installed temporarily by `fetch-deps.sh` | [Apache-2.0](https://github.com/onnx/onnx/blob/main/LICENSE) |

## Services

The optional rewrite step calls the [Inception](https://www.inceptionlabs.ai) chat completions API
(Mercury 3) with your own API key; its use is governed by Inception's terms of service. just-speak
is not affiliated with Inception, FunAudioLLM, Alibaba, Xiaomi/k2-fsa, Microsoft or Silero.
