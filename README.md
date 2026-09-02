<div align="center">
  <img src="mac/assets/openvox-logo.png" width="128" height="128" alt="OpenVox app icon">
  <h1>OpenVox</h1>
  <p><strong>Private, on-device voice dictation for macOS.</strong></p>
  <p>Hold a shortcut. Speak. Your words appear in any app.</p>
  <p>
    <a href="https://github.com/0xAnto/openvox/actions/workflows/ci.yml"><img src="https://github.com/0xAnto/openvox/actions/workflows/ci.yml/badge.svg" alt="Build status"></a>
    <a href="https://github.com/0xAnto/openvox/releases/latest"><img src="https://img.shields.io/github/v/release/0xAnto/openvox?display_name=tag" alt="Latest release"></a>
  </p>
  <p><a href="https://github.com/0xAnto/openvox/releases/latest"><strong>Download for macOS</strong></a></p>
</div>

## Designed for the Mac

A native app with a menu-bar companion. Press your shortcut in any app and the text lands at your cursor. Speech recognition runs on your Mac, so your voice never leaves it.

## Features

| | |
| --- | --- |
| **Any app** | One global shortcut. Works wherever you can type. |
| **Hold or tap** | Hold to talk. Tap once for hands-free, tap again to stop. |
| **Two modes** | Fast for low memory. Streaming for text as you speak. |
| **Cancel key** | Stop a dictation before it inserts. |
| **Indicator** | Shows when OpenVox is listening. Choose the color. |
| **History** | Search, copy, and clear past dictations. Keep for 7 days, 30 days, or forever. |
| **Microphone** | Pick any input device. |
| **Launch at login** | Ready when you are. |

## Speech models

| Mode | Model | Behavior | Download |
| --- | --- | --- | --- |
| **Fast** | [Moonshine Streaming](https://huggingface.co/moonshine-ai/moonshine-streaming) (medium, ONNX) | Transcribes when you release the key. | ~1.1 GB |
| **Streaming** | [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | Types while you speak, then finalizes. | ~5 GB with runtime |

Models download after you pick a mode. The app ships without them.

## Privacy

Audio and dictations stay on your Mac. Setup connects to Hugging Face once to download the model. History is stored at:

```text
~/Library/Application Support/OpenVox/history.json
```

## Install

1. Download `OpenVox-*-macOS.zip` from [Releases](https://github.com/0xAnto/openvox/releases/latest).
2. Unzip and move `OpenVox.app` to Applications.
3. Open it and follow the setup.
4. Grant Microphone and Accessibility access.

Builds are ad-hoc signed. On first launch, Control-click OpenVox and choose **Open**.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon recommended
- Internet for the first model download
- [`uv`](https://docs.astral.sh/uv/) or Python 3.10+

## Build from source

```bash
git clone https://github.com/0xAnto/openvox.git
cd openvox/mac
./scripts/build-app.sh
open OpenVox.app
```

Self-test without permissions or downloads:

```bash
swift build
.build/debug/OpenVox --selftest
```

## Releases

Every merge to `main` tags `v1.0.<run-number>` and publishes the app ZIP with a SHA-256 checksum on [Releases](https://github.com/0xAnto/openvox/releases).

## Repository layout

```text
openvox/
├── mac/          # macOS app, sidecar, assets, build tools
├── .github/      # PR builds and automatic releases
└── README.md
```

Windows and Linux clients will get their own top-level folders.
