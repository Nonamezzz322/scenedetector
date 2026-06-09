#!/usr/bin/env bash
# Build dist/SceneShot.dmg. Uses built-in hdiutil (no extra tooling); uses create-dmg if installed.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/SceneShot.app"
DMG="dist/SceneShot.dmg"
[ -d "$APP" ] || { echo "ERROR: build first (./Scripts/build.sh)" >&2; exit 1; }

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[ -f "dmg/КАК-ОТКРЫТЬ.txt" ] && cp "dmg/КАК-ОТКРЫТЬ.txt" "$STAGE/"
[ -f "dmg/КАК-ОТКРЫТЬ.png" ] && cp "dmg/КАК-ОТКРЫТЬ.png" "$STAGE/"
[ -f "Resources/FFMPEG-LICENSE.txt" ] && cp "Resources/FFMPEG-LICENSE.txt" "$STAGE/FFMPEG-LICENSE.txt"
[ -f "Resources/WHISPER-LICENSE.txt" ] && cp "Resources/WHISPER-LICENSE.txt" "$STAGE/WHISPER-LICENSE.txt"

rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1 && [ -f "dmg/background.png" ]; then
    echo "using create-dmg"
    create-dmg --volname "SceneShot" \
        --background "dmg/background.png" \
        --icon "SceneShot.app" 150 190 \
        --app-drop-link 430 190 \
        "$DMG" "$STAGE" \
        || hdiutil create -volname "SceneShot" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
else
    echo "using hdiutil"
    hdiutil create -volname "SceneShot" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

rm -rf "$STAGE"
echo "made $DMG ($(du -h "$DMG" | awk '{print $1}'))"
