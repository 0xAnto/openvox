<div align="center">
  <img src="mac/assets/openvox-logo.png" width="128" height="128" alt="OpenVox app icon">
  <h1>OpenVox</h1>
  <p><strong>Private, on-device voice dictation for macOS.</strong></p>
  <p>Hold a shortcut. Speak naturally. Your words appear in any app.</p>
  <p>
    <a href="https://github.com/0xAnto/openvox/actions/workflows/ci.yml"><img src="https://github.com/0xAnto/openvox/actions/workflows/ci.yml/badge.svg" alt="Build status"></a>
    <a href="https://github.com/0xAnto/openvox/releases/latest"><img src="https://img.shields.io/github/v/release/0xAnto/openvox?display_name=tag" alt="Latest release"></a>
  </p>
  <p><a href="https://github.com/0xAnto/openvox/releases/latest"><strong>Download the latest release</strong></a></p>
</div>

## Designed for the Mac

OpenVox is a native macOS app with a lightweight menu-bar companion. The main window keeps Home, History, and Settings together, while the menu bar stays ready for quick controls.

- Dictate into any macOS app with a configurable global shortcut.
- Hold to talk, or tap once to continue hands-free and tap again to stop.
- Choose between fast offline transcription and live streaming text.
- See readiness, shortcut, activity statistics, and recent dictations on Home.
- Search, copy, retain, or clear locally stored dictation history.
- Select a microphone, customize the cancel key and indicator, and launch at login.
- Keep audio and transcription on your Mac after the speech model is downloaded.

## Speech models

| Mode | Model | Experience | Download |
| --- | --- | --- | --- |
| **Fast** | [Moonshine Streaming](https://huggingface.co/moonshine-ai/moonshine-streaming), medium ONNX graphs | Records while the shortcut is held, then transcribes when it is released. Lowest memory use. | About 1.1 GB |
| **Streaming** | [NVIDIA Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | Types partial results while you speak, then finalizes the remaining text. | About 5 GB including the streaming runtime |

Models are downloaded only after the user chooses a mode. They are not included in the app bundle.

## Privacy

OpenVox sends neither microphone audio nor completed dictations to an OpenVox service. Model inference runs locally. First-time setup connects to Hugging Face to download the selected model and installs the local Python runtime dependencies.

Dictation history is stored at:

```text
~/Library/Application Support/OpenVox/history.json
```

History can be cleared at any time and retained for 7 days, 30 days, or indefinitely.

## Install

1. Download the newest `OpenVox-*-macOS.zip` from [GitHub Releases](https://github.com/0xAnto/openvox/releases/latest).
2. Unzip it and move `OpenVox.app` to Applications.
3. Open OpenVox and follow the five-step setup.
4. Grant Microphone and Accessibility access when macOS asks.

Current automated builds are ad-hoc signed for testing. On first launch, macOS may require you to Control-click OpenVox, choose **Open**, and confirm. Developer ID signing and notarization are required before broad public distribution without that prompt.

## Requirements

- macOS 14 Sonoma or later
- An internet connection during initial model setup
- Approximately 1.1 GB for Fast mode, or 5 GB for Streaming mode
- [`uv`](https://docs.astral.sh/uv/) or Python 3.10 or later for the local runtime bootstrap

OpenVox is tuned for Apple silicon. CPU fallback paths exist, but Intel Macs are not part of the current release test matrix.

## Build from source

```bash
git clone https://github.com/0xAnto/openvox.git
cd openvox/mac
./scripts/build-app.sh
open OpenVox.app
```

Run the local self-test without requesting permissions or downloading a model:

```bash
swift build
.build/debug/OpenVox --selftest
```

## Releases

Pull requests targeting `main` build and validate a downloadable app artifact. Every merge to `main` creates a versioned `v1.0.<run-number>` tag and publishes the app ZIP plus its SHA-256 checksum on the [Releases page](https://github.com/0xAnto/openvox/releases).

## Repository layout

```text
openvox/
├── mac/          # Native macOS app, runtime sidecar, assets, and build tools
├── .github/      # Pull-request builds and automatic GitHub releases
└── README.md
```

Future Windows and Linux clients will live in their own top-level platform folders.
