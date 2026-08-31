#!/bin/bash
# Builds OpenVox.app from the SwiftPM package. No Xcode: plain `swift build`
# plus a hand-assembled bundle, ad-hoc signed so TCC (mic/Accessibility)
# grants persist across rebuilds of the same signing identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OpenVox"
BUNDLE_ID="io.kanalabs.openvox"
APP="$ROOT/$APP_NAME.app"

echo "==> swift build -c release"
(cd "$ROOT" && swift build -c release)

BUILT_BIN="$ROOT/.build/release/$APP_NAME"
if [ ! -f "$BUILT_BIN" ]; then
    echo "error: built binary not found at $BUILT_BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT_BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenVox needs microphone access to turn your speech into text.</string>
</dict>
</plist>
PLIST

SIDECAR_SRC="$ROOT/sidecar"
if [ -d "$SIDECAR_SRC" ] && [ -n "$(ls -A "$SIDECAR_SRC" 2>/dev/null)" ]; then
    echo "==> copying sidecar/ into Resources"
    mkdir -p "$APP/Contents/Resources/sidecar"
    cp -R "$SIDECAR_SRC"/. "$APP/Contents/Resources/sidecar/"
else
    echo "warning: $SIDECAR_SRC is missing or empty; shipping without the sidecar (add it before distributing)"
fi

echo "==> codesign (ad-hoc, stable identifier)"
codesign --force -s - --identifier "$BUNDLE_ID" "$APP"

echo "==> done: $APP"
