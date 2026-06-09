#!/usr/bin/env bash
# Build Resources/AppIcon.icns from Resources/icon-source.png (1024×1024).
# If no source is present, generates a placeholder gradient icon with the bundled ffmpeg.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="Resources/icon-source.png"
OUT="Resources/AppIcon.icns"
FF="Resources/Helpers/$(uname -m)/ffmpeg"

if [ ! -f "$SRC" ]; then
    echo "no $SRC — generating a placeholder gradient icon"
    "$FF" -hide_banner -loglevel error -f lavfi \
        -i "gradients=s=1024x1024:c0=0x2A4DB0:c1=0x8B2FC9" -frames:v 1 -y "$SRC" 2>/dev/null \
    || "$FF" -hide_banner -loglevel error -f lavfi \
        -i "color=c=0x4F46E5:s=1024x1024" -frames:v 1 -y "$SRC"
fi

TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
gen() { sips -z "$2" "$2" "$SRC" --out "$SET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$TMP"
echo "made $OUT"
