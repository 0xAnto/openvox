#!/bin/bash
# Builds OpenVox.app from the SwiftPM package. No Xcode: plain `swift build`
# plus a hand-assembled bundle, ad-hoc signed so it has a verifiable local
# identity. Accessibility must be refreshed after the executable changes;
# use a real Developer ID identity for stable grants in distributed builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OpenVox"
BUNDLE_ID="io.kanalabs.openvox"
APP="$ROOT/$APP_NAME.app"
APP_VERSION="${OPENVOX_VERSION:-1.0.0}"
APP_BUILD="${OPENVOX_BUILD_NUMBER:-1}"

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
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenVox needs microphone access to turn your speech into text.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

ASSETS_SRC="$ROOT/assets"
if [ -f "$ASSETS_SRC/AppIcon.icns" ]; then
    cp "$ASSETS_SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: $ASSETS_SRC/AppIcon.icns not found; app will show the generic icon"
fi
for icon in MenuBarIcon.png "MenuBarIcon@2x.png"; do
    if [ -f "$ASSETS_SRC/$icon" ]; then
        cp "$ASSETS_SRC/$icon" "$APP/Contents/Resources/$icon"
    else
        echo "warning: $ASSETS_SRC/$icon not found; status item falls back to an SF Symbol"
    fi
done

SIDECAR_SRC="$ROOT/sidecar"
if [ -d "$SIDECAR_SRC" ] && [ -n "$(ls -A "$SIDECAR_SRC" 2>/dev/null)" ]; then
    echo "==> copying sidecar/ into Resources"
    mkdir -p "$APP/Contents/Resources/sidecar"
    # Bytecode caches are machine-local build debris. Shipping them is
    # unnecessary, and Python may rewrite them after launch, which would
    # invalidate the app bundle's code signature.
    rsync -a --exclude='__pycache__/' --exclude='*.py[co]' \
        "$SIDECAR_SRC"/ "$APP/Contents/Resources/sidecar/"
else
    echo "warning: $SIDECAR_SRC is missing or empty; shipping without the sidecar (add it before distributing)"
fi

echo "==> codesign (ad-hoc, bundle identifier: $BUNDLE_ID)"
codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

# An ad-hoc signature changes with every build, which silently voids the
# Accessibility grant (the System Settings toggle stays on but no longer
# applies, so the hotkey does nothing). Register this exact bundle with
# Launch Services before resetting TCC; otherwise tccutil may reject the
# bundle identifier and leave the stale, misleading enabled row in place.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    echo "==> registering app with Launch Services"
    "$LSREGISTER" -f "$APP"
fi
echo "==> resetting stale Accessibility grant for $BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID" || echo "warning: tccutil reset failed; toggle OpenVox off/on in System Settings > Privacy & Security > Accessibility"

echo "==> done: $APP"
