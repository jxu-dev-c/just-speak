<img src="Resources/icon.png" width="128" alt="just-speak icon">

# just-speak

Hold a key, speak, let go — your words appear, cleaned up, wherever the cursor is.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/orb-dark.png">
  <img src="docs/orb-light.png" width="520" alt="The floating just-speak orb: dark glass with a band of light across the middle and an iridescent rim">
</picture>

- **On-device ASR**: [Fun-ASR-Nano](https://github.com/FunAudioLLM/Fun-ASR) (int8) via sherpa-onnx, decoded at
  your pauses so little is left at release. Audio never leaves your Mac (~1 GB while loaded).
  Switch `asr.provider` to `openai` to stream to OpenAI
  [`gpt-live-transcribe`](https://developers.openai.com/api/docs/models/gpt-live-transcribe) instead (~15 MB,
  but ~0.6–0.8 s at release vs. ~0.2–0.5 s locally for a typical dictation), or to `hybrid` to run both and
  use whichever is faster for each dictation.
- **Rewrite**: Inception Mercury 3 (`reasoning_effort: instant`) removes fillers, false starts and fixes
  punctuation without translating or answering what you said. Falls back to the raw transcript on any error.
- **Clipboard untouched**: text is typed as synthetic Unicode keystrokes.
- **Local history**: plain JSONL per month, readable with `jq`/`grep` or `just-speak history`.
- **JSON config** with hot reload.

## Install

```sh
brew install --cask jxu-dev-c/tap/just-speak
just-speak setup                 # speech model → ~/Library/Application Support/just-speak/models (~1 GB, once)
mkdir -p ~/.config/just-speak    # API key for the rewrite step; see "API keys" below
echo 'INCEPTION_API_KEY=...' > ~/.config/just-speak/.env && chmod 600 ~/.config/just-speak/.env
open -a JustSpeak
```

Not an admin? `/Applications` needs admin rights, so install into your own Applications folder instead
with `brew install --cask --appdir=~/Applications jxu-dev-c/tap/just-speak`, or set
`export HOMEBREW_CASK_OPTS="--appdir=$HOME/Applications"` in your shell profile so upgrades go there too.

There's no Apple Developer account behind this project, so releases are signed with a self-signed
identity and not notarized. The cask clears the quarantine flag so Gatekeeper lets it open. If you
download the zip from GitHub Releases yourself, run
`xattr -dr com.apple.quarantine JustSpeak.app` (or use System Settings → Privacy & Security → Open Anyway).

Grant the two permissions it asks for (System Settings → Privacy & Security):
**Microphone** and **Accessibility** (the hotkey and typing into other apps). macOS shows each
prompt only once; afterwards the menu's "Grant permissions…" opens the right Settings pane.
Releases and `build-app.sh` sign with the same self-signed identity, so these grants survive upgrades and rebuilds.

### API keys

- **OpenAI** (`OPENAI_API_KEY`), only with `asr.provider: "openai"` or `"hybrid"`: create one at
  [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
- **Inception** (`INCEPTION_API_KEY`), for the rewrite step: sign up at [Inception](https://www.inceptionlabs.ai)
  and create one in their dashboard. Without a key, dictation still works: you get the raw transcript, and the menu bar
  shows ⚠︎ "rewrite failed" (set `rewrite.enabled` to `false` to turn the rewrite step off instead).

```sh
mkdir -p ~/.config/just-speak
printf 'OPENAI_API_KEY=sk-...\nINCEPTION_API_KEY=...\n' > ~/.config/just-speak/.env
chmod 600 ~/.config/just-speak/.env
just-speak rewrite "um so like hello"   # check: prints the cleaned-up text
```

Each key is looked up in this order: `asr.openai.apiKey` / `rewrite.apiKey` in `config.json`, then the
environment variable, then `~/.config/just-speak/.env`. Use the `.env` file for the app, since an app opened from
Finder or `open` doesn't see variables exported in your shell profile. Keys are read at launch,
so quit and reopen JustSpeak after changing them.

### OpenAI transcription (optional)

To stream audio to OpenAI instead of transcribing on-device, add `OPENAI_API_KEY` to the `.env` file and set
`"asr": {"provider": "openai"}` in `config.json`. The app then stays at ~15 MB and never loads the local model,
but each dictation waits ~0.6–0.8 s at release for OpenAI's final transcript (see "Numbers" below).

### Hybrid (optional)

`"asr": {"provider": "hybrid"}` decodes locally as usual and also streams the audio to OpenAI, without
committing it. At release it checks how much audio is still left to decode locally. With up to
`asr.hybrid.localMaxMs` (6 s) left and the model loaded, it uses the local result alone and never requests
OpenAI's transcript. With more left (a long stretch of speech without a pause), or while the model is still
loading after being idle, it commits OpenAI as well and takes whichever transcript arrives first. It needs both
the local model and an OpenAI key (without a key it is just local), and keeps the model loaded (~1 GB).

### Build from source

```sh
scripts/fetch-deps.sh            # sherpa-onnx dylibs → vendor/, model → ~/Library/Application Support/just-speak/models
scripts/build-app.sh --install   # build, sign, copy to /Applications, link /usr/local/bin/just-speak
```

## Privacy

With `asr.provider: "local"` (the default), audio never leaves your Mac. With `"openai"` or `"hybrid"`, the
**audio** of each dictation is streamed to OpenAI's API while you hold the key; a recording with no speech in it is
never committed, and in hybrid mode only dictations that race OpenAI are.
When `rewrite.enabled` is on (the default), the **transcript text** is sent to Inception's
API for cleanup. Set `rewrite.enabled` to `false` to stay fully offline. History stays on disk in
`~/Library/Application Support/just-speak/history/` as plain JSON (owner-only permissions), and
the log records only timings and sizes, never what you said.

## Requirements

- macOS 14+ on Apple Silicon (prebuilt sherpa-onnx libraries are arm64)
- Xcode or the Swift 6 toolchain (building from source only)
- ~1.1 GB disk for the speech model, and `uv` or `python3` for its one-off conversion (`just-speak setup`)
- An [Inception](https://www.inceptionlabs.ai) API key for the rewrite step; an OpenAI API key only with `asr.provider: "openai"` or `"hybrid"`

## Numbers (M5)

Local (Fun-ASR-Nano, 4 threads):

| | |
|---|---|
| Idle (model unloaded) | ~15 MB, 0% CPU |
| Model loaded | ~0.9–1.3 GB, loads in ~1.2 s (overlapped with your speech) |
| ASR | ~0.07× real time — 10 s of speech ≈ 0.75 s |
| Rewrite | ~0.3–0.5 s |
| Long dictation | transcribed in pieces at your pauses while you keep talking; only the speech since your last pause is left at release, and none if you paused before letting go |

The model is converted at install time so onnxruntime memory-maps its weights
(`scripts/externalize_onnx.py`): 2.2 GB → 0.9 GB loaded, same speed and output.
The CoreML execution provider was measured ~10× slower for this model and is not used.

Fun-ASR-Nano's sherpa-onnx export has a 512-token context (prompt + ~17 audio tokens/s + output), so
a single pass truncates past ~20 s. Silero VAD cuts a recording at the first pause after 6 s of speech
(or at the latest pause before 18 s if there is none), and the speech since the last pause is decoded
whenever you pause, so release latency stays flat however long you talk. Silence is trimmed, and a
recording with no speech is ignored.
Keep `hotwords` to a few dozen entries — they share that context.

OpenAI (`gpt-live-transcribe`, `delay: medium`):

| | |
|---|---|
| Footprint | ~15 MB idle and while dictating |
| ASR at release | ~0.5–0.8 s, however long you spoke: most text streams back during speech, but the final transcript arrives ~0.5–0.8 s after commit regardless |
| Rewrite | ~0.3–0.5 s |
| Cost | $0.017 per minute of audio |

`delay` barely moves release latency (minimal…xhigh all measured ~0.5–0.7 s), so it defaults to the more
accurate `medium`.

## Use

Hold **Right Option**, speak, release. Esc cancels.
Line breaks are sent as Shift+Return so chat apps don't send early (set `output.newlines` to change;
note that terminals treat Shift+Return as Return). Pressing another key while holding the hotkey
(e.g. ⌥← to jump words) cancels too, so Option keeps working as a modifier.

A soft sound marks start and stop, and a small glass orb sits at the bottom of the screen while you speak:
its band of light swells with your voice, narrows and breathes while transcribing, and dissolves once the
text is in. It only shows words for errors. Both are configurable under `feedback` (`feedback.pill` turns the orb off).
The screenshots above are rendered from the real orb view with `just-speak render-orb docs`.

Menu bar icon: 🎤 idle · rose mic recording · ⋯ processing · ⚠︎ something needs attention (open the menu).

Config: `~/.config/just-speak/config.json` — see [`config.example.json`](config.example.json).

## CLI

```sh
just-speak history --since 7d          # print (add --raw for the pre-rewrite text, --json, --grep)
just-speak transcribe a.wav b.wav      # ASR only (same path as the app), with timings; --provider openai|local|hybrid
                                       #   --realtime: feed at speaking pace (true release latency); --whole: one pass (local)
just-speak rewrite "um so like hello"  # rewrite only
just-speak config-path
```

## Files

| | |
|---|---|
| `~/.config/just-speak/config.json` | settings |
| `~/.config/just-speak/.env` | `OPENAI_API_KEY`, `INCEPTION_API_KEY` (if not in config) |
| `~/Library/Application Support/just-speak/history/YYYY-MM.jsonl` | one JSON record per line (owner-only, 0600) |
| `~/Library/Logs/just-speak.log` | timings and errors only — never transcript text |
| `~/Library/Application Support/just-speak/models/` | `funasr-nano-int8-mmap/`, `silero_vad.onnx` (local provider) |

## Development

```sh
swift build && swift test
swift run just-speak transcribe ~/Library/Application\ Support/just-speak/models/funasr-nano-int8-mmap/test_wavs/far_3.wav
```

### Releasing

```sh
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` tests, builds and signs the app, attaches `JustSpeak-<version>.zip` to a
GitHub Release and updates `Casks/just-speak.rb` in [jxu-dev-c/homebrew-tap](https://github.com/jxu-dev-c/homebrew-tap).
It needs the secrets listed at the top of that workflow.

## License

MIT — see [LICENSE](LICENSE). Third-party runtimes and models are downloaded at setup time and keep
their own (Apache-2.0 / MIT) licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
