# OpenVox — Design

Local-first macOS dictation. Hold a hotkey, speak, release, text appears in
the focused app. Menu-bar only, no dock icon, no cloud.

All model and runtime choices below come from measured results in
`/Users/kana/Documents/Apps/asr-benchmark/RESULTS.md` (same machine: M1,
8 GB, macOS 15.7.4). Do not re-litigate them.

## Architecture

Two processes:

1. **OpenVox.app** — native Swift (AppKit + SwiftUI), menu-bar app. Owns the
   hotkey, audio capture, text insertion, UI, permissions, and the sidecar's
   lifecycle.
2. **Sidecar** — one long-lived Python process (`sidecar/openvox_sidecar.py`)
   that runs whichever engine is active. Engines are ports of the proven
   adapters in `/Users/kana/Documents/Apps/asr-benchmark/adapters/`
   (`moonshine_onnx.py`, `nemotron.py`) with the benchmark plumbing removed.

Why a Python sidecar: Nemotron only runs via `transformers`>=5.13 + PyTorch
MPS (no ONNX/CoreML export exists). Moonshine could run natively via
onnxruntime C, but a second integration path buys nothing once the sidecar
exists. One runtime, both engines.

Why one model at a time: Nemotron warm is 3.6 GB, Moonshine 642 MB, machine
has 8 GB. Switching mode unloads the old engine, loads the new. The active
engine stays warm (loaded) while the app runs.

## Engines (fixed decisions)

| | Fast / Offline | Streaming |
| --- | --- | --- |
| Checkpoint | `moonshine-ai/moonshine-streaming`, `onnx/medium/*` | `nvidia/nemotron-speech-streaming-en-0.6b` |
| Runtime | onnxruntime, **CPUExecutionProvider only** (CoreML measured 6–10x slower) | transformers `AutoModelForRNNT`, **MPS** (CPU fallback) |
| Use | record whole utterance, transcribe on release (~330 ms to final) | 160 ms chunks, cache-aware streaming, append-only partials (churn 0.00) |
| Storage | standard HF cache (`~/.cache/huggingface`) via `snapshot_download` — both models are already there on this machine | same |

Nemotron streaming uses the background-`generate()` + queue pattern exactly as
in `adapters/nemotron.py` including its MPS thread-discipline (that code fixed
a real Metal crash — port it verbatim). Chunk size fixed at 160 ms
(lookahead 1). Moonshine offline path = `transcribe()` from
`adapters/moonshine_onnx.py` (frontend with zero state → encoder → adapter →
greedy decode). Moonshine's streaming path is NOT used (measured: cannot hold
real time).

## Sidecar protocol

NDJSON over stdin/stdout, one object per line. Audio is base64 float32 LE,
16 kHz mono. stderr = free-form logs.

App → sidecar:
- `{"op":"load","engine":"moonshine"|"nemotron"}` — download if needed
  (emit `progress`), load, warm up, reply `ready`. Loading a different engine
  implies unloading the current one.
- `{"op":"transcribe","pcm":"<b64>"}` — offline path. Reply one `final`.
- `{"op":"stream","pcm":"<b64>"}` — one 160 ms chunk. Reply `partial` only
  when the transcript grew (full transcript so far, append-only).
- `{"op":"finalize"}` — end of utterance. Reply one `final` (full transcript),
  reset stream state.
- `{"op":"ping"}` → `{"ev":"pong"}`.

Sidecar → app:
- `{"ev":"progress","stage":"download"|"load","pct":0-100}`
- `{"ev":"ready","engine":...}`
- `{"ev":"partial","text":"<full transcript so far>"}`
- `{"ev":"final","text":...}`
- `{"ev":"error","message":...}` — recoverable; app surfaces it and resets.

Sidecar exits when stdin closes. App restarts it if it dies.

## Python runtime and lazy provisioning

Created on first launch at `~/Library/Application Support/OpenVox/runtime`
(a venv): `uv venv --python 3.12` + `uv pip install` when uv exists, else
`python3 -m venv` + pip. Menu shows setup / download progress. Sidecar
scripts live in `OpenVox.app/Contents/Resources/sidecar/`.

Install only what the selected mode needs:

- `requirements-base.txt` — `numpy huggingface_hub onnxruntime tokenizers`
  (~60 MB). Installed on first launch. Enough for Fast/Offline.
- `requirements-streaming.txt` — `torch torchaudio transformers>=5.13`
  (~2–3 GB). Installed only when the user first enables Streaming.

Default mode is **Fast/Offline**. Nothing installs or downloads without the
user seeing and starting it (see Onboarding). Enabling Streaming later in
settings: install streaming deps, then `load` nemotron (downloads ~2.3 GB),
all with progress in the UI. Fast mode keeps working during the deps
install (app-side); it pauses during the sidecar's own download+load op
(the stdin loop serializes ops), with honest "preparing" status shown. The sidecar imports torch lazily (inside the
nemotron engine only) so it always starts with base deps alone; `load` for
nemotron without torch replies
`{"ev":"error","code":"missing-streaming-deps",...}` and the app runs the
extras install. Downloaded models and deps stay on disk (no auto-delete).

## Onboarding (first launch)

A setup-assistant window in the style of a first-party Mac utility: fixed
size (~640x520), centered, not resizable, standard traffic lights, SwiftUI,
generous whitespace, SF Symbols, semantic colors only. Steps, Continue
bottom-right, Back where it makes sense. Shown when setup was never
completed (UserDefaults flag); later launches go straight to the menu bar.

1. **Welcome** — app symbol, "Welcome to OpenVox", one calm sentence
   (hold a key, speak, text appears — all on this Mac, nothing leaves it).
   Continue.
2. **Choose how you dictate** — two selectable option cards:
   *Fast* (recommended, preselected): transcribes the moment you release
   the key; ~1.1 GB download; lowest memory. *Streaming*: text appears
   while you speak; ~5 GB download; uses more memory. One line under the
   cards: "You can switch anytime in Settings — the other option downloads
   then." The Continue button reads "Download" and states the size.
3. **Download** — determinate progress bar with stage labels ("Preparing
   runtime…" indeterminate during venv/pip, then "Downloading speech
   model — X of Y" from sidecar progress events, then "Loading…"). Shows
   nothing scary, no logs. Failure state: short message + Retry. Auto-
   advances when the engine reports ready. If everything is already on
   disk it passes through quickly showing "Already downloaded".
4. **Set up** — the essentials, live: microphone permission (grant button →
   status), accessibility permission (opens System Settings, status polls),
   hotkey recorder (default: hold Right Option), microphone picker, launch
   at login. This reuses the same SwiftUI form the Settings window shows —
   one view, two homes.
5. **Ready** — "You're all set. Hold ⌥ and speak." Done closes the window;
   the app lives in the menu bar.

## Swift app components (one SwiftPM executable target)

- **AppState** — mode, engine status, settings (UserDefaults: mode, hotkey,
  mic ID, launch-at-login). Single `@Observable`/ObservableObject.
- **StatusItem + menu** — NSStatusItem with the template glyph. Menu:
  "Enable Dictation" toggle, Settings…, Quit, plus a disabled status row
  only while provisioning/loading/on error. The mode picker lives ONLY in
  Settings (switching provisions with progress and an explicit success
  state). Settings window (SwiftUI): mode picker, hotkey recorder, cancel
  key recorder, microphone picker, launch at login toggle, permission
  status rows (live-polled) with "Open System Settings" buttons.
- **HotkeyMonitor** — CGEventTap (active, session), listens for
  keyDown/keyUp/flagsChanged. Hold-to-talk: key down → start, key up → stop.
  Supports a plain key (swallowed while dictating so it does not type) or a
  single modifier (e.g. Right Option, matched by keycode via flagsChanged).
  Default: Right Option. Requires Accessibility (same permission insertion
  needs). Re-enable tap on `kCGEventTapDisabled*`.
- **AudioCapture** — AVAudioEngine input tap → AVAudioConverter →
  16 kHz mono Float32. Streaming: deliver 2560-sample (160 ms) chunks.
  Offline: accumulate the utterance, hand over on stop. Mic selection: set
  device on the input AudioUnit (`kAudioOutputUnitProperty_CurrentDevice`);
  device list from CoreAudio (input-capable devices only). Publishes an RMS
  level for the indicator.
- **SidecarClient** — spawns venv python + sidecar script, NDJSON over pipes,
  async event stream, auto-restart with backoff, `load` on mode change so the
  active engine is always warm.
- **TextInserter** — CGEvent with `keyboardSetUnicodeString`, ≤20 UTF-16
  units per event, posted to `cghidEventTap`. Streaming: on each `partial`,
  type only the new suffix (prefix-match against what was already typed; on
  the never-observed mismatch case, stop typing partials and let `final`
  supply the remainder). Offline `final` > 300 chars: pasteboard + ⌘V, then
  restore the previous pasteboard contents after a short delay.
- **IndicatorPanel** — small non-activating floating NSPanel, bottom-center
  of the active screen: capsule with mic glyph + live level while listening,
  subtle progress state while transcribing (Moonshine) / while streaming text
  lands. Hidden otherwise. Never takes focus.
- **PermissionsHelper** — mic: `AVCaptureDevice.requestAccess`. Accessibility:
  `AXIsProcessTrustedWithOptions` + deep link to System Settings pane.
- **Launch at login** — `SMAppService.mainApp`.

## Dictation flows

Fast/Offline: hotkey down → indicator on, capture starts → hotkey up →
indicator shows "transcribing" → `transcribe` → `final` → insert → indicator
hides. Sub-second from release to text for normal utterances.

Streaming: hotkey down → indicator on, 160 ms chunks flow (`stream`) →
partials typed as they arrive (append-only) → hotkey up → `finalize` → type
remaining tail → indicator hides.

Guards: ignore hotkey while a previous utterance is still finalizing; drop
utterances shorter than 150 ms (accidental taps); if the sidecar is not
`ready`, show state in the indicator instead of recording into the void.

## Build (no Xcode, CLT only)

SwiftPM executable + `scripts/build-app.sh`: `swift build -c release`,
assemble `OpenVox.app` (Info.plist: `LSUIElement=true`,
`NSMicrophoneUsageDescription`, bundle id `io.kanalabs.openvox`), copy
sidecar into Resources, `codesign --force -s -` (stable ad-hoc identity so
TCC grants persist across rebuilds of the same signature).

## Testing

- Sidecar: assert-based self-check (`python openvox_sidecar.py --selfcheck`)
  that synthesizes speech with `say`, drives the real NDJSON protocol
  end-to-end for both engines, and checks partial monotonicity + non-empty
  finals. Runs against the benchmark repo's venvs during development.
- Swift: `swift build` clean; a small `--selftest` run mode that exercises
  chunking and suffix-diff logic with asserts (no UI, no permissions needed).
- Manual: end-to-end hold-to-talk in TextEdit after granting permissions.

## Future: native runtime candidates (researched 2026-08-31, not used)

A zero-Python build is possible later, but only after measuring quality on
this machine (the benchmark's method: never trust a leaderboard):

- Nemotron: sherpa-onnx exports of this exact model exist —
  `csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-160ms-2026-04-25`
  (fp32 and int8; int8 is ~663 MB total) via the sherpa-onnx C API. Also a
  CoreML/ANE port: `FluidInference/nemotron-speech-streaming-en-0.6b-coreml`
  with the FluidAudio Swift package. FluidAudio's own numbers degrade at the
  low-latency tiers (~10% WER at 160 ms on 20 files, ~60% at 80 ms), so the
  int8/CoreML conversions must be re-benchmarked at 160 ms before adoption.
- Moonshine medium: no sherpa-onnx support (tiny/base only). Native options:
  the official `moonshine-ai/moonshine-swift` package, or a DIY onnxruntime-C
  port of the 6-graph pipeline documented in the benchmark adapter.

## Out of scope (deliberate)

Punctuation commands, history/clips UI, multiple languages, per-app behavior,
custom vocab, VAD/auto-stop, app sandbox + notarization (local build).
