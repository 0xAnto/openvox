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

Builds are ad-hoc signed, so macOS blocks the first launch. It reports the app
as damaged and offers only **Move to Trash**. The app is not damaged. macOS
adds a quarantine flag to every download, and it refuses an unsigned app that
carries the flag. Remove the flag after you drag the app to Applications:

```bash
xattr -dr com.apple.quarantine /Applications/OpenVox.app
```

Then open the app as usual.

An ad-hoc signature also changes with every build, and macOS then drops the Accessibility grant. Repair it after each update: open **System Settings > Privacy & Security > Accessibility**, remove OpenVox with the minus button, then add the new app. The toggle alone does not repair the grant.

## Build from source

```bash
git clone https://github.com/0xAnto/openvox.git
cd openvox/mac
./scripts/build-app.sh
open /Applications/OpenVox.app
```

`build-app.sh` installs the app in `/Applications` and signs it there. A local
build carries no quarantine flag, so this path avoids the release-download
warning above. Set `CI=1` to keep the bundle in the source folder instead.

The script replaces `/Applications/OpenVox.app`. A local build and a release
build use the same bundle identifier, so they also share the settings, the
history, and the downloaded runtime in
`~/Library/Application Support/OpenVox`. Keep a release copy under a different
name before you build, or build with `CI=1`.

Each ad-hoc build gets a new signature, so macOS drops the Accessibility grant.
The script runs `tccutil reset Accessibility` for you. You still grant
Accessibility again in System Settings after each build.

Run the self-test to skip the permissions and the downloads:

```bash
swift build
.build/debug/OpenVox --selftest
```

The bare binary has no bundle and no `Info.plist`, so it gets no microphone
prompt and no Accessibility identity. Use `--selftest` only. Build the app for
every other test.

## Releases

1. Merge a pull request into `main`.
2. The workflow builds the app, packs the disk image, and signs it when the signing secrets exist.
3. The workflow publishes `OpenVox-v1.0.<run number>-macOS.dmg` on [Releases](https://github.com/0xAnto/openvox/releases). GitHub shows its SHA-256 there.
