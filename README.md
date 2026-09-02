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

Releases stay ad-hoc signed until the signing secrets exist. An ad-hoc signature changes with every build, so macOS drops the Accessibility grant on every update. Repair it after each update: open **System Settings > Privacy & Security > Accessibility**, remove OpenVox from the list with the minus button, then add the new app again. The toggle alone does not repair the grant.

### Developer ID signing

Add these five repository secrets to sign and notarize every build. The workflows import the certificate into a temporary keychain, sign with the hardened runtime, notarize with `notarytool`, and staple the ticket to the app. A Developer ID signature stays the same across builds, so the Accessibility grant survives an update.

| Secret | Holds |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 text of the exported "Developer ID Application" certificate and its private key |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` file |
| `APPLE_ID` | Apple ID of the account that notarizes |
| `APPLE_TEAM_ID` | 10-character team identifier of the developer account |
| `APPLE_APP_PASSWORD` | app-specific password for that Apple ID, from [appleid.apple.com](https://appleid.apple.com) |

Export the certificate from Keychain Access as `certificate.p12`, then copy its base64 text:

```bash
base64 -i certificate.p12 | pbcopy
```

Paste the clipboard into the `MACOS_CERTIFICATE_P12` secret.

Pull-request builds sign and notarize only when the secrets exist. A pull request from a fork never receives them, so it keeps the ad-hoc path.

Set `CODESIGN_IDENTITY` to sign a local build with the same identity:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

Run `security find-identity -v -p codesigning` to list the identities. Without `CODESIGN_IDENTITY` the script signs ad-hoc and resets the Accessibility grant for the bundle.

## Repository layout

```text
openvox/
├── mac/          # macOS app, sidecar, assets, build tools
├── .github/      # PR builds and automatic releases
└── README.md
```

Windows and Linux clients will get their own top-level folders.
