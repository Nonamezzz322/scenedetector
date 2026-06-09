#!/usr/bin/env bash
# Notarize + staple the DMG. No-op (exit 0) unless Apple credentials are provided via env:
#   APPLE_ID, TEAM_ID, APP_PASSWORD (app-specific password).
set -euo pipefail

cd "$(dirname "$0")/.."
DMG="dist/SceneShot.dmg"

if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
    echo "нотаризация пропущена (нет APPLE_ID/TEAM_ID/APP_PASSWORD — аккаунт Apple Developer не задан)"
    exit 0
fi
[ -f "$DMG" ] || { echo "ERROR: make the DMG first (./Scripts/make-dmg.sh)" >&2; exit 1; }

echo "submitting $DMG to Apple notary service…"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
xcrun stapler staple "$DMG"
echo "notarized + stapled"
