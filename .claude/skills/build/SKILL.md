---
name: build
description: Build the SceneShot macOS app — regenerate the Xcode project and produce a universal dist/SceneShot.app, surfacing any compile errors/warnings concisely. Use when asked to build, compile, or verify the app still builds.
---

# Build SceneShot

1. If `Scripts/build.sh` exists, run it. Otherwise run `swift build -c release` (universal: add `--arch arm64 --arch x86_64`), then assemble `dist/SceneShot.app` (Contents/MacOS/SceneShot from the built binary + Contents/Info.plist from Resources/Info.plist + Resources/Helpers if present) and ad-hoc codesign.
2. If `swift` is missing, tell the user to install Command Line Tools (`xcode-select --install`) and stop. Full Xcode is NOT needed (and is not installed here).
3. On failure: show the FIRST few compiler errors with `file:line`, not the whole log. Propose the fix; do not auto-rewrite unless asked.
4. On success: confirm `dist/SceneShot.app` exists, print `lipo -archs dist/SceneShot.app/Contents/MacOS/SceneShot` (expect `arm64 x86_64`), and report warnings (target: zero).
