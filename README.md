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

## Features

| | |
| --- | --- |
| **Any app** | One global shortcut. The text lands at your cursor. |
| **Hold or tap** | Hold to talk. Tap once for hands-free, tap again to stop. |
| **Two modes** | Fast for low memory. Streaming for text as you speak. |
| **Cancel key** | Stop a dictation before it inserts. |
| **Indicator** | Shows when OpenVox listens. Choose the color. |
| **History** | Search, copy, and clear past dictations. Keep them for 7 days, 30 days, or forever. |
| **Microphone** | Pick any input device. |
| **Launch at login** | Ready when you are. |

## Speech models

| Mode | Model | Behavior | Download |
| --- | --- | --- | --- |
| **Fast** | [Moonshine Streaming](https://huggingface.co/moonshine-ai/moonshine-streaming) (medium, ONNX) | Transcribes when you release the key. | ~1.1 GB |
| **Streaming** | [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | Types while you speak, then finalizes. | ~5 GB with runtime |

The app ships without the models. Your chosen mode downloads its own.

## Privacy

Your audio and your dictations stay on your Mac. Setup connects to Hugging Face once, to download the model. History stays in `~/Library/Application Support/OpenVox/history.json`.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon recommended
- [`uv`](https://docs.astral.sh/uv/) or Python 3.10 or later. Setup builds the speech runtime with it.
- Internet for the first model download

## Install

1. Download `OpenVox-*-macOS.dmg` from [Releases](https://github.com/0xAnto/openvox/releases/latest).
2. Open the disk image and drag `OpenVox.app` onto the Applications alias.
3. Open it and follow the setup.
4. Grant Microphone and Accessibility access.

Builds are ad-hoc signed, so macOS blocks the first launch. Open **System Settings > Privacy & Security**, then click **Open Anyway**.

An ad-hoc signature also changes with every build, and macOS then drops the Accessibility grant. Repair it after each update: open **System Settings > Privacy & Security > Accessibility**, remove OpenVox with the minus button, then add the new app. The toggle alone does not repair the grant.

## Build from source

```bash
git clone https://github.com/0xAnto/openvox.git
cd openvox/mac
./scripts/build-app.sh
open OpenVox.app
```

Run the self-test to skip the permissions and the downloads:

```bash
swift build
.build/debug/OpenVox --selftest
```

## Releases

Every merge to `main` publishes an ad-hoc signed disk image, and the app ZIP beside it, each with a SHA-256 checksum on [Releases](https://github.com/0xAnto/openvox/releases).
