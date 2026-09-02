<div align="center">
  <img src="mac/assets/openvox-logo.png" width="128" height="128" alt="OpenVox app icon">
  <h1>OpenVox</h1>
  <p><strong>Say it. It's typed.</strong></p>
  <p>Private, on-device voice dictation for the Mac. Hold a key, speak, and your words land in any app.</p>
  <p>
    <a href="https://github.com/0xAnto/openvox/actions/workflows/ci.yml"><img src="https://github.com/0xAnto/openvox/actions/workflows/ci.yml/badge.svg" alt="Build status"></a>
    <a href="https://github.com/0xAnto/openvox/releases/latest"><img src="https://img.shields.io/github/v/release/0xAnto/openvox?display_name=tag" alt="Latest release"></a>
  </p>
  <p><a href="https://github.com/0xAnto/openvox/releases/latest"><strong>Download for macOS</strong></a></p>
</div>

## Works everywhere you type.

OpenVox sits in your menu bar and listens only when you ask. Press your shortcut in Mail, Notes, Slack, a browser, or a terminal. The text appears where your cursor is. No copy, no paste, no switching windows.

## Every word stays on your Mac.

Speech recognition runs locally. Your voice never leaves your computer, and OpenVox has no server to send it to. Download a model once, then dictate offline for as long as you like.

## Features

| | |
| --- | --- |
| **One shortcut, any app** | Set a global shortcut and dictate into every macOS app that accepts text. |
| **Hold or tap** | Hold the key to talk. Tap it once to go hands-free, then tap again to stop. |
| **Two listening modes** | Choose Fast for lowest memory use, or Streaming to watch text appear while you speak. |
| **Cancel key** | Press one key to stop a dictation before it inserts anything. |
| **Live indicator** | A small on-screen indicator shows when OpenVox is listening. Pick its accent color. |
| **Home at a glance** | See readiness, your shortcut, activity statistics, and recent dictations in one window. |
| **Searchable history** | Search, copy, and clear past dictations. Keep them for 7 days, 30 days, or forever. |
| **Your microphone** | Choose the input device you want, including external and USB microphones. |
| **Ready at login** | Turn on Launch at Login and OpenVox is waiting when you sit down. |
| **Native to macOS** | Built in Swift with a menu-bar companion, a real app window, and system permissions handled the Mac way. |

## Two ways to listen.

| Mode | Model | How it feels | Download |
| --- | --- | --- | --- |
| **Fast** | [Moonshine Streaming](https://huggingface.co/moonshine-ai/moonshine-streaming) (medium, ONNX) | Records while you hold the key. Transcribes the moment you let go. Lowest memory use. | About 1.1 GB |
| **Streaming** | [NVIDIA Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | Types partial words while you speak, then settles the final text. | About 5 GB, including the streaming runtime |

Fast mode runs on ONNX Runtime with a small Python runtime of about 60 MB. Streaming mode adds PyTorch and Transformers. OpenVox downloads a model only after you choose its mode. The app bundle ships without models.

## Private by design.

- Microphone audio and finished dictations never leave your Mac.
- Model inference runs locally, with no OpenVox account and no OpenVox service.
- First-time setup connects to Hugging Face once to download the model you choose, and installs the local Python runtime.
- History lives in one file you control:

```text
~/Library/Application Support/OpenVox/history.json
```

Clear it any time from Settings.

## Get started.

1. Download the latest `OpenVox-*-macOS.zip` from [Releases](https://github.com/0xAnto/openvox/releases/latest).
2. Unzip it and move `OpenVox.app` to Applications.
3. Open OpenVox and follow the five-step setup.
4. Grant Microphone and Accessibility access when macOS asks.

Current builds are ad-hoc signed. On first launch, Control-click OpenVox, choose **Open**, and confirm. Developer ID signing and notarization come before broad public distribution.

## What you need.

- macOS 14 Sonoma or later
- Apple silicon recommended. CPU fallback paths exist, but Intel Macs are not in the release test matrix.
- An internet connection during first model setup
- About 1.1 GB of disk space for Fast mode, or 5 GB for Streaming mode
- [`uv`](https://docs.astral.sh/uv/) or Python 3.10 or later for the local runtime

## Build it yourself.

```bash
git clone https://github.com/0xAnto/openvox.git
cd openvox/mac
./scripts/build-app.sh
open OpenVox.app
```

Run the self-test without permissions or model downloads:

```bash
swift build
.build/debug/OpenVox --selftest
```

## Releases

Every pull request against `main` builds and validates a downloadable app artifact. Every merge to `main` tags a `v1.0.<run-number>` release and publishes the app ZIP with its SHA-256 checksum on the [Releases page](https://github.com/0xAnto/openvox/releases).

## Repository layout

```text
openvox/
├── mac/          # Native macOS app, runtime sidecar, assets, and build tools
├── .github/      # Pull-request builds and automatic GitHub releases
└── README.md
```

Windows and Linux clients will live in their own top-level platform folders.
