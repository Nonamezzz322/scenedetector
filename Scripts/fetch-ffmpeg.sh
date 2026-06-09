#!/usr/bin/env bash
# Download static ffmpeg + ffprobe for macOS arm64 and x86_64 into Resources/Helpers/<arch>/.
#
# Source: https://ffmpeg.martin-riedl.de (macOS static builds, arm64 + amd64, same version).
#
# LICENSE NOTE: these are GPL builds (bundle x264 etc.). SceneShot only DECODES video and writes
# mjpeg/png, so the GPL-only encoders aren't exercised at runtime — but the binary is still
# GPL-licensed. For distribution: ship the build's LICENSE and a written offer for source
# (the provider publishes full sources). To avoid GPL obligations entirely, swap the URLs for an
# LGPL build (decoders + the mjpeg/png encoders are all we need).
#
# Re-run with FORCE=1 to refresh existing binaries.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HELPERS="$ROOT/Resources/Helpers"
# Pinned exact build URLs so the URL and the sha256 below always describe the SAME artifact.
# (The moving /redirect/latest/ path would break verification once upstream advances past 8.1.1.)
VERSION="8.1.1"
url_for() {
    case "$1/$2" in
        arm64/ffmpeg)   echo "https://ffmpeg.martin-riedl.de/download/macos/arm64/1778761665_8.1.1/ffmpeg.zip";;
        arm64/ffprobe)  echo "https://ffmpeg.martin-riedl.de/download/macos/arm64/1778761665_8.1.1/ffprobe.zip";;
        x86_64/ffmpeg)  echo "https://ffmpeg.martin-riedl.de/download/macos/amd64/1778768838_8.1.1/ffmpeg.zip";;
        x86_64/ffprobe) echo "https://ffmpeg.martin-riedl.de/download/macos/amd64/1778768838_8.1.1/ffprobe.zip";;
        *) echo "";;
    esac
}

ARCHS=(arm64 x86_64)

# Pinned sha256 (martin-riedl.de, ffmpeg 8.1.1). If you bump the version, re-pin these.
expected_sha() {
    case "$1/$2" in
        arm64/ffmpeg)   echo "ef4fe121377039053b0d7bed4a9aa46e7912918f5ba6424a1dd155f4eed625b0";;
        arm64/ffprobe)  echo "3ec76ddd72068162294249465c36257d6c1add564f9b078e31e173837832967d";;
        x86_64/ffmpeg)  echo "6a2c2884161d883fbb1ef21a0223475283eb4e381ee870956719f59f32daf74c";;
        x86_64/ffprobe) echo "cb39232c06f663e97917798ed75f7538341367401f9c180f10646193a7a29a54";;
        *) echo "";;
    esac
}

fetch_tool() { # <arch> <tool>
    local arch="$1" tool="$2" url dest tmp bin
    url="$(url_for "$arch" "$tool")"
    [ -n "$url" ] || { echo "ERROR: no URL for $arch/$tool" >&2; exit 1; }
    dest="$HELPERS/$arch/$tool"
    if [ "${FORCE:-0}" != "1" ] && [ -x "$dest" ]; then
        echo "  $arch/$tool present (FORCE=1 to refresh)"
        return
    fi
    mkdir -p "$HELPERS/$arch"
    tmp="$(mktemp -d)"
    echo "  downloading $arch/$tool ..."
    curl -fsSL -m 600 -o "$tmp/$tool.zip" "$url"
    unzip -qo "$tmp/$tool.zip" -d "$tmp"
    bin="$(find "$tmp" -type f -name "$tool" ! -name '*.zip' | head -1)"
    [ -n "$bin" ] || { echo "ERROR: '$tool' not found inside archive" >&2; rm -rf "$tmp"; exit 1; }
    mv "$bin" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp"
}

for arch in "${ARCHS[@]}"; do
    for tool in ffmpeg ffprobe; do
        fetch_tool "$arch" "$tool"
    done
done

echo "== sha256 verify =="
fail=0
for arch in "${ARCHS[@]}"; do
    for tool in ffmpeg ffprobe; do
        f="$HELPERS/$arch/$tool"
        got="$(shasum -a 256 "$f" | awk '{print $1}')"
        want="$(expected_sha "$arch" "$tool")"
        if [ -n "$want" ] && [ "$want" != "$got" ]; then
            printf "  %-7s %-7s MISMATCH\n    expected %s\n    got      %s\n" "$arch" "$tool" "$want" "$got"
            fail=1
        else
            printf "  %-7s %-7s OK %s\n" "$arch" "$tool" "$got"
        fi
    done
done
[ "$fail" = "0" ] || { echo "ERROR: checksum verification failed" >&2; exit 1; }

host="$(uname -m)"
echo "== host ($host) ffmpeg version =="
"$HELPERS/$host/ffmpeg" -hide_banner -version 2>/dev/null | head -1 || echo "  (cannot run host binary)"
echo "done -> $HELPERS"
