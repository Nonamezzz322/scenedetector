---
name: release
description: Produce a distributable SceneShot.dmg — run the full build → sign → dmg → notarize(-or-skip) pipeline and verify the artifacts, accounting for the Gatekeeper reality given there is no Apple Developer account. Use when asked to package, make a DMG, or cut a release.
---

# Release SceneShot

1. Run `./Scripts/release.sh` (build.sh → sign.sh → make-dmg.sh → notarize.sh). If a step's script is missing, run the equivalent from `PLAN.md` §8.
2. Verify:
   - `dist/SceneShot.dmg` exists.
   - `codesign --verify --deep --strict --verbose=2 dist/SceneShot.app` passes.
   - `lipo -archs` on the app binary and the bundled ffmpeg shows `arm64 x86_64`.
   - `spctl -a -vv dist/SceneShot.app` — EXPECT rejection while un-notarized; report it as expected, not a failure.
3. Confirm the DMG contains the КАК-ОТКРЫТЬ Gatekeeper instruction.
4. Report: artifact paths/sizes, signing status (ad-hoc vs Developer ID), notarization status, and the exact first-run steps a marketer will face right now. If `APPLE_ID`/`TEAM_ID`/`APP_PASSWORD`/`CODESIGN_IDENTITY` are set, confirm the notarized path was taken.
5. Finally, spawn `release-ux-reviewer` to sanity-check end-user friction.
