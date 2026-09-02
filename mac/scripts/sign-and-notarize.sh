#!/bin/bash
# Developer ID signing and notarization helper for the GitHub workflows.
# Both release.yml and ci.yml call it, so the shell lives here once.
#
# The workflows run these commands only when the signing secrets exist. A
# fork has no secrets, so its build stays on the ad-hoc path.
#
#   import-certificate   Create a temporary keychain, import the .p12, and
#                        export CODESIGN_IDENTITY for the build step.
#   notarize <zip>       Submit the zip to Apple, wait, staple the ticket to
#                        OpenVox.app, and pack the stapled app again.
#   cleanup              Delete the temporary keychain.
#
# Environment:
#   MACOS_CERTIFICATE_P12       base64 of the Developer ID .p12
#   MACOS_CERTIFICATE_PASSWORD  password of the .p12
#   APPLE_ID                    Apple ID of the notarization account
#   APPLE_TEAM_ID               10-character team identifier
#   APPLE_APP_PASSWORD          app-specific password for that Apple ID
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/OpenVox.app"
# A fixed path lets the cleanup step find the keychain without saved state.
KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openvox-signing.keychain-db"

require_env() {
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            echo "error: $name is empty; set it from the matching repository secret" >&2
            exit 1
        fi
    done
}

import_certificate() {
    require_env MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD

    # The keychain password protects a keychain that the cleanup step deletes
    # in the same job, so a random value is enough.
    local keychain_password identity
    keychain_password="$(uuidgen)"
    # The trap runs after the local scope ends, so the path stays global.
    P12_FILE="$(mktemp -t openvox-cert)"
    trap 'rm -f "$P12_FILE"' EXIT
    printf '%s' "$MACOS_CERTIFICATE_P12" | base64 -d > "$P12_FILE"

    echo "==> creating temporary keychain $KEYCHAIN"
    security create-keychain -p "$keychain_password" "$KEYCHAIN"
    # Do not lock the keychain while the build runs.
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$keychain_password" "$KEYCHAIN"

    echo "==> importing the Developer ID certificate"
    security import "$P12_FILE" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security
    # codesign reads the private key without a user interface prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$keychain_password" "$KEYCHAIN" >/dev/null

    # Put the temporary keychain first in the search list and keep the rest,
    # so codesign in the next step finds the identity.
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KEYCHAIN" \
        $(security list-keychains -d user | tr -d '"')

    # ponytail: the script takes the first Developer ID Application identity.
    # Ceiling: one such certificate per .p12. Upgrade path: read the identity
    # name from another secret.
    identity="$(security find-identity -v -p codesigning "$KEYCHAIN" \
        | grep 'Developer ID Application' \
        | head -n 1 \
        | sed -E 's/^.*"(.*)".*$/\1/')"
    if [ -z "$identity" ]; then
        echo "error: the .p12 holds no Developer ID Application identity" >&2
        security find-identity -v -p codesigning "$KEYCHAIN" >&2
        exit 1
    fi

    echo "==> signing identity: $identity"
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "CODESIGN_IDENTITY=$identity" >> "$GITHUB_ENV"
    else
        echo "warning: GITHUB_ENV is unset; export CODESIGN_IDENTITY yourself" >&2
    fi
}

notarize() {
    require_env APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD
    local zip="${1:?usage: sign-and-notarize.sh notarize <zip>}"
    if [ ! -f "$zip" ]; then
        echo "error: $zip not found; package the app before notarization" >&2
        exit 1
    fi

    echo "==> notarytool submit $zip"
    xcrun notarytool submit "$zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait

    # notarytool can exit 0 for a rejected submission. The staple below fails
    # in that case, so the job still stops.
    echo "==> stapler staple $APP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"

    # A zip carries no ticket of its own, so pack the stapled app again.
    # ponytail: the release asset stays a zip. Ceiling: no DMG and no
    # in-app updater. Upgrade path: build a DMG and notarize that instead.
    echo "==> packing the stapled app into $zip"
    rm -f "$zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"
}

cleanup() {
    if [ -f "$KEYCHAIN" ]; then
        echo "==> deleting temporary keychain $KEYCHAIN"
        security delete-keychain "$KEYCHAIN"
    else
        echo "==> no temporary keychain to delete"
    fi
}

case "${1:-}" in
    import-certificate) import_certificate ;;
    notarize) shift; notarize "$@" ;;
    cleanup) cleanup ;;
    *)
        echo "usage: sign-and-notarize.sh {import-certificate|notarize <zip>|cleanup}" >&2
        exit 2
        ;;
esac
