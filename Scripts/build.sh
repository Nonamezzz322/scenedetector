#!/usr/bin/env bash
# Build SceneShot.app with swiftc + manual bundle assembly.
# Works with Command Line Tools only — no full Xcode required.
# Universal (arm64 + x86_64) by default; FAST=1 builds the host arch only (quicker dev loop).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="SceneShot"
DEPLOY="13.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BUILD="$DIST/.build"

log() { printf '==> %s\n' "$*"; }

command -v swiftc >/dev/null 2>&1 || {
    echo "ERROR: 'swiftc' not found. Install Command Line Tools: xcode-select --install" >&2
    exit 1
}

# Collect sources.
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$ROOT/Sources/$APP_NAME" -name '*.swift' | sort)
[ ${#SRCS[@]} -gt 0 ] || { echo "ERROR: no Swift sources under Sources/$APP_NAME" >&2; exit 1; }

mkdir -p "$BUILD/bin"

# 1) Compile each arch, then lipo into a universal binary.
if [ "${FAST:-0}" = "1" ]; then
    ARCHS=("$(uname -m)")
    log "FAST build: ${ARCHS[*]} only"
else
    ARCHS=(arm64 x86_64)
fi

SLICES=()
for arch in "${ARCHS[@]}"; do
    log "compile $arch"
    OUT="$BUILD/$APP_NAME.$arch"
    swiftc -parse-as-library -O \
        -target "${arch}-apple-macosx${DEPLOY}" \
        -o "$OUT" "${SRCS[@]}"
    SLICES+=("$OUT")
done

UNI="$BUILD/bin/$APP_NAME"
log "lipo (${ARCHS[*]})"
lipo -create "${SLICES[@]}" -output "$UNI"

# 2) Assemble the .app bundle by hand.
log "assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNI" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Bundled ffmpeg/ffprobe (and optional whisper-cli) helpers.
if [ -d "$ROOT/Resources/Helpers" ]; then
    log "bundling helper binaries"
    mkdir -p "$APP/Contents/Resources/Helpers"
    cp -R "$ROOT/Resources/Helpers/." "$APP/Contents/Resources/Helpers/"
    find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' -o -name 'yt-dlp' \) -exec chmod +x {} \;
fi

# Bundled whisper.cpp model (arch-independent data; NOT under Helpers, NOT code-signed separately).
if [ -d "$ROOT/Resources/Models" ]; then
    log "bundling whisper model"
    mkdir -p "$APP/Contents/Resources/Models"
    cp -R "$ROOT/Resources/Models/." "$APP/Contents/Resources/Models/"
fi

# App icon (added in stage 9; optional for now).
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the ffmpeg GPL license / source offer (compliance).
[ -f "$ROOT/Resources/FFMPEG-LICENSE.txt" ] && cp "$ROOT/Resources/FFMPEG-LICENSE.txt" "$APP/Contents/Resources/FFMPEG-LICENSE.txt"
# Bundle the whisper.cpp MIT license + model attribution.
[ -f "$ROOT/Resources/WHISPER-LICENSE.txt" ] && cp "$ROOT/Resources/WHISPER-LICENSE.txt" "$APP/Contents/Resources/WHISPER-LICENSE.txt"

# 3) Ad-hoc codesign. Clear stray extended attributes first — they invalidate the seal and
#    make OTHER Macs report "SceneShot is damaged" (the #1 cause of "won't launch elsewhere").
#    Then sign nested helpers FIRST, then the app bundle, and FAIL the build if the signature
#    isn't valid (a valid signature is what keeps macOS from calling it "damaged").
log "clean xattrs + ad-hoc codesign"
xattr -cr "$APP" 2>/dev/null || true
if [ -d "$APP/Contents/Resources/Helpers" ]; then
    find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' -o -name 'yt-dlp' \) -exec codesign -s - --force {} \;
fi
codesign -s - --force "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

log "done"
echo "app:   $APP"
echo "archs: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
