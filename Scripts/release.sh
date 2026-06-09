#!/usr/bin/env bash
# Full release pipeline: build (universal) → sign → dmg → notarize(-or-skip).
set -euo pipefail

cd "$(dirname "$0")/.."
./Scripts/build.sh
./Scripts/sign.sh
./Scripts/make-dmg.sh
./Scripts/notarize.sh

echo "== release artifacts =="
ls -lh dist/SceneShot.dmg 2>/dev/null || true
echo "archs: $(lipo -archs dist/SceneShot.app/Contents/MacOS/SceneShot 2>/dev/null || echo unknown)"
