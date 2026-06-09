#!/usr/bin/env bash
# Download the standalone yt-dlp_macos binary into Resources/Helpers/yt-dlp.
#
# yt-dlp lets the app accept page URLs (TikTok, Instagram Reels, YouTube, YouTube Shorts) and
# download the underlying video, then SceneShot extracts frames / transcribes it. The yt-dlp_macos
# asset is a PyInstaller "universal2" standalone — it bundles its own Python, so the end user needs
# nothing installed. It uses our already-bundled ffmpeg at runtime (--ffmpeg-location).
#
# NOTE: yt-dlp must be refreshed periodically — sites change their internals and pinned versions rot.
# Bump VERSION and re-pin the sha256 to update. yt-dlp is released under the Unlicense (public domain).
#
# Re-run with FORCE=1 to refresh.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HELPERS="$ROOT/Resources/Helpers"
DEST="$HELPERS/yt-dlp"          # shared universal location (FFmpeg.toolURL falls back here)

VERSION="2026.03.17"
URL="https://github.com/yt-dlp/yt-dlp/releases/download/${VERSION}/yt-dlp_macos"
EXPECTED_SHA256="e80c47b3ce712acee51d5e3d4eace2d181b44d38f1942c3a32e3c7ff53cd9ed5"

log() { printf '==> %s\n' "$*"; }

if [ "${FORCE:-0}" != "1" ] && [ -x "$DEST" ]; then
    log "yt-dlp present (FORCE=1 to refresh)"
else
    mkdir -p "$HELPERS"
    log "download yt-dlp_macos $VERSION"
    curl -fL --retry 3 -m 600 -o "$DEST" "$URL"
    chmod +x "$DEST"
fi

got_sha="$(shasum -a 256 "$DEST" | awk '{print $1}')"
if [ "$EXPECTED_SHA256" = "REPLACE_AFTER_FIRST_FETCH" ]; then
    echo "!! ACTION REQUIRED: pin the yt-dlp sha256 in Scripts/fetch-ytdlp.sh:"
    echo "!!   EXPECTED_SHA256=\"$got_sha\""
elif [ "$EXPECTED_SHA256" != "$got_sha" ]; then
    echo "ERROR: yt-dlp sha256 mismatch" >&2
    echo "  expected $EXPECTED_SHA256" >&2
    echo "  got      $got_sha" >&2
    exit 1
else
    echo "  yt-dlp sha256 OK $got_sha"
fi

log "lipo -info: $(lipo -info "$DEST" 2>/dev/null | sed 's/.*: //' || echo '?')"
log "version check"
"$DEST" --version 2>/dev/null | head -1 || echo "  (cannot run yt-dlp)"
echo "done -> $DEST"
