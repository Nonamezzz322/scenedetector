#!/usr/bin/env bash
# Code-sign SceneShot.app.
#   - default: ad-hoc (works locally, but Gatekeeper warns on other Macs)
#   - CODESIGN_IDENTITY="Developer ID Application: …": hardened runtime + entitlements (notarization-ready)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/SceneShot.app"
ENTITLEMENTS="Resources/SceneShot.entitlements"
[ -d "$APP" ] || { echo "ERROR: build first (./Scripts/build.sh)" >&2; exit 1; }

IDENTITY="${CODESIGN_IDENTITY:--}"

sign() {
    local target="$1"
    if [ "$IDENTITY" = "-" ]; then
        codesign -s - --force "$target"
    elif [ "$target" = "$APP" ] && [ -f "$ENTITLEMENTS" ]; then
        codesign -s "$IDENTITY" --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$target"
    else
        codesign -s "$IDENTITY" --force --options runtime --timestamp "$target"
    fi
}

# Nested helper binaries MUST be signed before the app bundle.
if [ -d "$APP/Contents/Resources/Helpers" ]; then
    while IFS= read -r f; do sign "$f"; done \
        < <(find "$APP/Contents/Resources/Helpers" -type f \( -name ffmpeg -o -name ffprobe -o -name whisper-cli -o -name yt-dlp \))
fi
sign "$APP"

echo "signed with: $([ "$IDENTITY" = "-" ] && echo 'ad-hoc (-)' || echo "$IDENTITY")"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
echo "Gatekeeper (spctl) — rejection is EXPECTED until notarized:"
spctl -a -vv "$APP" 2>&1 | head -2 || true
