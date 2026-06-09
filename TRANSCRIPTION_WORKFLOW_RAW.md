# Транскрипция голоса — сырой результат работы воркфлоу планирования

> Источник: фоновый workflow `transcription-plan` (runId `wf_906c671e-692`), остановлен на фазе Synthesize.

> Успели завершиться: 7 дизайн-агентов (срезы A–G) + 3 скептика-верификатора. Финальный синтез/критику агент не дописал — поэтому ниже сохранены сырые выводы агентов, а готовый план собран отдельно в `TRANSCRIPTION_PLAN.md`.


---


## Вердикты верификаторов (фаза Verify)


Три независимых скептика пытались опровергнуть осуществимость CLT-only сборки whisper.cpp. **Итог: все три — feasible, confidence high.**


### verify-build-3 — feasible: `True`, confidence: `high`


**Рассуждение:**

I adversarially verified the approach against the ACTUAL whisper.cpp v1.7.4 source (GitHub raw was reachable from this machine; HuggingFace was NOT — a 401/29-byte stub — which independently confirms the design's egress claims). The core thesis survives scrutiny, but I found two real corrections, one of them materially important.

GROUNDING CHECKS REPRODUCE EXACTLY:
- `which cmake` -> not found; `git`=/usr/bin/git (2.50.1); `make`=/usr/bin/make (GNU Make 3.81).
- `xcrun --find metal` -> ERROR "not a developer tool or in PATH"; same for `metallib` and `coremlc`. Metal/CoreML toolchains are DECISIVELY ABSENT under CLT.
- `uname -m` -> arm64; macOS 26.5 (25F71); Apple clang 21.0.0; SDK at /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; ld-1267 (fat-capable). Homebrew 5.1.6 at ~/.brew present, but cmake is NOT installed there (no Caskroom/cmake-app, no ~/.brew/bin/cmake).

CONFIRMED (source-verified, not memory):
1. CPU-ONLY AVOIDS THE MISSING TOOLCHAIN — DECISIVELY TRUE. ggml/src/CMakeLists.txt defines `ggml_add_backend(backend)` as `if (${backend_id}) add_subdirectory(...)`. `ggml_add_backend(METAL)` therefore only adds the ggml-metal subdir when GGML_METAL is ON. With -DGGML_METAL=OFF the ggml-metal CMakeLists (which contains BOTH the embed-asm path and the `xcrun -sdk macosx metal/metallib` custom_command) is never configured. So no metal/metallib is ever invoked. CPU build is correct, identical transcripts (same ggml weights/kernels, only GPU offload removed), just slower. SOUND.
2. NO PREBUILT RUNNABLE macOS whisper-cli. GitHub API for releases/tags/v1.7.4 returns tag_name+name only, ZERO browser_download_url assets — even stronger than the design said. Source build is the only deterministic path. CONFIRMED.
3. whisper-cli is the correct target (examples/cli/CMakeLists.txt: `set(TARGET whisper-cli)`). WHISPER_COREML already defaults OFF (top CMakeLists line 85), so -DWHISPER_COREML=OFF is a harmless belt-and-suspenders no-op. BUILD_SHARED_LIBS_DEFAULT is OFF in the standalone case, so static is even the default; the no-@rpath-dylib assertion is sound. Only Accelerate (find_library, a /System framework) + libc++/libSystem get linked — confirmed via ggml-cpu CMakeLists `if(APPLE AND GGML_ACCELERATE) find_library(ACCELERATE_FRAMEWORK Accelerate)` and ggml-blas `find_package(BLAS)`->Accelerate. So `otool -L` will show system frameworks only. The existing repo ffmpeg/ffprobe are per-arch Mach-O with only /usr/lib + /System deps, matching this model.
4. CROSS-COMPILE x86_64 ON arm64 UNDER CLT WORKS — the app already does it (build.sh: swiftc -target ${arch}-apple-macosx13.0 per arch then lipo). SDK is universal; ld-1267 emits fat. Sound.
5. HF SHA CANNOT BE CAPTURED HERE — verified: curl to the pinned HF URL returns HTTP 401, 29 bytes ("Invalid username or password."). The pin-once/verify-always placeholder workflow is the correct adaptation. (Note: the existing fetch-ffmpeg.sh actually hard-codes real shas and hard-fails on mismatch; it does NOT itself implement a REPLACE_AFTER_FIRST_FETCH print-and-continue step — so the whisper script is introducing a NEW first-run-capture nuance, not literally mirroring fetch-ffmpeg.sh. Acceptable, but call it out so the maintainer knows the first run must succeed-then-pin.)
6. Integration points exist exactly as described: FFmpeg.swift resolves Bundle.main/Resources/Helpers/<arch>/<tool> via `#if arch(arm64)` and an isExecutableFile guard (so a FAT binary copied into BOTH arm64 and x86_64 dirs resolves on either host). build.sh copies Resources/Helpers/. into the bundle and chmods ffmpeg/ffprobe (must extend predicate to whisper-cli). sign.sh signs nested Helpers binaries before the app via `find ... ( -name ffmpeg -o -name ffprobe )` (must add `-o -name whisper-cli`); ad-hoc `codesign -s - --force` for default, runtime+timestamp for Developer ID. All accurate.

REFUTATIONS (none fatal; #1 is materially important):
R1 — PRIMARY-vs-FALLBACK x86_64 ISA DIVERGENCE (the real find). The design claims the x86_64 slice is "generic-baseline (SSE/AVX off by default unless GGML_AVX set)." The actual mechanism (ggml/CMakeLists `if (GGML_NATIVE OR NOT GGML_NATIVE_DEFAULT) set(INS_ENB OFF) else set(INS_ENB ON)`): GGML_NATIVE_DEFAULT is ON unless CMAKE_CROSSCOMPILING (which a plain -DCMAKE_OSX_ARCHITECTURES build does NOT set). With -DGGML_NATIVE=OFF and DEFAULT=ON, the predicate is (OFF OR NOT ON)=FALSE -> INS_ENB=ON -> GGML_AVX/AVX2/FMA/F16C DEFAULT ON. Then in ggml-cpu/CMakeLists the x86 ARCH_FLAGS branch is gated `CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64"`:
  - PRIMARY multi-arch ("arm64;x86_64") is NOT STREQUAL "x86_64" (nor "arm64"), and CMAKE_OSX_ARCHITECTURES is non-empty so the CMAKE_SYSTEM_PROCESSOR fallbacks are skipped too -> NEITHER slice gets ANY x86/arm ARCH_FLAGS. Result: x86_64 slice is accidentally baseline-portable (good outcome, wrong stated reason); arm64 still fine (NEON mandatory, Accelerate gated separately at `if(APPLE AND GGML_ACCELERATE)`).
  - LIPO_FALLBACK (-DCMAKE_OSX_ARCHITECTURES=x86_64) DOES match STREQUAL "x86_64" -> with INS_ENB=ON it bakes in AVX2+FMA+F16C (ggml-cpu lines ~207-209 / 226-240: `-mavx2 -mfma -mf16c`). That binary will SIGILL/illegal-instruction on any x86_64 Mac lacking AVX2 (pre-2013 Haswell, some VMs). So primary and fallback emit DIFFERENT x86_64 ISA baselines; the fallback is materially less portable than assumed. The fallback command in the design omits the AVX-disable flags, so this is a latent footgun.
R2 — WRONG REASON FOR REJECTING GGML_METAL_EMBED_LIBRARY (cosmetic). Design says embedding "still requires compiling default.metallib via metal/metallib first." Source shows the EMBED branch uses only sed + enable_language(ASM) + `.incbin` (NO metal/metallib); it is the NON-embed `else()` branch that calls `xcrun metal/metallib`. The conclusion (GGML_METAL=OFF, which makes the embed flag moot) is right; the justification is factually inverted.
Minor: model is 147,951,465 bytes (~141.1 MiB); task's "~150 MB" is loose rounding. Exact-byte pre-check before sha256 is a good cheap guard. Could not byte-verify from here (HF blocked).


**Проверки на машине:**

- which cmake git make:
  cmake -> "cmake not found"
  git   -> /usr/bin/git (2.50.1)
  make  -> /usr/bin/make (GNU Make 3.81)
xcrun --find metal    -> error: unable to find utility "metal", not a developer tool or in PATH
xcrun --find metallib -> error: unable to find utility "metallib", not a developer tool or in PATH
xcrun --find coremlc  -> error: unable to find utility "coremlc", not a developer tool or in PATH
uname -m -> arm64
sw_vers  -> macOS 26.5, build 25F71
clang    -> Apple clang 21.0.0 (clang-2100.1.1.101), target arm64-apple-darwin25.5.0
xcrun --show-sdk-path -> /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
ld -v    -> PROJECT:ld-1267 (fat-capable)
Homebrew: ~/.brew/bin/brew present, Homebrew 5.1.6; cmake NOT installed (no Caskroom/cmake-app, no ~/.brew/bin/cmake) -> `~/.brew/bin/brew install cmake` required.

Egress probes (run here):
  GitHub raw whisper.cpp v1.7.4 CMakeLists -> HTTP 200 (reachable; used for source verification).
  HuggingFace pinned ggml-base.bin URL     -> HTTP 401, 29 bytes "Invalid username or password." (BLOCKED; sha256 not capturable here — confirms design).
  GitHub API releases/tags/v1.7.4          -> returns tag_name+name only, ZERO downloadable assets (no prebuilt macOS CLI).

Existing repo cross-checks:
  Resources/Helpers/{arm64,x86_64}/{ffmpeg,ffprobe} are per-arch (lipo: "Non-fat ... arm64" / "x86_64"), 63-94 MB each; otool -L shows only /usr/lib + /System frameworks (no @rpath dylibs) — matches the static-link target for whisper-cli.
  Sources/SceneShot/Engine/FFmpeg.swift: resolves Bundle.main/Resources/Helpers/<arch>/<tool.rawValue> with `#if arch(arm64)` + isExecutableFile guard -> a FAT whisper-cli copied into BOTH arch dirs resolves on either host (no resolver change needed).
  Scripts/build.sh: copies Resources/Helpers/. into bundle, chmods (-name ffmpeg -o -name ffprobe), ad-hoc signs nested then app — extend both predicates to whisper-cli.
  Scripts/sign.sh: find ... ( -name ffmpeg -o -name ffprobe ) signs nested before app; Developer ID branch adds --options runtime --timestamp — extend predicate to whisper-cli.
  Scripts/fetch-ffmpeg.sh: pins URL+sha and hard-fails on mismatch, but does NOT implement a placeholder first-run-capture; the whisper fetch script's REPLACE_AFTER_FIRST_FETCH workflow is a new variation (fine, but state it).

CMake logic verified at v1.7.4 (the decisive bits):
  ggml/CMakeLists.txt: APPLE -> GGML_METAL_DEFAULT ON; option(GGML_METAL ... ${GGML_METAL_DEFAULT}); option(GGML_METAL_EMBED_LIBRARY ... ${GGML_METAL}); GGML_NATIVE_DEFAULT = OFF iff CMAKE_CROSSCOMPILING else ON; `if (GGML_NATIVE OR NOT GGML_NATIVE_DEFAULT) INS_ENB=OFF else INS_ENB=ON`; GGML_AVX/AVX2/FMA/F16C default ${INS_ENB}.
  ggml/src/CMakeLists.txt: ggml_add_backend(backend) adds subdir only `if (${backend_id})`; ggml_add_backend(METAL) at line 307 -> ggml-metal added ONLY when GGML_METAL=ON.
  ggml/src/ggml-metal/CMakeLists.txt: EMBED branch = sed + enable_language(ASM) + .incbin (NO metal/metallib). NON-embed else branch = `xcrun -sdk macosx metal ... && xcrun -sdk macosx metallib ...`.
  ggml/src/ggml-cpu/CMakeLists.txt: arm64 branch gated `CMAKE_OSX_ARCHITECTURES STREQUAL "arm64"`; x86 branch gated `STREQUAL "x86_64"`. Non-MSVC x86 with GGML_NATIVE OFF + AVX2 ON -> appends -mavx2 -mfma -mf16c. Accelerate linked via `if(APPLE AND GGML_ACCELERATE) find_library(ACCELERATE_FRAMEWORK Accelerate)` (system framework).
  examples/cli/CMakeLists.txt: set(TARGET whisper-cli); links common+whisper. Top CMakeLists: WHISPER_COREML default OFF; BUILD_SHARED_LIBS_DEFAULT OFF (standalone).

**Рекомендованный подход:**

PROCEED with from-source CPU-only universal build, with two concrete fixes. The design is fundamentally correct; apply these:

PREREQUISITE: `~/.brew/bin/brew install cmake` (cmake is absent; git/make present). Acceptable on a dev/build machine; document it as a hard prerequisite in fetch-whisper.sh (fail fast with a clear message if `command -v cmake` is empty, exactly like build.sh does for swiftc).

PRIMARY (multi-arch single configure) — keep, it is the safest baseline. Add explicit AVX-disable flags for determinism and to make the comment match reality (in the multi-arch case they are currently no-ops because the x86 STREQUAL branch is skipped, but pinning them future-proofs against upstream changing the gating):
  WHISPER_REF="v1.7.4"
  git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp "$SRC"
  cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF \
    -DWHISPER_COREML=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DBUILD_SHARED_LIBS=OFF
  cmake --build "$SRC/build" --config Release -j --target whisper-cli
  # Fix the rationale comment: GGML_METAL=OFF makes ggml_add_backend(METAL) skip the whole ggml-metal subdir, so neither metallib NOR the embed-asm path is configured. Do NOT claim embed needs metallib (it does not; embed uses sed+ASM+.incbin). The point is moot under METAL=OFF anyway.

POST-BUILD ASSERTIONS (make the script fail loudly if violated):
  lipo -info "$SRC/build/bin/whisper-cli"            # MUST list: arm64 x86_64
  otool -L "$SRC/build/bin/whisper-cli"              # MUST show only /usr/lib/*, /System/Library/Frameworks/* (Accelerate, libc++, libSystem). Any libwhisper.dylib/libggml*.dylib => static link failed; abort.
  cp "$SRC/build/bin/whisper-cli" Resources/Helpers/arm64/whisper-cli
  cp "$SRC/build/bin/whisper-cli" Resources/Helpers/x86_64/whisper-cli   # fat binary in BOTH dirs; arch-keyed resolver finds it either way
  chmod +x Resources/Helpers/{arm64,x86_64}/whisper-cli

LIPO_FALLBACK (gate behind LIPO_FALLBACK=1) — CRITICAL FIX: the per-arch x86_64 configure DOES hit the `STREQUAL "x86_64"` branch, so with GGML_NATIVE=OFF it would bake in AVX2+FMA+F16C and crash on non-AVX2 x86_64 Macs. You MUST pass the same AVX-disable flags here, or the fallback binary diverges from the primary and is far less portable:
  for A in arm64 x86_64; do
    cmake -S "$SRC" -B "$SRC/build-$A" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=$A \
      -DGGML_METAL=OFF -DWHISPER_COREML=OFF -DGGML_NATIVE=OFF \
      -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF \
      -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
    cmake --build "$SRC/build-$A" -j --target whisper-cli
  done
  lipo -create "$SRC/build-arm64/bin/whisper-cli" "$SRC/build-x86_64/bin/whisper-cli" -output /tmp/whisper-cli-uni
  lipo -info /tmp/whisper-cli-uni   # MUST list: arm64 x86_64
(Alternatively, if you decide AVX2 x86_64 is an acceptable minimum spec, document that explicitly and drop the disable flags from BOTH paths so primary and fallback match — but do not leave them mismatched.)

MODEL: keep the pinned HF URL https://huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.bin. HF is blocked from this build sandbox (verified 401/29-byte stub), so ship EXPECTED_SHA256="REPLACE_AFTER_FIRST_FETCH" plus an exact-byte assert (147,951,465 bytes) as a cheap pre-check; on the maintainer's first real run, print `shasum -a 256`, have them paste it in, and hard-fail (exit 1) on every subsequent mismatch — never silent. Explicitly note in a comment that this first-run-capture step is a deliberate variation on fetch-ffmpeg.sh (which ships pre-pinned shas), so reviewers do not expect identical behavior. Bundle once to Contents/Resources/Models/ggml-base.bin (not per-arch).

LICENSING: add Resources/WHISPER-LICENSE.txt (whisper.cpp MIT + note on OpenAI Whisper base weights MIT, ggml-converted by ggml-org); have build.sh copy it next to FFMPEG-LICENSE.txt. MIT confirmed.

WIRING (this slice fixes the bundle paths; resolver/engine wiring is out of scope but enabled): extend build.sh's two `( -name ffmpeg -o -name ffprobe )` predicates (copy-chmod at line ~66 and ad-hoc sign at line ~78) and sign.sh's `find ... ( -name ffmpeg -o -name ffprobe )` (line 28) to also `-o -name whisper-cli`. No FFmpeg.swift change needed — the fat binary in both arch dirs satisfies the existing `#if arch(arm64)` + isExecutableFile lookup.

SIZE: +~145 MB (whisper-cli fat ~2-4 MB once; model ~141 MiB once). In-band with the existing 63-94 MB ffmpeg/ffprobe per arch.


### verify-build-2 — feasible: `True`, confidence: `high`


**Рассуждение:**

I tried hard to refute this and could not break the core thesis — I proved it by execution rather than trusting docs. The decisive test (clone v1.7.4 + run the EXACT proposed cmake configure/build on this CLT-only machine) produced a working 2.8 MB fat universal whisper-cli with completely clean linkage (only /usr/lib + Accelerate.framework, zero @rpath dylibs), correct minos 13.0 on both slices, that runs and ad-hoc-signs cleanly. The four central claims are all TRUE and now empirically backed: (1) cmake is required and absent, but `brew install cmake` works (~14s) on this dev machine; (2) Metal/metallib are absent under CLT so GGML_METAL=OFF is mandatory, and the CPU build is functionally correct (transcribes; just no GPU accel); (3) x86_64 cross-from-arm64 via CMAKE_OSX_ARCHITECTURES works under CLT (same mechanism the app's own build.sh already uses); (4) no prebuilt universal macOS whisper-cli exists in Releases, so source-build is the only deterministic path. BUILD_SHARED_LIBS=OFF genuinely yields a dependency-free binary — the proposal's strongest and riskiest assertion, and it held.

What I DID find (none fatal):
THREE real gaps:
G1 (the one that actually bites): build.sh has its OWN ad-hoc codesign at line 78 matching only `-name ffmpeg -o -name ffprobe`. The default `./Scripts/build.sh` path (primary dev/build path) would leave the bundled whisper-cli UNSIGNED inside an ad-hoc-signed app, breaking codesign --verify --strict/--deep and Gatekeeper. The proposal only flags sign.sh line 28 and misses build.sh lines 66 (chmod) and 78 (codesign). MUST patch both predicates in build.sh too.
G2 (cosmetic-to-low): build.sh line 66 chmod +x also matches only ffmpeg/ffprobe; the fetch script's chmod +x + cp -R preserves the bit so it survives in practice, but inconsistent.
G3 (honest limitation, correctly handled): exact model byte size + sha256 are unverifiable from this egress-restricted environment; the placeholder REPLACE_AFTER_FIRST_FETCH pattern (mirroring fetch-ffmpeg.sh) is the right mitigation.

TWO cosmetic factual errors in the proposal's prose (do not affect feasibility): (a) 'this is exactly what upstream build-xcframework.sh does' — that script returns 404 at tag v1.7.4 (it exists only on master/newer), so the precedent is real but not at the pinned tag; (b) the otool assertion 'only /usr/lib + /System frameworks' is technically satisfied but the proposal never names Accelerate.framework, which the default GGML_BLAS=ON (Apple vendor) pulls in — a reviewer extending the otool check should expect Accelerate and not flag it as an unexpected dep. Also worth noting v1.7.4 is now stale (current v1.8.6).

Redundant-but-harmless flags: -DGGML_METAL_EMBED_LIBRARY=OFF and -DWHISPER_COREML=OFF (both already defaults given the other settings). The fat-in-both-dirs choice wastes ~2.8 MB vs thin-per-arch — negligible against the 141 MB model, so it's an acceptable simplicity tradeoff, not a defect.

Net: the build/bundle approach is FEASIBLE and correct as designed; it needs the build.sh signing/chmod predicates extended (in addition to sign.sh) and two prose corrections. A CLT-only dev machine CAN produce a working universal whisper-cli + bundled model.


**Проверки на машине:**

- All run on THIS build machine (/Users/anatoliivovchok/Desktop/scenedetector), darwin arm64, macOS 26.5 (25F71):

TOOLCHAIN:
- `which cmake git make`: cmake NOT FOUND; git=/usr/bin/git (2.50.1); make=/usr/bin/make. Confirms proposal. brew present at /Users/anatoliivovchok/.brew (Homebrew 5.1.6). `brew install cmake` SUCCEEDED in ~14s -> cmake 4.3.3 (note: newer than proposal's mention; still built v1.7.4 fine).
- `xcrun --find metal` -> ERROR "unable to find utility metal". `xcrun --find metallib` -> ERROR. CONFIRMS Metal toolchain ABSENT under CLT. GGML_METAL=ON would fail. CPU-only mandatory: VERIFIED.
- `uname -m` -> arm64. clang = Apple clang 21.0.0.

UPSTREAM SOURCE FACTS (fetched live from raw.githubusercontent.com — github egress WORKS, HF egress returns 401/29-byte stub as proposal claims):
- ggml/CMakeLists.txt: line 52 `set(GGML_METAL_DEFAULT ON)` on APPLE; line 166 `option(GGML_METAL ... ${GGML_METAL_DEFAULT})` -> Metal ON by default: VERIFIED.
- line 170 GGML_METAL_EMBED_LIBRARY defaults to ${GGML_METAL} -> disabling METAL auto-disables embed; proposal's explicit -DGGML_METAL_EMBED_LIBRARY=OFF is REDUNDANT (harmless).
- Top CMakeLists: WHISPER_COREML defaults OFF (line 85) -> -DWHISPER_COREML=OFF REDUNDANT (harmless).
- CMAKE_CROSSCOMPILING -> GGML_NATIVE_DEFAULT OFF; line 96 `if(GGML_NATIVE OR NOT GGML_NATIVE_DEFAULT)` gates INS_ENB. With explicit GGML_NATIVE=OFF, AVX/AVX2 OFF -> portable x86_64 baseline: VERIFIED. NOTE: multi-arch alone does NOT set CMAKE_CROSSCOMPILING, so -DGGML_NATIVE=OFF is NECESSARY, not merely 'for determinism'.
- examples/cli/CMakeLists.txt: target IS `whisper-cli` (cli.cpp, links whisper+common): VERIFIED.

EMPIRICAL BUILD (decisive — ran the EXACT proposed primary command, v1.7.4 shallow clone):
- cmake configure with arm64;x86_64 + GGML_METAL=OFF + GGML_NATIVE=OFF + BUILD_SHARED_LIBS=OFF: SUCCEEDED. Logged 'Accelerate framework found', 'Found BLAS: ...Accelerate.framework', 'Unknown architecture' (expected multi-arch CPU-detect quirk, harmless).
- `cmake --build ... --target whisper-cli`: EXIT 0. Built libggml.a, libwhisper.a, libcommon.a (static), then whisper-cli.
- Output binary /tmp/wcpp/build/bin/whisper-cli: 2.8 MB; `file` -> 'Mach-O universal binary with 2 architectures [x86_64][arm64]'; `lipo -info` -> x86_64 arm64.
- `otool -L` BOTH slices: ONLY /usr/lib/libSystem.B.dylib, /usr/lib/libc++.1.dylib, /System/.../Accelerate.framework. ZERO @rpath dylibs. No stray *.dylib anywhere in build tree. Static-link assertion HOLDS.
- `vtool -show-build`: both slices minos 13.0 (deployment target propagated correctly).
- Host arm64 slice runs (`--help`, exit 0).
- `codesign -s - --force` on the fat binary: SUCCEEDED, --verify --strict passes, both slices preserved.
- Thin slice sizes: arm64=1.33MB, x86_64=1.49MB.

MODEL / RELEASES:
- GitHub Releases latest = v1.8.6; assets ONLY: whisper-bin-Win32/x64 (Windows), whisper-blas/cublas (Windows), whisper-*-xcframework.zip (framework, not a CLI), whispercpp.jar. NO standalone universal macOS whisper-cli Mach-O: VERIFIED -> source-build is the only path.
- models/download-ggml-model.sh ships NO sha256/shasum (grep count = 0): VERIFIED -> placeholder pin-once pattern justified.
- HF resolve URL blocked here (401, 29-byte stub) -> exact byte size 147,951,465 and sha256 CANNOT be confirmed from this environment (proposal's stated limitation is accurate; size is consistent with the known ~142 MiB ggml-base.bin but unverified here).
- models/.bin is gitignored on GitHub, so no LFS pointer with size/sha available via GitHub either.

INTEGRATION:
- Sources/SceneShot/Engine/FFmpeg.swift: arch via `#if arch(arm64)` (lines 37-40); toolURL builds Helpers/<arch>/<tool.rawValue> and returns nil unless FileManager.isExecutableFile (line 52): VERIFIED. Fat-in-both-dirs works (each host reads its arch dir; fat contains that slice). Resolver needs NO change.
- FFmpegTool is `enum FFmpegTool: String { case ffmpeg; case ffprobe }` -> a future case must be `case whisperCli = "whisper-cli"` (identifier != filename).
- Existing Helpers are THIN per-arch (arm64/ffmpeg is arm64-only, x86_64/ffmpeg is x86_64-only) — proposal's fat-in-both diverges but is valid.

**Рекомендованный подход:**

SHIP the proposed approach with these concrete fixes (ordered by importance):

1) MUST FIX — extend build.sh, not just sign.sh. The proposal only mentions sign.sh line 28. You MUST also patch build.sh's two predicates so the default ad-hoc build produces a verifiable bundle:
   - Line 66: `find ... \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' \) -exec chmod +x {} \;`
   - Line 78: `find ... \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' \) -exec codesign -s - --force {} \;`
   - sign.sh line 28: add `-o -name whisper-cli` (as proposed). 
   Without the build.sh line-78 change, the bundled whisper-cli is unsigned in the primary build path and codesign --verify --strict/--deep + Gatekeeper fail.

2) Use the EXACT primary command — it is empirically proven on this machine (no Xcode). Keep: -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DGGML_METAL=OFF -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF, target whisper-cli. -DGGML_NATIVE=OFF is NECESSARY (multi-arch does not auto-set CROSSCOMPILING). You may drop -DGGML_METAL_EMBED_LIBRARY=OFF and -DWHISPER_COREML=OFF (already defaults), but keeping them is harmless/defensive — recommend keeping for self-documentation.

3) Correct the otool assertion to ALLOW Accelerate.framework. Default GGML_BLAS=ON (Apple vendor) links /System/.../Accelerate.framework. The verification gate should assert: deps are a SUBSET of {/usr/lib/libSystem.B.dylib, /usr/lib/libc++.1.dylib, /System/Library/Frameworks/Accelerate.framework/...} and contain NO @rpath/@loader_path/non-/usr,/System path. (If you ever want zero Accelerate, add -DGGML_BLAS=OFF — but Accelerate is a always-present system framework, so leaving it ON is fine and faster.)

4) Make cmake required explicitly in fetch-whisper.sh: `command -v cmake >/dev/null || { echo 'ERROR: cmake required. brew install cmake'; exit 1; }`. Optionally prepend the brew bin to PATH so a Homebrew cmake is found.

5) Pin a CURRENT tag. v1.7.4 builds fine but is stale; prefer pinning v1.7.6 or v1.8.x (re-run the same build to re-confirm; the option names verified above are stable across these). Drop the prose claim that the primary command mirrors build-xcframework.sh at the pinned tag (that script is 404 at v1.7.4; only on master). Describe it as 'the standard cmake multi-arch technique' instead.

6) Model: keep the pin-once-verify-always placeholder (REPLACE_AFTER_FIRST_FETCH) exactly as proposed — upstream ships no checksums (verified) and HF is unreachable from restricted environments. Assert the exact byte size as a cheap pre-check, then shasum. The maintainer captures the real sha256 on first successful fetch from a network that can reach HF.

7) Keep the LIPO_FALLBACK=1 path documented (per-arch build + lipo -create) as a safety net — but the primary fat path is proven to work, so it should rarely be needed.

8) Optional polish: fat-in-both-dirs wastes ~2.8 MB vs thin-per-arch. Negligible vs the 141 MB model; keep the simpler single-build-copy-fat approach. Resolver needs NO change (verified arch-keyed + isExecutableFile). When the Transcription slice lands, the enum case must be `case whisperCli = "whisper-cli"` (identifier != on-disk filename).

LICENSING: MIT bundling plan (Resources/WHISPER-LICENSE.txt copied next to FFMPEG-LICENSE.txt) is sound; build.sh already copies FFMPEG-LICENSE.txt at line 73, so add the analogous copy line.


### verify-build-1 — feasible: `True`, confidence: `high`


**Рассуждение:**

VERDICT: The approach is FEASIBLE and technically sound. I tried hard to refute it and every load-bearing technical claim survived verification against the actual v1.7.4 source and this machine. Summary of the adversarial review:

CLAIMS THAT SURVIVED (verified, not just asserted):
1. cmake absent + Homebrew present -> `brew install cmake` is the correct, acceptable one-time dev-box prereq. git+make already present.
2. Metal/metallib absent under CLT -> GGML_METAL=ON WOULD fail at metallib. Verified the source defaults Metal ON on APPLE and that EMBED_LIBRARY follows GGML_METAL, so the design is right that embedding is NOT an escape hatch (it still needs metallib). Disabling Metal entirely is correct. CPU-only build produces identical transcripts (same ggml weights, same decode math) — only slower. For an offline marketer transcribing on the base model this is acceptable.
3. Cross-compiling x86_64 on arm64 under CLT works: the repo ALREADY does it (build.sh compiles both arches via `-target` and lipos them; ffmpeg helpers ship both arches). SDK is universal. Confirmed.
4. Target/binary names exact: `whisper-cli`, output build/bin/whisper-cli. The hardcoded `--target whisper-cli` and copy paths are correct.
5. No official prebuilt universal macOS CLI: CONFIRMED via API (empty assets). Source-build from a pinned tag is the only license-clean, deterministic, trustworthy path for a signed/notarized app.
6. Model: exact byte size (147,951,465) correct; HF really is blocked here (401/29B) so the placeholder-sha pattern is a NECESSITY, and it mirrors the repo's existing fetch-ffmpeg.sh pin-once-verify-always discipline.
7. BUILD_SHARED_LIBS=OFF statically links common+whisper into whisper-cli (default build has no ffmpeg libs), so the binary should have no @rpath dylib deps — matching the ffmpeg precedent. The design's `otool -L` assertion + dylib-bundling fallback is the right safeguard.

REFUTATIONS / CORRECTIONS I FOUND (none fatal, but must be fixed/heeded):
A. INTERNAL CONTRADICTION in the design header "INTEGRATION ... (no resolver change needed)": FALSE as written. FFmpeg.swift's `enum FFmpegTool { case ffmpeg; case ffprobe }` has NO whisper case, and `toolURL` keys off `tool.rawValue`. The existing resolver CANNOT find whisper-cli without code. The design's own body admits a `case whisperCli`/sibling resolver is needed but marks it OUT OF SCOPE. So the BUNDLE PATH mechanics (fat binary into both arch dirs; arch-keyed lookup) are sound, but "no resolver change needed" is wrong — a one-line enum/resolver addition is mandatory in the (separate) transcription slice. Not a blocker for THIS bundling slice, but the wording oversells it.
B. "No prebuilt binaries" is too absolute: third-party prebuilts DO exist (bizenlabs/whisper-cpp-macos-bin, yaklang). But they are non-official, arch-specific (not universal), and the arm64 ones are Metal-linked (runtime Metal dep). For a commercial signed/notarized app, depending on an unvetted third-party binary is a supply-chain DOWNGRADE vs building the pinned official source. So the design's CONCLUSION (build from source) stands; only its phrasing ("there is no prebuilt") should say "no OFFICIAL prebuilt; third-party ones exist but are untrusted/non-universal."
C. PRIMARY single-configure multi-arch path is the more FRAGILE one: the CPU backend's `STREQUAL "arm64"` exact-match means a dual-arch configure hits the "Unknown architecture" branch. It still builds (generic baseline, which is what we want for portability) and the design correctly forces GGML_NATIVE=OFF, but the per-arch+lipo FALLBACK is actually cleaner because each sub-build matches a real arch branch. Recommend PROMOTING per-arch+lipo to primary (it also matches the repo's own build.sh pattern exactly). Low risk either way.
D. The web surfaced a candidate sha256 for ggml-base.bin (60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe). DO NOT hard-pin this from a search snippet — it is unverified against the actual served LFS bytes (which I cannot download here due to the 401). Treat it ONLY as the value the maintainer should EXPECT to see on first real fetch; if `shasum -a 256` prints exactly this, great; if not, investigate before pinning. The honest placeholder remains the correct committed default.
E. Tag freshness: v1.7.4 is two releases behind (v1.7.6 exists). Fine as a deliberate pin, but note it's stale if "latest" was intended.

None of A-E breaks feasibility. A CLT-only dev machine with Homebrew CAN produce a working universal whisper-cli + bundled base model. The only true external prerequisite is `brew install cmake` (one-time), which is reasonable on a developer build host.


**Проверки на машине:**

- RAN ON THIS BUILD MACHINE (darwin 25.5.0 / macOS 26.5 build 25F71):
- `which cmake git make` -> cmake NOT FOUND ; git=/usr/bin/git ; make=/usr/bin/make. CONFIRMS design: cmake must be installed.
- `~/.brew/bin/brew --version` -> Homebrew 5.1.6 PRESENT and on PATH (~/.brew/bin). `brew install cmake` is viable on this dev box. (cmake genuinely absent from ~/.brew/bin today.)
- `xcrun --find metal` -> ERROR "unable to find utility metal". CONFIRMED.
- `xcrun --find metallib` -> ERROR "unable to find utility metallib". CONFIRMED. => Metal shader toolchain ABSENT under CLT; GGML_METAL=ON would fail.
- `uname -m` -> arm64. `clang --version` -> Apple clang 21.0.0, target arm64-apple-darwin25.5.0.
- `git ls-remote --tags ggml-org/whisper.cpp` -> v1.7.4 EXISTS (sha 8a9ad7844...); also v1.7.5, v1.7.6 exist (so v1.7.4 is a deliberately-older pin, not latest). GitHub reachable for clone.
- v1.7.4 ggml/CMakeLists.txt (fetched): VERBATIM `if(APPLE) set(GGML_METAL_DEFAULT ON)`, `option(GGML_METAL "ggml: use Metal" ${GGML_METAL_DEFAULT})`, `option(GGML_METAL_EMBED_LIBRARY "ggml: embed Metal library" ${GGML_METAL})`, `option(GGML_NATIVE ... ${GGML_NATIVE_DEFAULT})` with NATIVE_DEFAULT=OFF when CMAKE_CROSSCOMPILING. CONFIRMS Metal-on-by-default + embed-follows-Metal claims.
- v1.7.4 examples/cli/CMakeLists.txt (fetched): `set(TARGET whisper-cli)` + `add_executable(${TARGET} cli.cpp)` + `target_link_libraries(${TARGET} PRIVATE common whisper ${FFMPEG_LIBRARIES} ${CMAKE_THREAD_LIBS_INIT})`. CONFIRMS target name `whisper-cli` and binary at build/bin/whisper-cli; FFMPEG_LIBRARIES is empty unless WHISPER_FFMPEG=ON (off by default).
- v1.7.4 ggml-cpu CMakeLists: arch detection uses `CMAKE_OSX_ARCHITECTURES STREQUAL "arm64"` (exact-match). For "arm64;x86_64" NEITHER branch matches -> falls to "Unknown architecture" (no -march=native, generic baseline). CONFIRMS portable-baseline claim AND explains why per-arch+lipo fallback is the more robust path.
- Official v1.7.4 release via GitHub API: assets array is EMPTY (only auto tarball_url/zipball_url source archives). CONFIRMS "no official prebuilt macOS CLI artifact." (A web render briefly showed "Assets 2" but the API is authoritative: empty.)
- Model URL HF `resolve/main/ggml-base.bin`: `curl -sIL` -> HTTP/2 401, content-length 29, x-error-message "Invalid username or password." CONFIRMS the "29-byte 401 stub" egress block; real sha256 genuinely uncapturable here.
- Model size: web search corroborates ggml-base.bin = 147951465 bytes (matches design's exact byte assertion); upstream models/README lists base = "142 MiB" (= 141.1 MiB, consistent).
- Existing repo: Resources/Helpers/{arm64,x86_64}/{ffmpeg,ffprobe} present; ffmpeg arm64=61M, x86_64=89M (so a ~141 MiB model bundled ONCE is in-band). `lipo -archs` of existing ffmpeg shows the repo already ships per-arch (NOT fat) helpers. `otool -L` of ffmpeg shows only /usr/lib + /System frameworks (precedent for the dependency-free goal).

**Рекомендованный подход:**

SAFEST CONCRETE PATH (build whisper-cli + bundle model under CLT-only):

PREREQ (fetch script must guard): at top of fetch-whisper.sh, `command -v cmake >/dev/null || { echo "ERROR: cmake required. Run: brew install cmake (Homebrew is at ~/.brew)"; exit 1; }`. Do NOT auto-install; just fail loud with the exact command. git+make already present.

BUILD — make PER-ARCH + LIPO the PRIMARY (it matches the repo's existing build.sh, and each sub-build cleanly matches a real CPU-arch branch; the single dual-arch configure becomes the documented fallback):
  WHISPER_REF="v1.7.4"   # verified to exist; bump deliberately (v1.7.6 is latest)
  git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp "$SRC"
  for A in arm64 x86_64; do
    cmake -S "$SRC" -B "$SRC/build-$A" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
      -DCMAKE_OSX_ARCHITECTURES=$A \
      -DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF \
      -DWHISPER_COREML=OFF -DWHISPER_OPENVINO=OFF \
      -DGGML_NATIVE=OFF \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON \
      -DWHISPER_BUILD_SERVER=OFF -DBUILD_SHARED_LIBS=OFF
    cmake --build "$SRC/build-$A" -j --target whisper-cli
  done
  lipo -create "$SRC/build-arm64/bin/whisper-cli" "$SRC/build-x86_64/bin/whisper-cli" -output /tmp/whisper-cli
  lipo -archs /tmp/whisper-cli   # MUST print: arm64 x86_64
  # HARD ASSERT no external dylib deps (only /usr/lib + /System allowed):
  otool -L /tmp/whisper-cli | tail -n +2 | grep -vE '/usr/lib/|/System/' && { echo "ERROR: unexpected dylib dep"; exit 1; } || true
  install -m 0755 /tmp/whisper-cli Resources/Helpers/arm64/whisper-cli
  install -m 0755 /tmp/whisper-cli Resources/Helpers/x86_64/whisper-cli
(Keep the single-configure `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` variant in a comment as LIPO is the proven path; both work, lipo is less fragile given the STREQUAL exact-match in ggml-cpu.) Note the repo ships PER-ARCH (non-fat) ffmpeg helpers — copying the FAT whisper-cli into both dirs is still fine and keeps the arch-keyed resolver happy.

MODEL: keep the exact-byte pre-check (147951465) then sha256. Commit EXPECTED_SHA256="REPLACE_AFTER_FIRST_FETCH" placeholder; on first real fetch the script prints `shasum -a 256` and the maintainer pastes it; every later run hard-fails on mismatch (mirror fetch-ffmpeg.sh). Add a code COMMENT noting the value the maintainer should EXPECT is 60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe (from public sources, UNVERIFIED here due to the HF 401) — but DO NOT bake it into the active check; verify-on-first-fetch. Bundle once to Contents/Resources/Models/ggml-base.bin.

LICENSING: ship Resources/WHISPER-LICENSE.txt (whisper.cpp MIT + note on MIT-licensed Whisper base weights converted to ggml). build.sh copies it next to FFMPEG-LICENSE.txt.

SIGNING (build.sh + sign.sh): extend BOTH find predicates from `\( -name ffmpeg -o -name ffprobe \)` to `\( -name ffmpeg -o -name ffprobe -o -name whisper-cli \)` so the nested Mach-O is signed BEFORE the .app. Ad-hoc works locally; Developer ID inherits --options runtime/--timestamp.

FLAG TO THE TEAM (do not let this slip): the claim "no resolver change needed" is FALSE. FFmpeg.swift's FFmpegTool enum has only ffmpeg/ffprobe and resolves via tool.rawValue, so the (separate) transcription slice MUST add a whisper case (or a sibling Models/Helpers resolver). This bundling slice only fixes paths; it does not make whisper-cli runnable on its own.

VERIFICATION GATE before declaring success: (1) `lipo -archs` lists both arches; (2) `otool -L` shows zero non-system dylibs on BOTH slices; (3) on the arm64 host, run `Resources/Helpers/arm64/whisper-cli --help` (or transcribe a 5s wav with the bundled model) to prove the CPU-only binary actually runs and transcribes; (4) `codesign --verify --strict` passes on the .app after the find-predicate update.


---


## Дизайн-срезы (фаза Design)


## Срез A-build-bundle


**Измерение:** Acquiring + bundling whisper.cpp (universal arm64+x86_64 CLI) and the ggml base model under Command-Line-Tools-only


**Резюме:** Build whisper-cli FROM SOURCE with cmake (installed via the repo's existing Homebrew at ~/.brew), CPU-ONLY, because Metal shader compilation is impossible under CLT (metal/metallib are absent — confirmed). Produce a universal binary in a SINGLE cmake configure using CMAKE_OSX_ARCHITECTURES="arm64;x86_64" (the exact recipe upstream's build-xcframework.sh uses, but WITHOUT -G Xcode and with GGML_METAL=OFF), with per-arch+lipo as a documented fallback. Bundle it at Contents/Resources/Helpers/<arch>/whisper-cli (note: the universal fat binary is copied into BOTH arch dirs so the existing FFmpeg.swift arch-keyed resolver finds it unchanged). Bundle ggml-base.bin (147,951,465 bytes, ~142 MiB) at Contents/Resources/Models/ggml-base.bin, fetched from huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.bin with pinned-URL + pinned-sha256 verification mirroring fetch-ffmpeg.sh. Add Scripts/fetch-whisper.sh, extend build.sh + sign.sh (sign whisper-cli BEFORE the app), and add Resources/WHISPER-LICENSE.txt (MIT). Prebuilt releases are rejected: whisper.cpp ships no official universal macOS CLI binary, so source build is the only deterministic CLT path.


**Технические детали:**

GROUNDING CHECK RESULTS (run on this build machine):
- `which cmake git make` -> `cmake not found` ; `git` = /usr/bin/git (2.50.1) ; `make` = /usr/bin/make (GNU Make 3.81). => cmake MUST be installed (Homebrew is present at ~/.brew, Homebrew 5.1.6: `brew install cmake`). git+make already available.
- `xcrun --find metal` -> ERROR "unable to find utility \"metal\", not a developer tool or in PATH".
- `xcrun --find metallib` -> ERROR "unable to find utility \"metallib\"...".
  => DECISIVE: Metal shader toolchain is ABSENT under CLT. Any GGML_METAL=ON build will fail at metallib step. Therefore CPU-ONLY (GGML_METAL=OFF) is mandatory. CPU build is functionally correct (same transcripts), just slower — acceptable for offline marketer use on the bundled BASE model.
- `uname -m` -> arm64 (Apple Silicon build host).
- `sw_vers` -> macOS 26.5 (build 25F71). App deployment target stays 13.0.
- Extra: clang = Apple clang 21.0.0; SDK = /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk (universal, supports `-arch x86_64` cross from arm64 host); ld = ld-1267 (emits fat binaries); curl 8.7.1; Homebrew 5.1.6 present.

WHY SOURCE-BUILD, NOT PREBUILT: whisper.cpp GitHub Releases ship source + Windows/xcframework assets, NOT a standalone universal macOS `whisper-cli` Mach-O. There is no pinnable official macOS CLI release artifact, so a from-source cmake build is the only deterministic, license-clean, CLT-compatible path. (xcframework assets are .framework bundles for linking, not a runnable CLI.)

WHY CPU-ONLY WORKS UNDER CLT (the crux): whisper.cpp's ggml/CMakeLists.txt sets `set(GGML_METAL_DEFAULT ON)` on APPLE and `option(GGML_METAL "..." ${GGML_METAL_DEFAULT})` — so Metal is ON BY DEFAULT and would invoke the absent metal/metallib. We override with `-DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF -DWHISPER_COREML=OFF` (Core ML also needs Xcode's coremlc). GGML_METAL_EMBED_LIBRARY is NOT a usable escape hatch here: embedding still requires compiling default.metallib via metal/metallib first, which are missing — so we disable Metal entirely rather than embed it.

UNIVERSAL BUILD STRATEGY (primary): one cmake configure with CMAKE_OSX_ARCHITECTURES="arm64;x86_64" emits a fat binary directly (this is exactly what upstream build-xcframework.sh does for macos: `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`). We drop their `-G Xcode` (needs full Xcode) and use the default Makefile generator. Multi-arch REQUIRES `-DGGML_NATIVE=OFF` (can't apply -march=native to two arches; cmake auto-disables NATIVE when cross/multi-arch but we set it explicitly for determinism). Result: portable generic-baseline x86_64 (SSE/AVX off by default unless GGML_AVX etc. set; fine for correctness). FALLBACK if multi-arch link misbehaves: build each arch in its own build dir (`-DCMAKE_OSX_ARCHITECTURES=arm64` then `=x86_64`) and `lipo -create` the two whisper-cli slices.

EXACT PRIMARY BUILD COMMANDS (fetch-whisper.sh core):
  WHISPER_REF="v1.7.4"   # pin a tag; bump deliberately
  git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp "$SRC"
  cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF \
    -DWHISPER_COREML=OFF \
    -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DBUILD_SHARED_LIBS=OFF
  cmake --build "$SRC/build" --config Release -j --target whisper-cli
  # binary at: "$SRC/build/bin/whisper-cli"  (fat). Copy to BOTH arch dirs:
  cp "$SRC/build/bin/whisper-cli" Resources/Helpers/arm64/whisper-cli
  cp "$SRC/build/bin/whisper-cli" Resources/Helpers/x86_64/whisper-cli
  chmod +x Resources/Helpers/{arm64,x86_64}/whisper-cli
NOTE on BUILD_SHARED_LIBS=OFF: forces static link of ggml/whisper into whisper-cli so the bundled binary has NO @rpath dylib dependency (otherwise cmake builds libwhisper.dylib/libggml*.dylib and whisper-cli would need them co-bundled + install_name fixups). Verify with `otool -L whisper-cli` -> only /usr/lib + /System frameworks. If a future whisper.cpp still emits dylib deps even with static flag, the fallback is to bundle the dylibs next to whisper-cli and patch with install_name_tool -change ... @loader_path/.. — but static is the clean path; assert it.

FALLBACK PER-ARCH+LIPO (document in script comment, gated behind LIPO_FALLBACK=1):
  for A in arm64 x86_64; do
    cmake -S "$SRC" -B "$SRC/build-$A" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=$A \
      -DGGML_METAL=OFF -DWHISPER_COREML=OFF -DGGML_NATIVE=OFF \
      -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
    cmake --build "$SRC/build-$A" -j --target whisper-cli
  done
  lipo -create "$SRC/build-arm64/bin/whisper-cli" "$SRC/build-x86_64/bin/whisper-cli" -output /tmp/whisper-cli-uni
  lipo -info /tmp/whisper-cli-uni   # must list: arm64 x86_64

MODEL (ggml-base.bin):
- Pinned URL: https://huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.bin (LOCKED by task; identical LFS object to the legacy ggerganov/whisper.cpp mirror).
- Size: 147,951,465 bytes (~141.1 MiB; upstream models/README rounds to "142 MiB", task says "~150 MB"). The fetch script asserts exact byte size as a cheap pre-check before sha256.
- sha256 PINNING: whisper.cpp's own download-ggml-model.sh does NOT ship checksums (verified), and this environment's egress proxy blocks HF (returns a 29-byte 401 stub even with sandbox disabled), so the real sha256 cannot be captured from here. MIRROR fetch-ffmpeg.sh's "pin-once-verify-always" pattern: ship EXPECTED_SHA256 as a clearly-marked placeholder "REPLACE_AFTER_FIRST_FETCH"; on first run the maintainer runs the script, it prints the computed `shasum -a 256`, the maintainer pastes it into EXPECTED_SHA256, and EVERY subsequent run hard-fails (exit 1) on mismatch — never silent. Bundle to Contents/Resources/Models/ggml-base.bin.

DISK/SIZE IMPACT: whisper-cli fat binary ~2-4 MB; model ~141 MiB. App grows ~145 MB (precedent: ffmpeg/ffprobe are already 63-93 MB each per arch in this repo, so a 150 MB model is in-band). Model is bundled ONCE (not per-arch).

LICENSING: whisper.cpp = MIT (confirmed). Add Resources/WHISPER-LICENSE.txt containing the whisper.cpp MIT text + a note on the bundled base model (OpenAI Whisper weights, MIT-licensed, converted to ggml by ggml-org). build.sh copies it to Contents/Resources/WHISPER-LICENSE.txt next to the existing FFMPEG-LICENSE.txt copy.

INTEGRATION WITH EXISTING CODE (no resolver change needed): Sources/SceneShot/Engine/FFmpeg.swift resolves Helpers/<arch>/<tool> via Bundle.main using `#if arch(arm64)`. By copying the FAT whisper-cli into BOTH Helpers/arm64 and Helpers/x86_64, the unchanged arch-keyed lookup finds it on either host. The Transcription engine slice (separate) will add a `case whisperCli` to a tool enum (or a sibling resolver) and a Models/ resolver `Bundle.main.resourceURL/Models/ggml-base.bin`; that is OUT OF SCOPE here but the bundle paths are fixed by this slice.

SIGNING ORDER (sign.sh + build.sh): whisper-cli is a nested Mach-O and MUST be codesigned BEFORE the enclosing .app (same rule as ffmpeg/ffprobe). Extend the existing `find ... -name ffmpeg -o -name ffprobe` predicates to also match `-o -name whisper-cli`. Ad-hoc `codesign -s - --force` works; with Developer ID it inherits --options runtime/--timestamp from sign.sh's existing branch.


**Ключевые решения:**

- Build whisper-cli FROM SOURCE via cmake (not prebuilt): whisper.cpp ships no official runnable universal macOS CLI artifact to pin; source build is the only deterministic, license-clean CLT path.
- CPU-ONLY is MANDATORY, not a fallback: metal+metallib are absent under CLT (verified), and GGML_METAL defaults ON on Apple, so we MUST pass -DGGML_METAL=OFF -DWHISPER_COREML=OFF. GGML_METAL_EMBED_LIBRARY is NOT a workaround (it still needs metallib).
- Universal in ONE cmake configure via CMAKE_OSX_ARCHITECTURES="arm64;x86_64" (upstream build-xcframework.sh's exact arch recipe), using the default Makefile generator (NOT -G Xcode which needs full Xcode); per-arch + lipo retained as LIPO_FALLBACK=1.
- Set -DGGML_NATIVE=OFF for the multi-arch build (cannot apply -march=native to two arches); accept generic-baseline x86_64 — correct and portable.
- -DBUILD_SHARED_LIBS=OFF to statically link ggml/whisper into whisper-cli, avoiding @rpath dylib co-bundling and install_name fixups; assert via otool -L.
- Copy the single FAT whisper-cli into BOTH Helpers/arm64 and Helpers/x86_64 so the existing #if-arch resolver in FFmpeg.swift works unchanged on either host (no Swift change in this slice).
- Pin the model by URL (ggml-org as locked) + exact byte size 147,951,465 + sha256; mirror fetch-ffmpeg.sh's pin-on-first-fetch since whisper.cpp publishes no model checksum and this env's network is proxy-blocked.
- Install cmake via the repo's existing Homebrew (~/.brew) inside fetch-whisper.sh; do not assume cmake is preinstalled.
- Do NOT vendor whisper.cpp sources into the repo — clone into a scratch/.build dir; only the built binary + model land in Resources.
- Sign whisper-cli as a nested binary BEFORE the .app in both build.sh and sign.sh (add -o -name whisper-cli to the find predicates); never sign the model data file.

**Риски:**

- sha256 cannot be captured in THIS environment (egress proxy returns a 29-byte 401 stub for HF even with sandbox disabled). Mitigation: ship EXPECTED_SHA256 placeholder; script prints computed hash on first real-network run and the maintainer pins it; hard-fail on every subsequent mismatch (no silent pass).
- GGML_NATIVE=OFF yields a generic-baseline x86_64 binary (no AVX/AVX2 auto-tuning) -> slower on Intel; acceptable for base-model offline use. If speed matters later, build x86_64 separately with -DGGML_AVX2=ON via the lipo fallback.
- Future whisper.cpp versions may rename CMake options or still emit ggml/whisper dylibs despite BUILD_SHARED_LIBS=OFF -> the otool -L assertion catches it; pin WHISPER_REF=v1.7.4 and bump deliberately. Fallback: co-bundle the dylibs and patch with install_name_tool -change @loader_path/..
- Building a fat binary via CMAKE_OSX_ARCHITECTURES compiles every TU twice -> longer build; one-time on the build machine, not in the ship loop. The lipo fallback is there if the single-configure multi-arch link ever fails on a future toolchain.
- App size grows ~145 MB (binary ~3 MB + model ~141 MiB). In-band with existing ffmpeg/ffprobe (63-93 MB each per arch); flag for DMG size but not blocking. Model is bundled once, not per-arch.
- The locked URL host ggml-org/whisper.cpp must remain the canonical LFS mirror; if it ever 404s, the legacy ggerganov/whisper.cpp resolve URL serves the identical object — document as a comment but keep ggml-org per the LOCKED decision.
- whisper-cli CLI flags (e.g. -m, -otxt, -osrt, -of) are consumed by the SEPARATE transcription-engine slice; this slice only guarantees the binary exists, is universal, runs --help, and is signed. Flag wiring is out of scope here.

**Файлы (добавить/изменить):**

- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/fetch-whisper.sh (NEW — clone+cmake CPU-only universal build, lipo fallback, model download with size+sha pin)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/whisper-cli (NEW — fat binary, produced by fetch-whisper.sh)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/x86_64/whisper-cli (NEW — same fat binary)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Models/ggml-base.bin (NEW — 147,951,465 bytes)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/WHISPER-LICENSE.txt (NEW — MIT + model note)
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/build.sh (EDIT — add whisper-cli to chmod/codesign find predicates; copy Resources/Models and WHISPER-LICENSE.txt into the bundle)
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/sign.sh (EDIT — add -o -name whisper-cli to the nested-binary find so it signs before the app)

**Команды:**

```bash
which cmake git make
xcrun --find metal
xcrun --find metallib
uname -m
sw_vers
brew install cmake
git clone --depth 1 --branch v1.7.4 https://github.com/ggml-org/whisper.cpp /tmp/whisper.cpp
cmake -S /tmp/whisper.cpp -B /tmp/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF -DWHISPER_COREML=OFF -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build /tmp/whisper.cpp/build --config Release -j --target whisper-cli
lipo -info /tmp/whisper.cpp/build/bin/whisper-cli
otool -L /tmp/whisper.cpp/build/bin/whisper-cli
/tmp/whisper.cpp/build/bin/whisper-cli --help
curl -fL --retry 3 -o Resources/Models/ggml-base.bin https://huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.bin
stat -f%z Resources/Models/ggml-base.bin
shasum -a 256 Resources/Models/ggml-base.bin
./Scripts/fetch-whisper.sh
./Scripts/build.sh
codesign --verify --strict --verbose=1 dist/SceneShot.app
```

**Черновик промпта для этапа:**


```text
Acquire and bundle a universal (arm64+x86_64) whisper.cpp CLI and the ggml BASE model, building FROM SOURCE under Command Line Tools ONLY (no full Xcode). GROUNDING (already verified on this machine, do not relitigate): `xcrun --find metal` and `xcrun --find metallib` BOTH fail -> Metal shader compilation is impossible under CLT -> the build MUST be CPU-only (GGML_METAL=OFF). cmake is NOT installed but Homebrew IS (at ~/.brew); git+GNU make are present. Host is arm64; the universal SDK at /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk supports cross-compiling x86_64. whisper.cpp is MIT.

1) Create Scripts/fetch-whisper.sh (mirror the structure of Scripts/fetch-ffmpeg.sh exactly: `set -euo pipefail`, `cd "$(dirname "$0")/.."`, FORCE=1 to refresh, pinned refs, sha verification that HARD-FAILS on mismatch, a final host-arch sanity run). It must:
   a) Ensure cmake exists: `command -v cmake >/dev/null 2>&1 || { command -v brew >/dev/null && brew install cmake || { echo 'ERROR: install cmake (brew install cmake)'>&2; exit 1; }; }`.
   b) Pin `WHISPER_REF="v1.7.4"` (a tag). `git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp "$BUILD/whisper.cpp"` into a dist/.build-style scratch dir (gitignore-friendly; do NOT vendor sources into the repo).
   c) PRIMARY universal build (single configure, default Makefile generator — NOT -G Xcode):
      cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF -DWHISPER_COREML=OFF -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
      cmake --build "$SRC/build" --config Release -j --target whisper-cli
      Resulting fat binary: "$SRC/build/bin/whisper-cli". Assert it is statically linked: `otool -L "$SRC/build/bin/whisper-cli"` must show ONLY /usr/lib + /System/Library entries (no libwhisper/libggml dylibs). If dylibs appear, fail with a clear message (do not silently ship a binary with @rpath deps).
      Include, behind `LIPO_FALLBACK=1`, a per-arch path that configures two build dirs (`-DCMAKE_OSX_ARCHITECTURES=arm64` and `=x86_64`, same other flags) then `lipo -create .../build-arm64/bin/whisper-cli .../build-x86_64/bin/whisper-cli -output <fat>`.
   d) Install the fat binary into BOTH arch dirs so the existing arch-keyed resolver in Sources/SceneShot/Engine/FFmpeg.swift finds it on either host: `cp "$FAT" Resources/Helpers/arm64/whisper-cli; cp "$FAT" Resources/Helpers/x86_64/whisper-cli; chmod +x Resources/Helpers/{arm64,x86_64}/whisper-cli`.
   e) Download the model: MODEL_URL="https://huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.bin", dest Resources/Models/ggml-base.bin (mkdir -p Resources/Models). Use `curl -fL --retry 3 -o`. EXPECTED_SIZE=147951465 (assert exact byte count via `stat -f%z` as a cheap pre-check). EXPECTED_SHA256="REPLACE_AFTER_FIRST_FETCH" — on first run print the computed `shasum -a 256` and, while EXPECTED_SHA256 is still the placeholder, print a loud WARNING telling the maintainer to paste the value in; once set, verify and exit 1 on mismatch. (Rationale: whisper.cpp ships no official model checksums, so we pin-on-first-fetch exactly like fetch-ffmpeg.sh.)
   f) Final sanity: run the host-arch binary `Resources/Helpers/$(uname -m)/whisper-cli --help | head -1` and `lipo -info Resources/Helpers/arm64/whisper-cli` (must list `arm64 x86_64`).

2) Add Resources/WHISPER-LICENSE.txt: the whisper.cpp MIT license text, plus a short note that the bundled ggml-base.bin is the OpenAI Whisper base model (MIT) converted to ggml by ggml-org, and that whisper-cli is invoked as a separate process (not linked into the app). Keep it parallel in tone to Resources/FFMPEG-LICENSE.txt.

3) Extend Scripts/build.sh:
   - The existing Helpers copy already recurses; ensure the chmod +x predicate also matches whisper-cli: change `\( -name 'ffmpeg' -o -name 'ffprobe' \)` to `\( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' \)` (both the post-copy chmod and the ad-hoc codesign find).
   - Copy the model: after the Helpers block, `if [ -d "$ROOT/Resources/Models" ]; then mkdir -p "$APP/Contents/Resources/Models"; cp -R "$ROOT/Resources/Models/." "$APP/Contents/Resources/Models/"; fi`.
   - Copy the license: `[ -f "$ROOT/Resources/WHISPER-LICENSE.txt" ] && cp "$ROOT/Resources/WHISPER-LICENSE.txt" "$APP/Contents/Resources/WHISPER-LICENSE.txt"`.

4) Extend Scripts/sign.sh: add `-o -name whisper-cli` to the nested-binary `find` so whisper-cli is signed BEFORE the .app (it already signs nested helpers first, then `sign "$APP"`). Do NOT sign the model (data file).

ACCEPTANCE: ./Scripts/fetch-whisper.sh produces Resources/Helpers/{arm64,x86_64}/whisper-cli (fat, both arches via lipo -info) and Resources/Models/ggml-base.bin (147,951,465 bytes, sha matches pin); `Resources/Helpers/$(uname -m)/whisper-cli --help` exits 0; `otool -L` shows no extra dylib deps; ./Scripts/build.sh still produces dist/SceneShot.app with whisper-cli signed and the model + WHISPER-LICENSE.txt under Contents/Resources/; codesign --verify --strict passes.
```

**Критерии приёмки:**

1) `./Scripts/fetch-whisper.sh` completes with exit 0 on the arm64 build host, installing cmake via brew if absent. 2) `lipo -info Resources/Helpers/arm64/whisper-cli` prints "arm64 x86_64" (and same for x86_64/whisper-cli — they are the identical fat binary). 3) `Resources/Helpers/$(uname -m)/whisper-cli --help` exits 0 and prints usage on the host arch. 4) `otool -L Resources/Helpers/arm64/whisper-cli` lists only /usr/lib and /System/Library frameworks (no libwhisper.dylib/libggml*.dylib — proves static link, no @rpath breakage in the bundle). 5) `stat -f%z Resources/Models/ggml-base.bin` == 147951465 and `shasum -a 256` matches the pinned EXPECTED_SHA256 (after the maintainer fills it on first fetch); the script exits 1 on any mismatch. 6) The build was CPU-only: cmake was invoked with -DGGML_METAL=OFF (no metal/metallib calls, no Metal-related build failure). 7) Resources/WHISPER-LICENSE.txt exists (MIT text + model note). 8) `./Scripts/build.sh` still produces dist/SceneShot.app; `find dist/SceneShot.app -name whisper-cli` shows it under Contents/Resources/Helpers/{arm64,x86_64}/; Contents/Resources/Models/ggml-base.bin and Contents/Resources/WHISPER-LICENSE.txt are present. 9) whisper-cli is codesigned BEFORE the app (sign.sh/build.sh find predicate includes it) and `codesign --verify --strict --verbose=1 dist/SceneShot.app` passes. 10) The fallback path (LIPO_FALLBACK=1) is present in fetch-whisper.sh and documented even if the primary single-configure universal build is used.


---


## Срез B-audio


**Измерение:** Engine: whisper-ready audio extraction from video via bundled ffmpeg (16 kHz mono PCM s16le WAV), with pre-flight no-audio detection, temp lifecycle, and progress.


**Резюме:** This slice adds an AudioExtractor engine that turns any Source (local file or remote URL) into a whisper.cpp-ready WAV (16 kHz, mono, PCM s16le) in a temp file, plus a pre-flight audio-presence check so a silent/no-audio video fails fast with a friendly Russian error instead of wasting an extraction pass.

Key verified facts (tested against the actually-bundled ffmpeg/ffprobe 8.1.1 in Resources/Helpers/):
1. EXACT extraction command works and yields a validated stream (codec_name=pcm_s16le, sample_rate=16000, channels=1, bits_per_sample=16): `ffmpeg -hide_banner -nostdin -i INPUT -vn -ac 1 -ar 16000 -c:a pcm_s16le -progress pipe:1 -y OUT.wav`.
2. `-progress pipe:1` emits the SAME `out_time=HH:MM:SS.micro` / `progress=end` lines on stdout that SceneExtractor.parseProgress already parses — so progress is 100% reuse, no new parser.
3. No-audio detection needs NO new ffprobe call: the EXISTING MediaProbe args (`-show_entries format=duration:stream=index,codec_type,codec_name,...`) already return audio streams in the `streams` array. The fix is to extend MediaProbe.parse to set `hasAudio` (and `audioCodec`) by scanning for `codec_type == "audio"`. Verified: a with-audio mp4 shows an `aac`/`audio` stream; a no-audio mp4 shows only the video stream.

The engine mirrors SceneExtractor's structure exactly (build args, launch via FFmpeg.shared, parse progress from stdout, cancel via Running.cancel(), check exitCode, throw FFmpegError.failed) and mirrors Downloader's temp-file convention (FileManager.default.temporaryDirectory + "sceneshot-<UUID>.wav"). For remote sources it reuses Source.isRemote to inject the same reconnect flags SceneExtractor uses, and honors the same "stream vs download-first" choice already implemented in Downloader.

This slice deliberately does NOT touch UI tabs, whisper invocation, or Settings — it produces a WAV URL and a typed no-audio error for the downstream whisper slice to consume.


**Технические детали:**

FILES TO ADD/CHANGE:

1) NEW: Sources/SceneShot/Engine/AudioExtractor.swift — the engine. Public surface:
   - `enum AudioExtractError: LocalizedError { case noAudio }` with `errorDescription = "В этом видео нет звуковой дорожки — расшифровывать нечего."` (typed error the acceptance criteria require).
   - `struct AudioExtractResult { let wavURL: URL }`.
   - `final class AudioExtractor` with `private var running: FFmpeg.Running?`, `private var cancelled = false`, `func cancel()` (sets cancelled, calls running?.cancel()), and:
     `func extract(source: Source, mediaInfo: MediaInfo, durationSeconds: Double?, onProgress: @escaping (Double) -> Void) async throws -> AudioExtractResult`.

   extract() body:
   - Pre-flight: `guard mediaInfo.hasAudio else { throw AudioExtractError.noAudio }` (uses the flag added in step 2; caller already has MediaInfo from the probing state, so no extra ffprobe needed for the file case). For robustness on remote where MediaInfo may be partial, if `mediaInfo.hasAudio == false` AND we never probed, the caller should probe first — but in the normal job flow MediaInfo is always populated, matching how SceneExtractor receives durationSeconds.
   - Build output URL: `let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("sceneshot-audio-\(UUID().uuidString).wav")` (mirrors Downloader.swift line 104 convention).
   - Build args (mirrors SceneExtractor lines 55-68):
     ```swift
     var args = ["-hide_banner", "-nostdin", "-nostats"]
     if source.isRemote {
         args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
     }
     args += ["-i", source.ffmpegInput]
     args += ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"]
     args += ["-progress", "pipe:1", "-y", wavURL.path]
     ```
     (`-nostdin` added vs SceneExtractor to prevent ffmpeg from consuming the parent's stdin during long remote reads — verified harmless on the bundled build.)
   - Launch via the SAME pattern as SceneExtractor lines 73-94: `withCheckedThrowingContinuation` wrapping `FFmpeg.shared.launch(.ffmpeg, args: args, onStdoutLine: { line in if let p = SceneExtractor.parseProgress(line, duration: durationSeconds) { onProgress(p) } }, onStderrLine: nil, completion: ...)`. Store the Running handle in `self.running`. REUSE `SceneExtractor.parseProgress` (it is `static` and `internal` — directly callable; do NOT duplicate it).
   - After completion: `if cancelled { try? FileManager.default.removeItem(at: wavURL); return ...}` — but since extract throws, model cancel as `throw CancellationError()` after cleanup, OR return via a `cancelled` outcome. To match SceneExtractor which returns `.cancelled`, prefer adding `case cancelled` is overkill here; simplest: if cancelled, `try? FileManager.default.removeItem(at: wavURL); throw CancellationError()`.
   - On non-zero exit: `try? FileManager.default.removeItem(at: wavURL)` (no half-written temp left), then `throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)`.
   - On success: `return AudioExtractResult(wavURL: wavURL)`.

2) CHANGE: Sources/SceneShot/Engine/MediaProbe.swift — add audio fields, NO new ffprobe args needed.
   - Add to `struct MediaInfo`: `var hasAudio: Bool = false` and `var audioCodec: String? = nil`.
   - In `parse(_:)`, after the existing video-stream block (after line 58), add:
     ```swift
     if let streams = root["streams"] as? [[String: Any]],
        let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
         info.hasAudio = true
         info.audioCodec = a["codec_name"] as? String
     }
     ```
   - The existing `probe(_:)` args are UNCHANGED — verified they already emit audio streams.

TEMP LIFECYCLE / CLEANUP (explicit):
- WAV lives in `FileManager.default.temporaryDirectory` (system temp, auto-purged by macOS, not sandboxed so writable).
- AudioExtractor removes its own WAV on cancel and on ffmpeg failure (so no orphan on the error/cancel paths).
- On SUCCESS the WAV URL is returned and OWNED by the caller (the whisper slice). The caller is responsible for deleting it after transcription via `try? FileManager.default.removeItem(at:)` in a defer — this matches how Downloader hands back a temp file the caller must clean (Downloader comment line 102). Document this ownership in a doc-comment on AudioExtractResult.

STREAM vs DOWNLOAD-FIRST REUSE: This engine accepts a Source. The job state machine decides remote handling exactly as for frames: if the user picked "Сначала скачать", the orchestrator runs `Downloader.download(...)` first and passes `.file(downloadedURL)` to AudioExtractor (so reconnect flags are skipped and ffmpeg reads a local file); if "Стримить", it passes the original `.remote(url)` and the reconnect flags above apply. No new download code in this slice — pure reuse of Downloader + Source.

VERIFICATION COMMANDS (run against bundled binary, all PASSED during design):
- Make fixtures: `ffmpeg -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i sine=frequency=440:duration=3 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac with_audio.mp4 -y` and the same without the audio inputs for `no_audio.mp4`.
- Extract: `ffmpeg -hide_banner -nostdin -i with_audio.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le -progress pipe:1 -y out.wav` → prints `out_time=...`/`progress=end`.
- Validate: `ffprobe -v error -print_format json -show_entries stream=codec_name,sample_rate,channels,bits_per_sample out.wav` → must show `pcm_s16le / 16000 / 1 / 16`.
- No-audio: `ffprobe -v error -select_streams a -show_entries stream=index -print_format json no_audio.mp4` → empty `streams` array (this is the manual mirror of the in-app `hasAudio == false` path).


**Ключевые решения:**

- No second ffprobe call for audio detection: the EXISTING MediaProbe args already return audio streams; only extend parse() with a hasAudio flag (verified against bundled ffprobe 8.1.1).
- Progress is 100% reuse: `-progress pipe:1` emits the same out_time=/progress=end stdout lines, so AudioExtractor calls SceneExtractor.parseProgress directly instead of duplicating the parser.
- Exact whisper-mandated format: -ac 1 -ar 16000 -c:a pcm_s16le with -vn; validated output is codec_name=pcm_s16le, sample_rate=16000, channels=1, bits_per_sample=16.
- Temp WAV in FileManager.default.temporaryDirectory as `sceneshot-audio-<UUID>.wav` (same convention as Downloader); deleted on cancel and on ffmpeg failure; on success ownership transfers to the caller (whisper slice) which deletes after transcription.
- Pre-flight no-audio guard throws a TYPED AudioExtractError.noAudio BEFORE launching ffmpeg, giving the friendly Russian message and wasting zero work.
- Remote handling reuses Source.isRemote (same reconnect flags as SceneExtractor) and the existing Downloader for the 'download-first' path — no new networking code; orchestrator passes .file(downloadedURL) for download-first, .remote(url) for stream.
- Added -nostdin (vs SceneExtractor) so ffmpeg never consumes the parent stdin during long remote reads; verified harmless on the bundled build.
- Engine returns only a WAV URL + typed error — intentionally no UI/whisper/Settings coupling, keeping this slice consumable by the downstream whisper slice.

**Риски:**

- MediaInfo.hasAudio is only reliable if the job actually probed the source first. In the normal flow the probing state populates MediaInfo (same as durationSeconds for frames), but if an orchestrator calls extract() with a default/empty MediaInfo it would wrongly throw noAudio. Mitigation: the caller must pass the probed MediaInfo (document this; the frame path already establishes the pattern of passing probe results into the engine).
- Remote ffprobe over a flaky/HEAD-hostile server may return partial JSON and miss the audio stream → false 'no audio'. Mitigation: the download-first path (already in Downloader) probes/extracts a local file; recommend preferring download-first for unreliable remotes (PLAN risk §8 already notes this).
- Whisper.cpp tolerance: it strictly wants 16 kHz mono PCM s16le WAV; we produce exactly that (validated). If a future whisper binary build expects f32 or a WAV header quirk, revisit -c:a (kept explicit precisely so it's easy to change in one place).
- Very long videos create a large WAV (~1.9 MB/min at 16k mono s16le ≈ 115 MB/hr) in temp. Acceptable (temp is auto-purged, not sandboxed), but the caller should delete promptly after transcription; cleanup-on-failure/cancel already prevents orphans on error paths.

**Файлы (добавить/изменить):**

- Sources/SceneShot/Engine/AudioExtractor.swift (NEW — engine producing 16k mono PCM s16le WAV from a Source, mirroring SceneExtractor; reuses SceneExtractor.parseProgress, FFmpeg.shared.launch, FFmpegError; temp WAV in FileManager.default.temporaryDirectory with cleanup on cancel/failure)
- Sources/SceneShot/Engine/MediaProbe.swift (CHANGE — add `hasAudio: Bool` and `audioCodec: String?` to MediaInfo; extend parse() to scan streams for codec_type=="audio". ffprobe args UNCHANGED — they already return audio streams)

**Команды:**

```bash
ffmpeg -hide_banner -nostdin -i INPUT -vn -ac 1 -ar 16000 -c:a pcm_s16le -progress pipe:1 -y OUT.wav   # core extraction (remote: prepend -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 before -i)
ffprobe -v error -print_format json -show_entries stream=codec_name,sample_rate,channels,bits_per_sample OUT.wav   # validate: pcm_s16le / 16000 / 1 / 16
ffprobe -v error -select_streams a -show_entries stream=index -print_format json NO_AUDIO.mp4   # manual mirror of hasAudio==false: empty streams array
ffmpeg -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i sine=frequency=440:duration=3 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac with_audio.mp4 -y   # build with-audio fixture
ffmpeg -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -c:v libx264 -pix_fmt yuv420p no_audio.mp4 -y   # build no-audio fixture
./Scripts/build.sh   # builds dist/SceneShot.app, must be warning-free
```

**Черновик промпта для этапа:**


```text
Реализуй извлечение аудио для расшифровки (whisper) из видео встроенным ffmpeg. Это движок: на вход Source (файл или прямая ссылка), на выход — путь к временному WAV 16 кГц / моно / PCM s16le (требование whisper.cpp). НЕ трогай UI-вкладки, вызов whisper и Settings — только движок и расширение MediaProbe.

ИЗУЧИ перед началом: Sources/SceneShot/Engine/FFmpeg.swift (запуск Process, FFmpeg.shared.launch, Running.cancel, FFmpegError), Sources/SceneShot/Engine/SceneExtractor.swift (паттерн движка: сборка args, launch через continuation, парс прогресса, отмена, проверка exitCode — будешь переиспользовать его static parseProgress), Sources/SceneShot/Engine/MediaProbe.swift (MediaInfo + parse), Sources/SceneShot/Engine/Downloader.swift (соглашение про temp-файл: FileManager.default.temporaryDirectory + "sceneshot-<UUID>"), Sources/SceneShot/Models/Source.swift (isRemote, ffmpegInput).

ВАЖНЫЙ ФАКТ (проверено на реально вшитом ffprobe 8.1.1): текущие аргументы MediaProbe (`-show_entries format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate`) УЖЕ возвращают аудио-потоки в массиве streams. Поэтому НЕ добавляй второй вызов ffprobe и не меняй аргументы — только дополни parse.

1) Измени Sources/SceneShot/Engine/MediaProbe.swift:
   - В struct MediaInfo добавь: `var hasAudio: Bool = false` и `var audioCodec: String? = nil`.
   - В функции parse(_:), после блока, который ищет video-стрим, добавь поиск audio-стрима:
     ```swift
     if let streams = root["streams"] as? [[String: Any]],
        let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
         info.hasAudio = true
         info.audioCodec = a["codec_name"] as? String
     }
     ```
   - Аргументы probe(_:) НЕ меняй.

2) Создай Sources/SceneShot/Engine/AudioExtractor.swift:
   ```swift
   import Foundation

   enum AudioExtractError: LocalizedError {
       case noAudio
       var errorDescription: String? {
           switch self {
           case .noAudio:
               return "В этом видео нет звуковой дорожки — расшифровывать нечего."
           }
       }
   }

   /// Путь к временному WAV (16 кГц/моно/PCM s16le), готовому для whisper.cpp.
   /// ВЛАДЕНИЕ: после успешной расшифровки вызывающий ОБЯЗАН удалить файл
   /// (try? FileManager.default.removeItem(at: wavURL)), как и с temp-файлом Downloader.
   struct AudioExtractResult {
       let wavURL: URL
   }

   /// Извлекает аудио из видео встроенным ffmpeg в WAV для whisper.
   /// Зеркалит структуру SceneExtractor: сборка args, launch, парс прогресса, отмена.
   final class AudioExtractor {
       private var running: FFmpeg.Running?
       private var cancelled = false

       func cancel() {
           cancelled = true
           running?.cancel()
       }

       func extract(
           source: Source,
           mediaInfo: MediaInfo,
           durationSeconds: Double?,
           onProgress: @escaping (Double) -> Void
       ) async throws -> AudioExtractResult {
           cancelled = false

           // Пред-проверка: нет звука → понятная ошибка ДО запуска ffmpeg.
           guard mediaInfo.hasAudio else { throw AudioExtractError.noAudio }

           let wavURL = FileManager.default.temporaryDirectory
               .appendingPathComponent("sceneshot-audio-\(UUID().uuidString).wav")

           var args = ["-hide_banner", "-nostdin", "-nostats"]
           if source.isRemote {
               args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
           }
           args += ["-i", source.ffmpegInput]
           args += ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"]
           args += ["-progress", "pipe:1", "-y", wavURL.path]

           let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
               self.running = FFmpeg.shared.launch(
                   .ffmpeg,
                   args: args,
                   onStdoutLine: { line in
                       if let p = SceneExtractor.parseProgress(line, duration: durationSeconds) {
                           onProgress(p)
                       }
                   },
                   onStderrLine: nil,
                   completion: { res in
                       switch res {
                       case .success(let r): cont.resume(returning: r)
                       case .failure(let e): cont.resume(throwing: e)
                       }
                   }
               )
           }

           if cancelled {
               try? FileManager.default.removeItem(at: wavURL)
               throw CancellationError()
           }
           guard result.exitCode == 0 else {
               try? FileManager.default.removeItem(at: wavURL)
               throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)
           }
           return AudioExtractResult(wavURL: wavURL)
       }
   }
   ```

Замечания:
- Переиспользуй SceneExtractor.parseProgress (static, internal) — НЕ дублируй парсер. `-progress pipe:1` пишет в stdout те же строки out_time=/progress=end, что и при извлечении кадров (проверено).
- `-nostdin` нужен, чтобы ffmpeg не перехватывал stdin при долгом чтении remote; на вшитой сборке безопасен.
- Temp-файл удаляется при отмене и при ненулевом коде ffmpeg (никаких недописанных хвостов). При успехе файл возвращается и принадлежит вызывающему (слою whisper), который удалит его через defer после расшифровки.
- Поток vs «сначала скачать» решает оркестратор задачи как для кадров: при «Сначала скачать» сначала Downloader.download(...), затем передай в extract `.file(скачанныйURL)` (флаги reconnect не сработают); при «Стримить» передай исходный `.remote(url)` (reconnect-флаги применятся). Новый код скачивания не пиши.

После реализации собери `./Scripts/build.sh` без ворнингов.

КРИТЕРИЙ ПРИЁМКИ (см. ниже acceptanceCriteria) — выполни ОБА сценария на вшитом бинарнике.
```

**Критерии приёмки:**

1) Сборка `./Scripts/build.sh` проходит без ворнингов; AudioExtractor.swift компилируется, MediaProbe расширен полями hasAudio/audioCodec.

2) 16k mono WAV реально создаётся и валидируется (проверено вручную тем же ffmpeg/ffprobe, что вшит в Resources/Helpers/<arch>/):
   - Фикстура с аудио: `ffmpeg -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i sine=frequency=440:duration=3 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac with_audio.mp4 -y`
   - Команда движка: `ffmpeg -hide_banner -nostdin -i with_audio.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le -progress pipe:1 -y out.wav` → в stdout видны строки `out_time=...` и `progress=end`.
   - Валидация: `ffprobe -v error -print_format json -show_entries stream=codec_name,sample_rate,channels,bits_per_sample out.wav` → ровно один audio-стрим с `codec_name=pcm_s16le`, `sample_rate=16000`, `channels=1`, `bits_per_sample=16`. (Подтверждено при проектировании.)

3) Видео без звука даёт ТИПИЗИРОВАННУЮ ошибку:
   - Фикстура без аудио: `ffmpeg -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -c:v libx264 -pix_fmt yuv420p no_audio.mp4 -y`
   - MediaProbe.parse на её ffprobe-выводе даёт `hasAudio == false` (в массиве streams нет codec_type=="audio" — подтверждено: `ffprobe -v error -select_streams a -show_entries stream=index -print_format json no_audio.mp4` возвращает пустой массив streams).
   - AudioExtractor.extract бросает `AudioExtractError.noAudio` ДО запуска ffmpeg; errorDescription == "В этом видео нет звуковой дорожки — расшифровывать нечего." Никакого WAV не создаётся, работа не тратится.

4) Temp-гигиена: при ненулевом коде ffmpeg и при отмене временный WAV удаляется (orphan-файлов в temporaryDirectory не остаётся); при успехе путь к WAV возвращается вызывающему, который обязан его удалить после расшифровки.


---


## Срез C-engine


**Измерение:** WhisperEngine wrapper + generalizing the bundled-tool Process runner


**Резюме:** Add whisper.cpp transcription by (1) a ONE-LINE generalization of the existing deadlock-safe runner — add `case whisper = "whisper-cli"` to the `FFmpegTool` enum in Sources/SceneShot/Engine/FFmpeg.swift, which automatically resolves Contents/Resources/Helpers/<arch>/whisper-cli via the existing toolURL() and runs it through the unchanged launch() (DispatchGroup + concurrent stdout/stderr draining) — and (2) a new Sources/SceneShot/Engine/WhisperEngine.swift mirroring SceneExtractor.swift. The engine first transcodes the source to 16 kHz mono PCM-s16le WAV via FFmpeg.shared.run(.ffmpeg,...) (whisper.cpp requires this), then launches whisper-cli with `-m <model> -f <wav> -l <auto|ru|en> -otxt -osrt -of <outbase> -t <cores> -pp`, parses progress from the stderr marker `whisper_print_progress_callback: progress = N%` (N/100 → 0..1; with a segment-timestamp `[hh:mm:ss.fff --> …]` ÷ wav-duration fallback), cancels via running.cancel() (terminate()), and collects the produced <outbase>.txt / <outbase>.srt. No other engine file (MediaProbe, SceneExtractor, Downloader) changes. The model and whisper-cli binaries get bundled the same way ffmpeg is.


**Технические детали:**

RUNNER GENERALIZATION (minimal, zero-risk): In Sources/SceneShot/Engine/FFmpeg.swift the enum is `enum FFmpegTool: String { case ffmpeg; case ffprobe }`. Add `case whisper = "whisper-cli"`. That is the ONLY change to FFmpeg.swift. Why it suffices: toolURL(_:) already builds `resourceURL/Helpers/<arch>/<tool.rawValue>` and checks isExecutableFile — with rawValue "whisper-cli" it resolves Helpers/arm64/whisper-cli (or x86_64). launch(_:args:onStdoutLine:onStderrLine:completion:) is already tool-agnostic: it only uses `toolURL(tool)` for the executable and `tool.rawValue` for the toolMissing error string ("Не найден встроенный whisper-cli…"), and the DispatchGroup (3 enters: stdout EOF, stderr EOF, terminationHandler) + per-pipe readabilityHandler draining are untouched, so the deadlock-safe semantics are preserved verbatim. `FFmpeg.shared.run(.whisper, args:)` (the async convenience) also works unchanged. (Rejected alternative: renaming FFmpegTool→Tool / adding a separate toolURL(named:) — it would ripple through MediaProbe/SceneExtractor/Downloader call sites for no functional gain; a third enum case is the smallest correct change and keeps one runner.)

WHISPER.CPP FACTS (whisper-cli is the renamed `main`; build/bin/whisper-cli): it ONLY accepts 16 kHz mono PCM WAV. So step 1 transcodes via ffmpeg. Step 2 args (array, no shell quoting):
  -m <modelPath> -f <wavPath> -l <lang> -otxt -osrt -of <outBaseNoExt> -t <threads> -pp
- `-otxt`/`-osrt` write `<outBase>.txt`/`<outBase>.srt`; `-of` is the basename WITHOUT extension.
- `-pp` (alias --print-progress) forces periodic stderr line: `whisper_print_progress_callback:  progress =  42%`.
- Segment lines (stdout by default) look like: `[00:00:01.480 --> 00:00:04.000]   Привет, это тест.`

PROGRESS PARSING (primary marker on STDERR): regex `progress\s*=\s*(\d+)%` → Double(group)/100.0 → clamp 0..1. This is self-contained (no duration needed). Fallback (segment timestamps, robust if -pp output ever differs): match `\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s*-->`, take the START timestamp seconds = h*3600+m*60+s+ms/1000, divide by the WAV duration (from MediaProbe.probe(wavPath).durationSeconds or the known source duration), clamp 0..1. Mirror SceneExtractor's parseHMS exactly. Wire BOTH: onStderrLine tries parseWhisperPercent first, else parseSegmentStart÷duration; onStdoutLine also runs the segment fallback (covers builds that print segments to stdout).

LANGUAGE: enum TranscriptLanguage { case auto="auto", ru="ru", en="en" } → pass rawValue to `-l`. Default `.auto` (whisper detects ru/en/etc). Marketers can force ru/en in the «Транскрипция» tab.
THREADS: default `ProcessInfo.processInfo.activeProcessorCount` (== logical cores), passed as `-t <n>`. Clamp to >=1.

MODEL PATH: bundled like ffmpeg, but arch-independent (a .bin data file). Put ggml-base.bin under Resources/Models/ggml-base.bin and resolve via `Bundle.main.url(forResource: "ggml-base", withExtension: "bin", subdirectory: "Models")` (or resourceURL + "Models/ggml-base.bin"). build.sh copies Resources/Models → Contents/Resources/Models (NOT per-arch, since the model is identical for both slices).

WAV TEMP: write to FileManager.default.temporaryDirectory.appendingPathComponent("sceneshot-\(UUID().uuidString).wav") (mirrors Downloader's temp naming). ffmpeg args: ["-hide_banner","-nostats","-y","-i", source.ffmpegInput, "-vn","-ac","1","-ar","16000","-c:a","pcm_s16le", wavURL.path] (+ reconnect flags before -i when source.isRemote, copied from SceneExtractor). Delete the WAV in a defer/cleanup after whisper finishes.

CANCEL: store `private var running: FFmpeg.Running?` + `private var cancelled = false`; cancel() sets cancelled=true and running?.cancel() (process.terminate()). Also cancel the in-flight ffmpeg transcode: keep its Running too (transcodeRunning), terminate it on cancel. After the continuation resumes, `if cancelled { return .cancelled }` before reading exit code — exactly SceneExtractor's pattern.

OUTPUT COLLECTION: outBase = outputDir/<sanitized sourceName> (no extension). After whisper exits 0, verify FileManager fileExists for outBase+".txt" and outBase+".srt"; return TranscribeOutcome.done(txt: URL, srt: URL, outputDir: URL). If both missing → .empty(outputDir). whisper-cli exit!=0 → throw FFmpegError.failed(code:stderr:) (reuses existing error; raw stderr stays in the technical log, human copy is generic).


**Ключевые решения:**

- Generalize the runner with a THIRD enum case (case whisper = "whisper-cli") instead of renaming FFmpegTool or adding toolURL(named:): toolURL/launch are already tool-agnostic and key off rawValue, so one line preserves the deadlock-safe DispatchGroup+concurrent-drain behavior with zero ripple into MediaProbe/SceneExtractor/Downloader.
- whisper.cpp requires 16 kHz mono PCM-s16le WAV, so WhisperEngine runs a mandatory ffmpeg transcode step first (reusing FFmpeg.shared.run(.ffmpeg,...)) into a temp WAV (Downloader-style sceneshot-<UUID> naming) deleted via defer.
- Primary progress marker is the STDERR line from -pp: `whisper_print_progress_callback: progress = N%` -> N/100 (self-contained, no duration math). Segment-timestamp `[hh:mm:ss.fff --> …]` start ÷ WAV-duration is the fallback and is also wired on stdout (some builds emit segments there).
- Use -pp (alias --print-progress) to force the percent lines; -otxt -osrt -of <base> writes <base>.txt/.srt; -of takes a basename WITHOUT extension.
- Bundle ggml-base.bin under Resources/Models (arch-independent data), copied by build.sh to Contents/Resources/Models — NOT under per-arch Helpers; resolve via Bundle.main.resourceURL + Models/ggml-base.bin. The model is covered by the app-bundle signature; only the whisper-cli binaries need explicit pre-signing.
- Language default = .auto (whisper auto-detects ru/en); user may force ru/en. Threads default = ProcessInfo.processInfo.activeProcessorCount (>=1).
- Reuse existing FFmpegError (.toolMissing/.failed) for missing binary/model and non-zero exit, keeping raw stderr out of the user's face (technical log only), consistent with SceneExtractor.

**Риски:**

- whisper.cpp binary/flag drift: very old builds used the name `main` and `--print-progress` only (no `-pp` alias); pin the same whisper.cpp release in the sibling fetch slice and verify `whisper-cli -h` lists -pp/-otxt/-osrt/-of. If the percent line format ever changes, the segment-timestamp fallback still advances progress.
- If a source has NO audio stream, the ffmpeg WAV transcode exits non-zero — surface as a human message in the «Транскрипция» tab («в файле нет звуковой дорожки») rather than a raw failure; the engine throws FFmpegError.failed which the UI must translate.
- Model size (~150 MB) inflates the .app and DMG; ensure .gitignore/LFS strategy for ggml-base.bin is handled by the bundling/packaging slice (out of scope here) so the repo stays usable.
- On cancel during the ffmpeg transcode phase, only transcodeRunning exists (running is nil) — cancel() must terminate whichever handle is live; both are nil-checked. Partial .txt/.srt from a terminated whisper must NOT be reported as .done (guarded by the `if cancelled { return .cancelled }` check before fileExists).
- activeProcessorCount returns logical cores (incl. hyperthreads on Intel); on some machines whisper is faster with physical-core count, but logical-core default is a safe, simple baseline and user-tunable later.

**Файлы (добавить/изменить):**

- Sources/SceneShot/Engine/FFmpeg.swift (add one enum case: case whisper = "whisper-cli")
- Sources/SceneShot/Engine/WhisperEngine.swift (NEW — mirrors SceneExtractor.swift)
- Scripts/build.sh (copy Resources/Models -> Contents/Resources/Models; add -o -name 'whisper-cli' to the Helpers chmod+x and codesign find expressions)
- Scripts/sign.sh (add -o -name whisper-cli to the nested-binary find)
- Resources/Helpers/arm64/whisper-cli + Resources/Helpers/x86_64/whisper-cli (binaries, provided by the sibling fetch slice — consumed here)
- Resources/Models/ggml-base.bin (model, provided by the sibling fetch slice — consumed here)

**Команды:**

```bash
./Scripts/build.sh    # or FAST=1 ./Scripts/build.sh for host-arch dev loop
ffmpeg -hide_banner -nostats -y -i INPUT.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le /tmp/t.wav    # mirrors the engine's transcode step
Resources/Helpers/$(uname -m)/whisper-cli -m Resources/Models/ggml-base.bin -f /tmp/t.wav -l auto -otxt -osrt -of /tmp/out -t $(sysctl -n hw.ncpu) -pp    # expect /tmp/out.txt + /tmp/out.srt and stderr 'progress =  NN%'
ls -l /tmp/out.txt /tmp/out.srt    # verify both outputs exist
Resources/Helpers/$(uname -m)/whisper-cli -h | grep -E 'print-progress|otxt|osrt| -of '    # confirm flag names in the bundled build
```

**Черновик промпта для этапа:**


```text
Реализуй движок транскрипции на whisper.cpp, обобщив существующий запускатель процессов. НИЧЕГО не ломай в дедлок-безопасном draining.

ФАЙЛ 1 — Sources/SceneShot/Engine/FFmpeg.swift (МИНИМАЛЬНАЯ правка, одна строка):
В enum `FFmpegTool: String { case ffmpeg; case ffprobe }` добавь третий кейс:
    case whisper = "whisper-cli"
Больше В ЭТОМ ФАЙЛЕ НИЧЕГО не меняй. Проверь логику: toolURL(_:) уже строит resourceURL/Helpers/<arch>/<tool.rawValue> и проверяет isExecutableFile — для rawValue "whisper-cli" это даст Helpers/arm64/whisper-cli (или x86_64). launch(...) и async run(...) уже tool-agnostic (используют toolURL(tool) и tool.rawValue только в сообщении об ошибке), DispatchGroup (3 enter: stdout EOF, stderr EOF, terminationHandler) и readabilityHandler-дренаж остаются как есть. Значит `FFmpeg.shared.launch(.whisper, …)` и `FFmpeg.shared.run(.whisper, …)` работают без других правок.

ФАЙЛ 2 — Sources/SceneShot/Engine/WhisperEngine.swift (НОВЫЙ, зеркалит SceneExtractor.swift):
Типы:
    enum TranscriptLanguage: String, CaseIterable { case auto, ru, en }
    struct TranscribeParams { var language: TranscriptLanguage = .auto; var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount); var sourceName: String = "audio" }
    enum TranscribeOutcome { case done(txt: URL, srt: URL, outputDir: URL); case empty(outputDir: URL); case cancelled }
Класс `final class WhisperEngine` с `private var running: FFmpeg.Running?`, `private var transcodeRunning: FFmpeg.Running?`, `private var cancelled = false`, и `func cancel() { cancelled = true; transcodeRunning?.cancel(); running?.cancel() }`.

Модель: 
    static func modelURL() -> URL? { Bundle.main.resourceURL?.appendingPathComponent("Models/ggml-base.bin") } — верни nil, если файла нет (FileManager.fileExists). Если nil → throw FFmpegError.toolMissing("модель транскрипции").

Метод:
    func transcribe(source: Source, outputDir: URL, params: TranscribeParams, durationSeconds: Double?, onProgress: @escaping (Double) -> Void) async throws -> TranscribeOutcome

Шаги:
1) cancelled = false; createDirectory(outputDir, withIntermediateDirectories: true).
2) Перекодируй звук в WAV 16 кГц моно PCM s16le (whisper.cpp принимает ТОЛЬКО такой WAV):
   let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("sceneshot-\(UUID().uuidString).wav")
   defer { try? FileManager.default.removeItem(at: wavURL) }
   var ffArgs = ["-hide_banner","-nostats","-y"]
   if source.isRemote { ffArgs += ["-reconnect","1","-reconnect_streamed","1","-reconnect_delay_max","5"] }
   ffArgs += ["-i", source.ffmpegInput, "-vn","-ac","1","-ar","16000","-c:a","pcm_s16le", wavURL.path]
   Запусти через FFmpeg.shared.launch(.ffmpeg, args: ffArgs, completion:) внутри withCheckedThrowingContinuation, сохрани handle в self.transcodeRunning, чтобы cancel() мог его terminate(). После: if cancelled { return .cancelled }; guard exitCode==0 else { throw FFmpegError.failed(code:…, stderr:…) }.
   Длительность WAV для прогресса-фолбэка: wavDuration = durationSeconds ?? (try? await MediaProbe.probe(wavURL.path))?.durationSeconds.
3) Запусти whisper-cli:
   guard let model = Self.modelURL() else { throw FFmpegError.toolMissing("модель транскрипции") }
   let outBase = outputDir.appendingPathComponent(Self.sanitize(params.sourceName)) // БЕЗ расширения
   let wargs = ["-m", model.path, "-f", wavURL.path, "-l", params.language.rawValue, "-otxt", "-osrt", "-of", outBase.path, "-t", String(params.threads), "-pp"]
   let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
       self.running = FFmpeg.shared.launch(.whisper, args: wargs,
         onStdoutLine: { line in if let p = Self.parseSegmentProgress(line, duration: wavDuration) { onProgress(p) } },
         onStderrLine: { line in if let p = Self.parsePercent(line) { onProgress(p) } else if let p = Self.parseSegmentProgress(line, duration: wavDuration) { onProgress(p) } },
         completion: { res in switch res { case .success(let r): cont.resume(returning: r); case .failure(let e): cont.resume(throwing: e) } })
   }
   if cancelled { return .cancelled }
   guard result.exitCode == 0 else { throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr) }
4) Сбор результатов:
   let txt = outputDir.appendingPathComponent(Self.sanitize(params.sourceName) + ".txt")
   let srt = outputDir.appendingPathComponent(Self.sanitize(params.sourceName) + ".srt")
   let fm = FileManager.default
   if fm.fileExists(atPath: txt.path) && fm.fileExists(atPath: srt.path) { return .done(txt: txt, srt: srt, outputDir: outputDir) }
   return .empty(outputDir: outputDir)

Парсеры (static; parseHMS — как в SceneExtractor):
    static func parsePercent(_ line: String) -> Double? {
        // whisper.cpp -pp пишет в stderr: "whisper_print_progress_callback:  progress =  42%"
        guard let r = line.range(of: "progress") else { return nil }
        let tail = line[r.upperBound...]
        guard let pr = tail.range(of: "=") else { return nil }
        let digits = tail[pr.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        guard let n = Double(digits) else { return nil }
        return max(0, min(1, n / 100))
    }
    static func parseSegmentProgress(_ line: String, duration: Double?) -> Double? {
        // строки сегментов: "[00:00:01.480 --> 00:00:04.000]   текст" — берём СТАРТ
        guard let duration, duration > 0, let open = line.firstIndex(of: "[") else { return nil }
        guard let arrow = line.range(of: "-->") else { return nil }
        let inside = line[line.index(after: open)..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let secs = parseHMS(inside) else { return nil }
        return max(0, min(1, secs / duration))
    }
    static func parseHMS(_ s: String) -> Double? { let p = s.split(separator: ":"); guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }; return h*3600 + m*60 + sec }
    static func sanitize(_ s: String) -> String { let bad = CharacterSet(charactersIn: "/\\:*?\"<>|"); let j = s.components(separatedBy: bad).joined(separator: "_"); return j.isEmpty ? "audio" : j }

Язык: .auto = автоопределение whisper (передаём -l auto); .ru / .en — принудительно. Дефолт .auto. Потоки: дефолт = ProcessInfo.processInfo.activeProcessorCount (минимум 1).

ФАЙЛ 3 — Scripts/build.sh: после блока копирования Helpers добавь копирование модели (одинаковой для обеих арх):
    if [ -d "$ROOT/Resources/Models" ]; then
        log "bundling whisper model"
        mkdir -p "$APP/Contents/Resources/Models"
        cp -R "$ROOT/Resources/Models/." "$APP/Contents/Resources/Models/"
    fi
И в существующих find … -name 'ffmpeg' -o -name 'ffprobe' (chmod +x И codesign) добавь -o -name 'whisper-cli', чтобы вшитый whisper-cli тоже стал исполняемым и подписался ПЕРЕД бандлом. (Аналогично поправь Scripts/sign.sh: в find для подписи вложенных бинарников добавь -o -name whisper-cli. Модель ggml-base.bin — это данные, отдельно подписывать не нужно, она покроется подписью бандла.)

ВАЖНО: бинарники whisper-cli (Helpers/arm64/whisper-cli, Helpers/x86_64/whisper-cli) и Resources/Models/ggml-base.bin должны лежать в репозитории (их кладёт отдельный fetch-скрипт из соседнего слайса). Этот этап только их ПОДКЛЮЧАЕТ и использует. Если их нет — toolURL(.whisper)/modelURL() вернут nil и движок бросит понятную ошибку «Не найден встроенный whisper-cli…» / «модель транскрипции».
```

**Критерии приёмки:**

1) Запускатель: после добавления `case whisper = "whisper-cli"` проект собирается (./Scripts/build.sh, можно FAST=1) без ворнингов; `FFmpeg.shared.toolURL(.whisper)` указывает на Contents/Resources/Helpers/<arch>/whisper-cli; никакие правки не затронули DispatchGroup/readabilityHandler в launch(). 2) WAV+TXT+SRT: дан локальный mp4/mov с речью → transcribe(...) создаёт в outputDir файлы <name>.txt и <name>.srt с непустым текстом; промежуточный WAV в temporaryDirectory удаляется после завершения (defer). Проверка вручную: собрать тестовый WAV `ffmpeg -i in.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le /tmp/t.wav` и `Helpers/$(uname -m)/whisper-cli -m Resources/Models/ggml-base.bin -f /tmp/t.wav -l auto -otxt -osrt -of /tmp/out -t $(sysctl -n hw.ncpu) -pp` → появляются /tmp/out.txt и /tmp/out.srt, а в stderr видны строки `progress =  NN%`. 3) Прогресс: onProgress вызывается с возрастающими значениями 0<p≤1 по мере транскрипции (парсер ловит `progress = N%` на stderr; фолбэк — старт таймкода сегмента ÷ длительность WAV). 4) Отмена: вызов cancel() в середине транскрипции терминирует whisper-cli (или ffmpeg-перекодировку, если ещё идёт она), continuation резолвится, метод возвращает .cancelled, частичные файлы не считаются успехом. 5) Язык/потоки: -l принимает auto|ru|en (дефолт auto); -t = ProcessInfo.activeProcessorCount по умолчанию. 6) Ошибки: при отсутствии whisper-cli — ошибка «Не найден встроенный whisper-cli…»; при отсутствии модели — «модель транскрипции»; при exit!=0 — FFmpegError.failed (сырой stderr только в технический лог).


---


## Срез D-ui-tabs


**Измерение:** UI — adding the «Транскрипция» tab without breaking the existing «Кадры» flow


**Резюме:** This slice refactors the monolithic ContentView into a RootView that hosts a top-level segmented Picker switching between «Кадры» (the existing frame-extraction flow, moved verbatim into FramesView) and «Транскрипция» (a new TranscriptionView). The current ContentView (Sources/SceneShot/ContentView.swift, 403 lines, owns ALL input + run state + 9 @AppStorage keys) becomes FramesView with byte-for-byte identical behaviour. A new SharedInputSection is NOT introduced as a shared component in this slice (to keep the frames flow provably unchanged) — instead the input affordances (dropZone + «Выбрать видео…» + urlRow + sourceSummary) are copied into TranscriptionView, reusing the existing Source / VideoValidation / MediaProbe / Downloader.validate machinery exactly as FramesView uses them. TranscriptionView adds a language picker (Авто/Русский/English/…), TXT+SRT toggles (both on by default), an output-folder picker, a static model-status line «Модель: base (встроена)», a big «Транскрибировать» button, and progress+ETA+cancel + a results card — all driven by the same idle/probing/working/done/empty/error/cancelled job pattern. To compile independently of the (sibling) transcription-engine slice, this slice declares a thin TranscriptionEngine contract (Transcriber class + TranscribeParams + TranscribeOutcome + TranscriptResult) with a stub implementation behind it, so the UI builds and the engine slice fills in the real whisper.cpp call later. The app entry point changes from ContentView() to RootView() in one line of SceneShotApp.swift.


**Технические детали:**

EXACT CURRENT STATE (grounded in repo):
- SceneShotApp.swift WindowGroup { ContentView() } with .windowResizability(.contentSize).
- ContentView (Sources/SceneShot/ContentView.swift) holds: input @State source/info/remoteSizeText/notice/noticeIsError/probing/urlText/dropTargeted; run @State extracting/progress/phaseLabel/startTime/userCancelled/result/extractor(SceneExtractor)/downloader(Downloader); 9 @AppStorage: threshold, minInterval, format, jpegQuality, maxWidth, maxFrames, outputFolderPath, filenameTemplate, downloadFirst. Computed views: header, dropZone, urlRow, sourceSummary(_:), bottomBar. Methods: pickVideo, handleDrop, loadFromURL, setSource (async: Downloader.validate for remote, MediaProbe.probe), failInput, currentParams, extract, finishExtraction, retryMoreSensitive, cancelAll, etaText, makeOutputDir, describeError; plus private extension Double.rounded(toPlaces:).
- RunResult enum + ResultsView + pluralFrames live in Views/ResultsView.swift; RunResult is frames-specific (.done(count,dir,frames:[FrameRef]) / .empty(dir) / .error(message,technical) / .cancelled).
- Reusable as-is: Source + VideoValidation + ValidationError (Models/Source.swift), MediaInfo + MediaProbe (Engine/MediaProbe.swift), RemoteInfo + Downloader (Engine/Downloader.swift), FFmpegTool + FFmpeg.shared + ProcessResult + FFmpegError (Engine/FFmpeg.swift). FFmpegTool is a String enum {ffmpeg,ffprobe}; the engine slice will extend it with `case whisper`, but THIS slice must not depend on that — it talks only to the Transcriber contract.
- Package.swift path is Sources/SceneShot with -parse-as-library; any new .swift file under that dir is compiled automatically (no Package.swift edit needed). Confirmed `swift build` is green at baseline (Build complete!, exit 0).

REFACTOR MECHANICS (RootView via segmented Picker — chosen over TabView because the app already uses .pickerStyle(.segmented) in SettingsView, matches the «Кадры»/«Транскрипция» two-way switch, and keeps a single WindowGroup with .contentSize resizability):
1. Sources/SceneShot/Views/RootView.swift (NEW): owns one persisted tab selector `@AppStorage("activeTab") private var tab = AppTab.frames` (enum AppTab: String { case frames, transcription }). body = VStack(spacing:16) { app title header; Picker(selection:$tab){ Text("Кадры").tag(.frames); Text("Транскрипция").tag(.transcription) }.pickerStyle(.segmented).labelsHidden(); then `switch tab { case .frames: FramesView(); case .transcription: TranscriptionView() }` }.padding(24).frame(minWidth:560,minHeight:620). The shared app title «SceneShot» moves UP into RootView; FramesView/TranscriptionView each render their own subtitle line. Because each tab is a distinct View with its own @State, switching tabs preserves each tab's state independently (SwiftUI keeps both subtrees' identity stable across the switch only if both are always instantiated; using a switch RECREATES state on toggle). To preserve in-flight frames/transcription state across tab toggles, instantiate BOTH and toggle visibility instead: ZStack { FramesView().opacity(tab == .frames ? 1 : 0).allowsHitTesting(tab == .frames); TranscriptionView().opacity(tab == .transcription ? 1 : 0).allowsHitTesting(tab == .transcription) } — keeps a running extraction alive when the user peeks at the other tab. (Acceptable simpler alternative if reviewers prefer: plain switch; document that toggling mid-run is not a target scenario.)
2. Sources/SceneShot/ContentView.swift → rename struct ContentView to FramesView (keep file or rename file to Views/FramesView.swift — renaming the file is cleaner; if kept, leave a `typealias ContentView = FramesView` OUT to avoid confusion). Move ALL existing state/methods unchanged. Only edits: remove the outer .frame(minWidth:560,minHeight:620) and the «SceneShot» largeTitle from `header` (RootView owns chrome now); FramesView's header becomes just the subtitle «Извлечение кадров на смене сцены». Everything else (dropZone, urlRow, sourceSummary, SettingsView call with all 9 bindings, ResultsView, bottomBar, extract pipeline) stays identical. The private Double.rounded(toPlaces:) extension stays with FramesView (or move to a shared file; it's only used by retryMoreSensitive).
3. SceneShotApp.swift: change `ContentView()` → `RootView()`.

TRANSCRIPTIONVIEW (Sources/SceneShot/Views/TranscriptionView.swift, NEW): mirrors FramesView's structure. State: copy the INPUT block verbatim (source/info/remoteSizeText/notice/noticeIsError/probing/urlText/dropTargeted) and the run block adapted (transcribing:Bool, progress:Double, phaseLabel:String, startTime:Date?, userCancelled:Bool, txResult:TranscriptRunResult?, transcriber=Transcriber(), downloader=Downloader()). @AppStorage (NEW keys, distinct from frames so they don't collide): `@AppStorage("tx_language") language = "auto"`, `@AppStorage("tx_txt") wantTxt = true`, `@AppStorage("tx_srt") wantSrt = true`, `@AppStorage("tx_outputFolderPath") txOutputFolderPath = ""`. Reuse the SAME input methods (pickVideo/handleDrop/loadFromURL/setSource/failInput) — copy them; setSource is identical (Downloader.validate + MediaProbe.probe). UI body mirrors FramesView: subtitle «Автоматическая расшифровка речи в текст»; dropZone (same dashed RoundedRectangle, icon "waveform" or "text.bubble", text «Перетащите сюда видео для расшифровки»); urlRow identical; sourceSummary identical; THEN a transcription-options card (DisclosureGroup OR always-visible VStack): language Picker (.menu style) with tags "auto"/"ru"/"en"/"uk"/"de"/"es"/"fr" labelled «Авто»/«Русский»/«English»/«Українська»/«Deutsch»/«Español»/«Français»; two Toggles «Текст (.txt)» bound to $wantTxt and «Субтитры (.srt)» bound to $wantSrt (guard: if both off, disable run button and show hint «Выберите хотя бы один формат вывода»); output-folder picker identical pattern to SettingsView.chooseFolder (NSOpenPanel canChooseDirectories) writing txOutputFolderPath, with «Сброс»/«Выбрать…» and a caption showing «по умолчанию: ~/Movies/SceneShot» or the path; a static model-status line: HStack { Image(systemName:"cpu"); Text("Модель: base (встроена)").font(.caption).foregroundStyle(.secondary) }; bottomBar: when !transcribing a borderedProminent .large Button { transcribe() } label Label("Транскрибировать", systemImage:"text.bubble").frame(maxWidth:.infinity), .disabled(source==nil || probing || (!wantTxt && !wantSrt)); when transcribing the SAME progress block as FramesView (phaseLabel, ProgressView(value:progress).linear, percent + «осталось ~\(eta)» via an etaText() copied verbatim, «Отменить» → cancelAll()). Results: a TranscriptionResultsView card.

TRANSCRIPTION RESULT TYPES (define in TranscriptionView.swift or a small Views/TranscriptionResultsView.swift): `enum TranscriptRunResult { case done(TranscriptResult); case empty; case error(message:String, technical:String?); case cancelled }`. The card for .done shows: «Готово» check; a transcript preview (ScrollView { Text(result.previewText).textSelection(.enabled).font(.callout) }.frame(maxHeight:160)); buttons «Показать в Finder» (NSWorkspace.shared.activateFileViewerSelecting([result.outputDir])), «Открыть .txt»/«Открыть .srt» (NSWorkspace.shared.open on result.txtURL/result.srtURL when non-nil), «Скопировать текст» (NSPasteboard.general.clearContents(); .setString(result.fullText, forType:.string)). .empty → «Речь не распознана»; .error → reuse the same DisclosureGroup «Технический лог» pattern from ResultsView.errorView; .cancelled → «Отменено.».

ENGINE CONTRACT (this slice DEFINES the interface so it compiles standalone; the transcription-engine slice IMPLEMENTS the body): create Sources/SceneShot/Engine/Transcriber.swift with:
```
struct TranscribeParams { var language: String = "auto"; var wantTxt = true; var wantSrt = true; var outputDir: URL; var sourceName: String = "audio" }
struct TranscriptResult { let outputDir: URL; let txtURL: URL?; let srtURL: URL?; let fullText: String; var previewText: String { String(fullText.prefix(2000)) } }
enum TranscribeOutcome { case done(TranscriptResult); case empty(outputDir: URL); case cancelled }
final class Transcriber {
    private var running: FFmpeg.Running?
    private var cancelled = false
    func cancel() { cancelled = true; running?.cancel() }
    func transcribe(source: Source, outputDir: URL, params: TranscribeParams, durationSeconds: Double?, onProgress: @escaping (Double)->Void) async throws -> TranscribeOutcome {
        // STUB for the UI slice — the engine slice replaces this body with the real
        // ffmpeg(extract wav)+whisper.cpp pipeline (FFmpegTool gains `case whisper`).
        throw FFmpegError.toolMissing("whisper")
    }
}
```
This makes TranscriptionView fully type-check and the «Транскрибировать» button wire end-to-end (it will surface the «Не найден встроенный whisper…» error until the engine slice lands — which is the correct offline-honest behaviour and a valid acceptance demo). transcribe() in the View mirrors extract(): build txOutputDir via a makeOutputDir copy (default ~/Movies/SceneShot/<name>-<stamp>, or txOutputFolderPath), set transcribing=true/progress=0/startTime/phaseLabel=«Расшифровка…» (and «Загрузка видео…» first if remote+downloadFirst — but transcription has no downloadFirst toggle, so for remote it streams: just probe/feed URL; ffmpeg-wav-extraction in the engine slice handles -reconnect), call transcriber.transcribe(...), map outcome to txResult on MainActor, finishTranscription() resets flags. cancelAll(){ userCancelled=true; downloader.cancel(); transcriber.cancel() }. Error mapping: reuse a small describeError that returns ((error as? LocalizedError)?.errorDescription ?? "Ошибка расшифровки.", (error as? FFmpegError stderr if any)).

WHY no shared SharedInputView extraction in THIS slice: the task demands frames behaviour stay IDENTICAL and provable. Extracting a generic input component risks subtle regressions (binding plumbing, the async setSource closure capturing self). Duplicating ~60 lines of input UI into TranscriptionView is the lower-risk move for this slice; a follow-up cleanup slice can DRY it into a SharedSourceInput component once both tabs are green. Note this explicitly in keyDecisions.


**Ключевые решения:**

- Top switch is a segmented Picker (not TabView): matches existing .pickerStyle(.segmented) usage in SettingsView, fits a 2-way «Кадры»/«Транскрипция» toggle, keeps the single WindowGroup + .windowResizability(.contentSize) layout intact.
- ContentView is renamed to FramesView and moved to Views/, with ZERO logic changes — only the app-title largeTitle and the outer minWidth/minHeight frame are lifted into RootView. This is what makes 'frames behaviour identical' provable.
- Input affordances are DUPLICATED into TranscriptionView (dropZone/urlRow/sourceSummary + pickVideo/handleDrop/loadFromURL/setSource/failInput copied) rather than extracted into a shared component IN THIS SLICE. Rationale: extracting a generic input view risks subtle regressions in the frames flow (binding plumbing, async setSource self-capture); a follow-up cleanup slice can DRY it into SharedSourceInput once both tabs are green. Flagged as a known, intentional debt.
- This UI slice DEFINES the Transcriber engine contract (Transcriber + TranscribeParams + TranscriptResult + TranscribeOutcome) with a stub body, so the UI compiles and the button wires end-to-end independently of the sibling engine slice. The stub throws FFmpegError.toolMissing("whisper") — offline-honest, and a valid acceptance demo until the real whisper.cpp pipeline lands.
- RootView keeps BOTH tab subtrees alive via ZStack + opacity/allowsHitTesting (not a switch), so an in-progress extraction or transcription survives a tab toggle. The current FFmpegTool stays untouched; the engine slice adds `case whisper` later, so this slice has no dependency on that change.
- New @AppStorage keys are namespaced with a tx_ prefix (tx_language/tx_txt/tx_srt/tx_outputFolderPath) plus activeTab, guaranteeing no collision with the 9 existing frames keys.
- TranscriptRunResult is a SEPARATE enum from RunResult (frames). RunResult is frame-specific (count/dir/frames:[FrameRef], pluralFrames). Reusing it would force awkward shoehorning; a parallel enum keeps each tab's result UI clean while copying ResultsView's proven error/empty card structure.

**Риски:**

- SwiftUI state identity on tab switch: a plain `switch tab { ... }` recreates each view's @State on every toggle, silently killing an in-flight run. Mitigation specified: ZStack + opacity/allowsHitTesting keeps both subtrees mounted. If reviewers accept losing mid-run state on toggle, the switch form is simpler — call it out, don't ship it silently.
- Compilation coupling with the engine slice: if the engine slice ALSO declares Transcriber/TranscribeParams/etc., there will be duplicate-symbol build errors. Resolution: this slice owns Engine/Transcriber.swift's type/stub; the engine slice must REPLACE the stub body in the same file, not add a second declaration. State this boundary explicitly in both slices' prompts.
- FFmpegTool currently has only ffmpeg/ffprobe; the stub Transcriber must NOT reference a non-existent `.whisper` case or the UI slice won't compile. The stub deliberately throws toolMissing("whisper") as a plain string — verify no `.whisper` enum reference sneaks in.
- Input-code duplication drift: because pickVideo/handleDrop/loadFromURL/setSource are copied, a future bug fix in one tab can be forgotten in the other. Mitigation: the planned follow-up DRY slice; until then, note the duplication at the top of TranscriptionView.
- Renaming ContentView -> FramesView can leave dangling references (e.g., previews, build scripts). Grep `ContentView` across the repo (Sources + Scripts) after the change; Scripts/build.sh references the bundle/executable name, not the view, so it should be unaffected — confirm.
- Window sizing regression: the minWidth/minHeight frame moves from ContentView to RootView. If forgotten, the window can collapse. Acceptance check #3 + the explicit frame in RootView guard against this.
- Language tag values ('auto','ru','en',…) must match whatever the engine slice passes to whisper.cpp (-l). Document the agreed tag vocabulary so the engine slice maps them correctly (whisper uses 'auto' for detect, ISO codes otherwise).

**Файлы (добавить/изменить):**

- Sources/SceneShot/SceneShotApp.swift (edit: ContentView() -> RootView())
- Sources/SceneShot/ContentView.swift (delete; content moves to Views/FramesView.swift)
- Sources/SceneShot/Views/FramesView.swift (new: former ContentView, renamed struct, header/frame chrome removed)
- Sources/SceneShot/Views/RootView.swift (new: segmented Picker «Кадры»/«Транскрипция» + app title + window frame)
- Sources/SceneShot/Views/TranscriptionView.swift (new: mirrors FramesView input + language/format/folder/model-status/run/progress)
- Sources/SceneShot/Views/TranscriptionResultsView.swift (new: TranscriptRunResult + result card with preview/open/copy)
- Sources/SceneShot/Engine/Transcriber.swift (new: TranscribeParams/TranscriptResult/TranscribeOutcome + stub Transcriber that the engine slice fills in)

**Команды:**

```bash
swift build
grep -rn "struct ContentView" Sources/SceneShot
grep -rn "RootView()" Sources/SceneShot/SceneShotApp.swift
swift build 2>&1 | grep -i warning || echo 'no warnings'
./Scripts/build.sh && open dist/SceneShot.app
```

**Черновик промпта для этапа:**


```text
Рефактори UI приложения SceneShot: добавь верхний переключатель режимов «Кадры» / «Транскрипция», НЕ ломая существующий поток извлечения кадров. Работай только в Sources/SceneShot. Перед началом прочитай: Sources/SceneShot/ContentView.swift, Sources/SceneShot/Views/SettingsView.swift, Sources/SceneShot/Views/ResultsView.swift, Sources/SceneShot/Models/Source.swift, Sources/SceneShot/Engine/FFmpeg.swift, Sources/SceneShot/Engine/Downloader.swift, Sources/SceneShot/Engine/MediaProbe.swift, Sources/SceneShot/SceneShotApp.swift. Сборка проверяется командой `swift build` (сейчас она зелёная — не сломай).

ШАГ 1 — FramesView (поведение кадров не меняется ни на байт логики).
- Переименуй struct ContentView в FramesView. Перемести файл в Sources/SceneShot/Views/FramesView.swift (содержимое целиком, со всеми @State, @AppStorage и методами extract/setSource/etc. и private extension Double.rounded(toPlaces:)). Удали старый ContentView.swift.
- Единственные правки внутри FramesView: (а) убери из var body внешний модификатор `.frame(minWidth: 560, minHeight: 620)` (его возьмёт RootView); (б) в `header` убери крупный заголовок `Text("SceneShot").font(.largeTitle).bold()` — оставь только подзаголовок `Text("Извлечение кадров на смене сцены").foregroundStyle(.secondary)`. Всё остальное (dropZone, urlRow, sourceSummary, вызов SettingsView со всеми 9 биндингами, ResultsView, bottomBar, весь конвейер extract) оставь идентичным.

ШАГ 2 — RootView (Sources/SceneShot/Views/RootView.swift, новый).
```
import SwiftUI
enum AppTab: String { case frames, transcription }
struct RootView: View {
    @AppStorage("activeTab") private var tab = AppTab.frames
    var body: some View {
        VStack(spacing: 16) {
            Text("SceneShot").font(.largeTitle).bold()
            Picker("", selection: $tab) {
                Text("Кадры").tag(AppTab.frames)
                Text("Транскрипция").tag(AppTab.transcription)
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 360)
            ZStack {
                FramesView().opacity(tab == .frames ? 1 : 0).allowsHitTesting(tab == .frames)
                TranscriptionView().opacity(tab == .transcription ? 1 : 0).allowsHitTesting(tab == .transcription)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 620)
    }
}
```
(ZStack с opacity сохраняет состояние обеих вкладок при переключении — идущая обработка не сбрасывается. @AppStorage("activeTab") НЕ должен пересекаться с ключами @AppStorage из @AppStorage параметров extractor.)

ШАГ 3 — SceneShotApp.swift: замени `ContentView()` на `RootView()`. Больше ничего не трогай.

ШАГ 4 — Контракт движка транскрипции (Sources/SceneShot/Engine/Transcriber.swift, новый). Это ЗАГЛУШКА, реальную реализацию whisper.cpp добавит соседний срез — но UI должен компилироваться и кнопка должна быть подключена end-to-end.
```
import Foundation
struct TranscribeParams {
    var language: String = "auto"
    var wantTxt = true
    var wantSrt = true
    var outputDir: URL
    var sourceName: String = "audio"
}
struct TranscriptResult {
    let outputDir: URL
    let txtURL: URL?
    let srtURL: URL?
    let fullText: String
    var previewText: String { String(fullText.prefix(2000)) }
}
enum TranscribeOutcome {
    case done(TranscriptResult)
    case empty(outputDir: URL)
    case cancelled
}
final class Transcriber {
    private var running: FFmpeg.Running?
    private var cancelled = false
    func cancel() { cancelled = true; running?.cancel() }
    func transcribe(source: Source, outputDir: URL, params: TranscribeParams,
                    durationSeconds: Double?, onProgress: @escaping (Double) -> Void) async throws -> TranscribeOutcome {
        // ЗАГЛУШКА для UI-среза. Соседний срез заменит тело реальным пайплайном
        // ffmpeg(WAV 16k mono) + whisper.cpp (FFmpegTool получит `case whisper`).
        throw FFmpegError.toolMissing("whisper")
    }
}
```

ШАГ 5 — TranscriptionView (Sources/SceneShot/Views/TranscriptionView.swift, новый). Зеркаль структуру FramesView, переиспользуя Source/VideoValidation/MediaProbe/Downloader.
- Состояние ввода — СКОПИРУЙ из FramesView без изменений: source/info/remoteSizeText/notice/noticeIsError/probing/urlText/dropTargeted.
- Состояние прогона: transcribing=false, progress=0.0, phaseLabel="", startTime:Date?=nil, userCancelled=false, txResult:TranscriptRunResult?=nil, transcriber=Transcriber(), downloader=Downloader().
- @AppStorage (НОВЫЕ ключи, не пересекаются с кадрами): "tx_language"=="auto", "tx_txt"==true, "tx_srt"==true, "tx_outputFolderPath"=="".
- Методы ввода pickVideo/handleDrop/loadFromURL/setSource/failInput — скопируй из FramesView (setSource идентичен: для .remote вызывает Downloader.validate, затем MediaProbe.probe(s.ffmpegInput); вместо self.result=nil сбрасывай self.txResult=nil).
- body: подзаголовок Text("Автоматическая расшифровка речи в текст").foregroundStyle(.secondary); ScrollView { dropZone (та же пунктирная RoundedRectangle что в FramesView, иконка systemName "waveform", текст «Перетащите сюда видео для расшифровки», кнопка Label("Выбрать видео…", systemImage:"folder")); urlRow идентичен; if probing { ProgressView().controlSize(.small) }; if let source { sourceSummary(source) } (скопируй sourceSummary целиком); карточка опций (VStack в RoundedRectangle .fill(Color.secondary.opacity(0.06)), padding 12): Picker("Язык", selection:$language){ Text("Авто").tag("auto"); Text("Русский").tag("ru"); Text("English").tag("en"); Text("Українська").tag("uk"); Text("Deutsch").tag("de"); Text("Español").tag("es"); Text("Français").tag("fr") }.pickerStyle(.menu); Toggle("Текст (.txt)", isOn:$wantTxt); Toggle("Субтитры (.srt)", isOn:$wantSrt); if !wantTxt && !wantSrt { Text("Выберите хотя бы один формат вывода").font(.caption).foregroundStyle(.red) }; блок «Папка вывода» (как в SettingsView.output: «Сброс» если непусто + «Выбрать…» → NSOpenPanel canChooseDirectories=true/canChooseFiles=false → txOutputFolderPath=url.path; caption txOutputFolderPath.isEmpty ? "по умолчанию: ~/Movies/SceneShot" : txOutputFolderPath); строка статуса модели HStack { Image(systemName:"cpu").foregroundStyle(.secondary); Text("Модель: base (встроена)").font(.caption).foregroundStyle(.secondary) }; if let txResult, !transcribing { TranscriptionResultsView(result: txResult) } }; затем bottomBar (как у FramesView): если transcribing — VStack { if !phaseLabel.isEmpty { Text(phaseLabel).font(.caption).foregroundStyle(.secondary) }; ProgressView(value:progress).progressViewStyle(.linear); HStack { Text("\(Int(progress*100))%").font(.caption).monospacedDigit(); if let eta=etaText() { Text("· осталось ~\(eta)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Отменить"){ cancelAll() } } }; иначе Button { transcribe() } label: Label("Транскрибировать", systemImage:"text.bubble").frame(maxWidth:.infinity), .controlSize(.large).buttonStyle(.borderedProminent).disabled(source==nil || probing || (!wantTxt && !wantSrt)).
- etaText() — скопируй из FramesView. makeOutputDir(for:) — скопируй из FramesView, но базируй на txOutputFolderPath (дефолт ~/Movies/SceneShot/<name>-<stamp>); вынеси stampFormatter так же static.
- transcribe(): guard let source; outDir=makeOutputDir(for:source); var params=TranscribeParams(outputDir:outDir); params.language=language; params.wantTxt=wantTxt; params.wantSrt=wantSrt; params.sourceName=(source.displayName as NSString).deletingPathExtension; transcribing=true; progress=0; userCancelled=false; txResult=nil; notice=""; startTime=Date(); phaseLabel="Расшифровка…"; Task { do { let outcome = try await transcriber.transcribe(source:source, outputDir:outDir, params:params, durationSeconds:info?.durationSeconds, onProgress:{ p in Task { @MainActor in self.progress=p } }); await MainActor.run { self.finishTranscription(); switch outcome { case .done(let r): self.txResult = .done(r); NSWorkspace.shared.activateFileViewerSelecting([r.outputDir]); case .empty: self.txResult = .empty; case .cancelled: self.txResult = .cancelled } } } catch { await MainActor.run { self.finishTranscription(); if self.userCancelled || error is CancellationError { self.txResult = .cancelled } else { let m=(error as? LocalizedError)?.errorDescription ?? "Ошибка расшифровки."; var tech:String? = nil; if let ff = error as? FFmpegError, case .failed(_, let stderr)=ff { tech=stderr }; self.txResult = .error(message:m, technical:tech) } } } } }.
- finishTranscription(){ transcribing=false; progress=0; phaseLabel=""; startTime=nil }. cancelAll(){ userCancelled=true; downloader.cancel(); transcriber.cancel() }.

ШАГ 6 — TranscriptionResultsView + TranscriptRunResult (в TranscriptionView.swift или отдельном Views/TranscriptionResultsView.swift).
```
enum TranscriptRunResult {
    case done(TranscriptResult)
    case empty
    case error(message: String, technical: String?)
    case cancelled
}
```
Карточка: .done(r) → VStack: HStack { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green); Text("Готово").bold() }; ScrollView { Text(r.previewText).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading) }.frame(maxHeight:160); HStack { Button { NSWorkspace.shared.activateFileViewerSelecting([r.outputDir]) } label: Label("Показать в Finder", systemImage:"folder"); if let t=r.txtURL { Button { NSWorkspace.shared.open(t) } label: Label("Открыть .txt", systemImage:"doc.text") }; if let s=r.srtURL { Button { NSWorkspace.shared.open(s) } label: Label("Открыть .srt", systemImage:"captions.bubble") }; Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.fullText, forType:.string) } label: Label("Скопировать текст", systemImage:"doc.on.doc") } } внутри RoundedRectangle(cornerRadius:10).fill(Color.green.opacity(0.08)), padding 12, frame(maxWidth:.infinity). .empty → как emptyView в ResultsView, текст «Речь не распознана», иконка "waveform.slash", оранжевый фон, без кнопки повтора. .error(message,technical) → точная копия структуры errorView из ResultsView (красный фон + DisclosureGroup «Технический лог» с моноширинным ScrollView, .textSelection(.enabled), maxHeight 120). .cancelled → HStack { Image(systemName:"xmark.circle").foregroundStyle(.secondary); Text("Отменено.") } в сером фоне.

ПОСЛЕ всех изменений: запусти `swift build` — должно быть «Build complete!» без ворнингов. Убедись что в проекте больше нет ссылок на старое имя ContentView (`grep -rn ContentView Sources` → только в истории/нет). НЕ редактируй Package.swift (новые файлы под Sources/SceneShot подхватываются автоматически). НЕ меняй сигнатуры FFmpeg/Downloader/MediaProbe/Source.
```

**Критерии приёмки:**

1) `swift build` завершается «Build complete!» с кодом 0 и БЕЗ ворнингов (как и до рефактора). 2) `grep -rn "struct ContentView" Sources/SceneShot` ничего не находит; `grep -rn "RootView()" Sources/SceneShot/SceneShotApp.swift` находит точку входа. 3) При запуске (`./Scripts/build.sh` затем `open dist/SceneShot.app`, на машине с дисплеем) вверху окна виден сегментированный переключатель «Кадры» | «Транскрипция»; по умолчанию активна «Кадры». 4) Вкладка «Кадры» работает идентично прежнему ContentView: drag&drop файла и вставка прямой ссылки заполняют источник и показывают длительность/разрешение; «Извлечь кадры» запускает извлечение, идёт прогресс+ETA, «Отменить» останавливает ffmpeg, по готовности открывается Finder, ResultsView/empty/error/cancel отображаются как раньше; @AppStorage настройки кадров сохраняются. 5) Переключение на «Транскрипция» НЕ сбрасывает состояние вкладки «Кадры» (идущая обработка продолжается; выбранный источник остаётся). 6) Вкладка «Транскрипция» имеет те же средства ввода, что и «Кадры»: та же пунктирная зона drag&drop, кнопка «Выбрать видео…», поле прямой ссылки + «Загрузить», и тот же блок sourceSummary с метаданными из MediaProbe; невалидная ссылка даёт то же понятное сообщение (через VideoValidation/Downloader.validate). 7) Видны: Picker языка (Авто/Русский/English/Українська/Deutsch/Español/Français), два тумблера «Текст (.txt)» и «Субтитры (.srt)» — оба включены по умолчанию; при обоих выключенных кнопка «Транскрибировать» неактивна и показана подсказка «Выберите хотя бы один формат вывода»; выбор папки вывода (NSOpenPanel) с дефолтом ~/Movies/SceneShot; строка «Модель: base (встроена)». 8) Большая кнопка «Транскрибировать» неактивна без источника; при нажатии (с заглушкой Transcriber) показывает прогресс-блок, а затем карточку ошибки «Не найден встроенный whisper…» с разворачиваемым «Технический лог» — то есть end-to-end-проводка кнопки подтверждена (реальный вывод появится после среза движка). 9) @AppStorage-ключи транскрипции (tx_language/tx_txt/tx_srt/tx_outputFolderPath) и activeTab НЕ конфликтуют с ключами кадров (threshold/minInterval/format/jpegQuality/maxWidth/maxFrames/outputFolderPath/filenameTemplate/downloadFirst).


---


## Срез E-outputs


**Измерение:** Output files (TXT+SRT) and the results/preview/save UX for transcription


**Резюме:** Designs the output + results UX for the new «Транскрипция» tab, mirroring the existing frame-extraction result pattern. whisper-cli writes <basename>.txt and <basename>.srt via `-of <dir>/<basename> -otxt -osrt` into a per-run folder `~/Movies/SceneShot/<name>-transcript-<stamp>/` (reusing ContentView.makeOutputDir conventions: outputFolderPath @AppStorage override, .moviesDirectory fallback, the existing yyyy-MM-dd_HH-mm-ss stamp). A new TranscriptResultsView mirrors ResultsView.RunResult with a typed TranscriptResult enum (.done/.empty/.error/.cancelled), reads the TXT off disk into a scrollable SELECTABLE preview (reusing the textSelection(.enabled) + monospaced ScrollView pattern already in ResultsView's technical-log section), and shows «Открыть папку» / «Показать в Finder» (reusing NSWorkspace.shared.open / activateFileViewerSelecting verbatim) plus «Копировать текст» (NSPasteboard). Empty/no-speech is a first-class typed state (.empty) with a Russian message, detected by an empty/whitespace-only TXT after a 0-exit run. SRT timecode sanity is a lightweight validator (HH:MM:SS,mmm --> HH:MM:SS,mmm line check) that downgrades to a soft warning, never a hard failure.


**Технические детали:**

WHISPER OUTPUT FLAGS (load-bearing): whisper-cli writes sidecar files from the value of `-of` (output file path WITHOUT extension) plus per-format switches. So for outDir + basename `transcript`: pass `-otxt -osrt -of <outDir>/transcript`. whisper-cli then creates exactly `<outDir>/transcript.txt` and `<outDir>/transcript.srt`. Do NOT append extensions to `-of` (whisper adds `.txt`/`.srt` itself; passing `transcript.txt` yields `transcript.txt.txt`). Language is selected by the sibling engine's `-l <code>` (e.g. `-l ru`, or `-l auto`); this slice only needs the code to (a) name nothing differently and (b) optionally surface a tiny "распознан язык: RU" caption parsed from whisper stderr line `whisper_full_with_state: auto-detected language: ru (p = ...)`. SRT shape whisper emits (1-indexed, blank-line separated):
  1\n00:00:00,000 --> 00:00:02,480\n<text>\n\n
The TXT is plain UTF-8, one line per segment, no timecodes.

OUTPUT DIR (mirror ContentView.makeOutputDir exactly, only the suffix differs): stamp = same static DateFormatter `yyyy-MM-dd_HH-mm-ss`; base = outputFolderPath (if a NEW @AppStorage("transcriptOutputFolderPath") is non-empty) else `.moviesDirectory` first URL (fallback `homeDirectoryForCurrentUser/Movies`) + "SceneShot"; final = base + "<name>-transcript-<stamp>" where name = (source.displayName as NSString).deletingPathExtension. Create with createDirectory(withIntermediateDirectories: true). NOTE the suffix is `-transcript-<stamp>` (Кадры uses bare `-<stamp>`) so the two tabs never collide in the same parent folder.

TYPED RESULT STATE (new file Sources/SceneShot/Views/TranscriptResultsView.swift, modeled 1:1 on ResultsView.swift):
  enum TranscriptResult {
      case done(dir: URL, txtURL: URL, srtURL: URL, text: String, segments: Int, language: String?, srtWarning: String?)
      case empty(dir: URL)                 // 0-exit but no speech → empty/whitespace TXT
      case error(message: String, technical: String?)
      case cancelled
  }
TranscriptResultsView switches over it just like ResultsView. The engine (sibling slice) returns done/empty/cancelled; ContentView maps a thrown WhisperError/FFmpegError-style failure to .error(message,technical) via a describeError() like the existing one. `text` is read ONCE on the engine's background completion (try String(contentsOf: txtURL, encoding: .utf8)) so the view never blocks the main thread on disk I/O — same discipline ResultsView uses (it only touches already-produced files). `segments` = count of non-empty lines in the TXT (cheap, drives pluralization).

DONE VIEW layout (reuse ResultsView idioms):
- Header HStack: Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) + Text("Готово: \(segments) \(Self.pluralSegments(segments))").bold(). If language != nil, a caption "распознан язык: \(language!.uppercased())".foregroundStyle(.secondary).
- Selectable preview: ScrollView { Text(text).font(.system(.callout)).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading) }.frame(maxHeight: 260) inside a RoundedRectangle(cornerRadius:8).fill(Color.secondary.opacity(0.06)). textSelection(.enabled) is the SAME modifier ResultsView already uses for its technical log, so selection/copy works natively.
- If srtWarning != nil: a small Label(srtWarning, systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) above the buttons (soft, non-fatal).
- Buttons HStack (reuse exact existing handlers):
    Button { NSWorkspace.shared.activateFileViewerSelecting([txtURL]) } label: { Label("Показать в Finder", systemImage:"folder") }   // selects the TXT inside the folder
    Button { NSWorkspace.shared.open(dir) } label: { Label("Открыть папку", systemImage:"arrow.up.forward.app") }
    Button { copyText(text) } label: { Label("Копировать текст", systemImage:"doc.on.doc") }
  copyText: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string). Optionally flip a @State `copied` to show a 1.5s "Скопировано" checkmark (DispatchQueue.main.asyncAfter).
- Wrap in .background(RoundedRectangle(cornerRadius:10).fill(Color.green.opacity(0.08))) exactly like doneView.

EMPTY VIEW (.empty): magnifyingglass.orange + Text("Речь не распознана").bold() + caption "В видео не обнаружено разборчивой речи. Проверьте, что в ролике есть голос." + Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } Label("Показать в Finder", "folder"). Same orange-tinted card as ResultsView.emptyView. (No "retry more sensitive" — whisper has no sensitivity knob analogous to threshold.)

ERROR VIEW: byte-for-byte the existing errorView(message:technical:) from ResultsView (red card + collapsible "Технический лог" with monospaced selectable ScrollView). Reuse it; do not reinvent.

CANCELLED: simple("Отменено.", icon:"xmark.circle", tint:.secondary) — identical helper to ResultsView.

SRT TIMECODE SANITY (static func, non-fatal): scan SRT text lines; a valid cue line matches regex `^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$`. Compute: arrowLines = lines containing " --> "; valid = arrowLines matching the regex; also verify monotonic non-decreasing start times. If arrowLines.isEmpty OR valid.count != arrowLines.count OR not monotonic → return srtWarning = "Файл субтитров (SRT) мог записаться с ошибкой таймкодов — проверьте перед использованием." Otherwise nil. This NEVER blocks .done; it only annotates. Parse a timecode to seconds for monotonic check by splitting on ':' and ','.

PLURALIZATION (add to TranscriptResultsView, copy the algorithm from ResultsView.pluralFrames): pluralSegments(n) → "фрагмент"/"фрагмента"/"фрагментов" (same mod10/mod100 rules). Used only in the header count.

@AppStorage additions (in ContentView for the transcript tab): "transcriptOutputFolderPath" (String, ""), "transcriptLanguage" (String, "auto") — language belongs to the engine slice but is declared here for the settings panel; this slice only consumes the resolved code for the caption. Do not reuse the frames "outputFolderPath" key (separate folders, separate persistence).

INTEGRATION POINT: ContentView gains a TabView (existing body becomes the «Кадры» tab; a new «Транскрипция» tab hosts the transcription input + a transcribe() function shaped like extract()). transcribe() builds outDir via the transcript-suffixed makeOutputDir, calls the sibling Transcriber engine, and on completion sets a @State transcriptResult: TranscriptResult and (mirroring extract()'s `NSWorkspace.shared.activateFileViewerSelecting([dir])` on .done) reveals the folder. TranscriptResultsView(result:) is rendered when transcriptResult != nil && !transcribing, exactly as ResultsView is gated by `if let result, !extracting`.


**Ключевые решения:**

- Mirror ResultsView's typed-state pattern exactly: a TranscriptResult enum with .done/.empty/.error/.cancelled, switched over in a dedicated TranscriptResultsView — no shared generic results component (keeps each tab's copy and affordances independent, matches existing style).
- whisper sidecars come from `-of <dir>/transcript -otxt -osrt` → transcript.txt + transcript.srt; `-of` MUST be extensionless (otherwise .txt.txt). Fixed basename 'transcript' keeps paths deterministic for the view.
- Output folder reuses ContentView.makeOutputDir verbatim except suffix '-transcript-<stamp>' (vs frames' bare '-<stamp>') so both tabs can write under the same parent without collision; separate @AppStorage key transcriptOutputFolderPath.
- TXT is read once on the engine's background completion and passed into the view as a ready String (not read in body) — same main-thread-safe discipline ResultsView follows; drives a textSelection(.enabled) scrollable preview (the exact modifier already used for the technical log).
- Reuse existing button handlers byte-for-byte: NSWorkspace.shared.activateFileViewerSelecting([txtURL]) for «Показать в Finder», NSWorkspace.shared.open(dir) for «Открыть папку»; add «Копировать текст» via NSPasteboard with a 1.5s «Скопировано» confirmation.
- Empty/no-speech is a real typed state (.empty), detected by a whitespace-only TXT after a 0-exit run, with a distinct Russian message «Речь не распознана» and NO retry-sensitivity button (whisper has no threshold analogue).
- SRT timecode sanity is non-fatal: a regex/monotonic check that only annotates .done with srtWarning, never downgrades the run to .error.

**Риски:**

- The Transcriber engine itself is a SEPARATE slice and does not yet exist in the tree; this slice must compile standalone. Mitigation: ship TranscriptResultsView + TranscriptResult + TabView scaffold and leave a TODO at the engine call site rather than inventing the engine, so «Кадры» build stays green.
- Exact whisper-cli sidecar naming depends on the bundled build; `-of` semantics (extensionless, whisper appends .txt/.srt) are correct for upstream whisper.cpp main/whisper-cli but must be confirmed against the bundled binary in the engine slice. If a future build changes naming, only the two URL constants change.
- Language caption depends on parsing whisper stderr ('auto-detected language: xx') which is an engine-slice responsibility; if unavailable, pass language=nil and simply omit the caption (graceful degradation).
- Large transcripts could make the SwiftUI Text preview heavy; capped via .frame(maxHeight:260) ScrollView, but extremely long single-Text rendering may still be costly — acceptable for typical marketing clips, revisit with TextEditor(.constant) if needed.
- activateFileViewerSelecting([txtURL]) selects the TXT specifically (nice UX), but if whisper wrote only the SRT or neither, the path may not exist — guarded because .done is only produced when the TXT exists and is non-empty; .empty/.error paths select the dir instead.

**Файлы (добавить/изменить):**

- Sources/SceneShot/Views/TranscriptResultsView.swift (NEW — TranscriptResult enum + TranscriptResultsView, modeled on ResultsView.swift: done/empty/error/cancelled, selectable TXT preview, 3 buttons, SRT sanity, pluralSegments)
- Sources/SceneShot/ContentView.swift (CHANGE — wrap body in TabView «Кадры»/«Транскрипция»; add @State transcriptResult/transcribing; add @AppStorage transcriptOutputFolderPath/transcriptLanguage; add transcribe() + makeTranscriptOutputDir() mirroring extract()/makeOutputDir; render TranscriptResultsView gated by `if let transcriptResult, !transcribing`)

**Команды:**

```bash
FAST=1 ./Scripts/build.sh
plutil -lint dist/SceneShot.app/Contents/Info.plist
codesign --verify --strict --verbose=1 dist/SceneShot.app
open dist/SceneShot.app
ls -la ~/Movies/SceneShot/*-transcript-*/
head -5 ~/Movies/SceneShot/*-transcript-*/transcript.srt
```

**Черновик промпта для этапа:**


```text
Реализуй вывод файлов и экран результата для вкладки «Транскрипция» (TXT + SRT, предпросмотр, сохранение). Это половина «результата» новой функции; движок whisper делает соседний слайс — здесь только запись файлов в нужную папку и UX результата. Следуй стилю существующего Sources/SceneShot/Views/ResultsView.swift и паттернам ContentView.swift (extract()/makeOutputDir).

ПАПКА ВЫВОДА (повтори ContentView.makeOutputDir, отличается только суффикс):
- stamp: тот же static DateFormatter с форматом "yyyy-MM-dd_HH-mm-ss".
- base: если новый @AppStorage("transcriptOutputFolderPath") НЕ пуст → URL(fileURLWithPath: …, isDirectory:true); иначе FileManager.default.urls(for:.moviesDirectory,in:.userDomainMask).first ?? homeDirectoryForCurrentUser/"Movies", затем .appendingPathComponent("SceneShot", isDirectory:true).
- итог: base.appendingPathComponent("\(name)-transcript-\(stamp)", isDirectory:true), где name = (source.displayName as NSString).deletingPathExtension.
- Суффикс ИМЕННО "-transcript-<stamp>" (у «Кадров» голый "-<stamp>"), чтобы папки двух вкладок не сталкивались.
- Создай папку: FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true).

ФАЙЛЫ WHISPER (важно — это контракт с соседним слайсом движка):
- whisper-cli пишет сайдкары по значению `-of` (путь БЕЗ расширения) + переключатели формата. Для папки outDir и basename "transcript" движок должен передать: `-otxt -osrt -of <outDir>/transcript`. whisper создаст РОВНО `<outDir>/transcript.txt` и `<outDir>/transcript.srt`. НЕ добавляй расширение к `-of` (иначе получишь transcript.txt.txt). Зафиксируй эти два пути константами basename="transcript": txtURL = outDir/"transcript.txt", srtURL = outDir/"transcript.srt".
- TXT — простой UTF-8, одна строка на фрагмент, без таймкодов. SRT — стандартный: индекс\nHH:MM:SS,mmm --> HH:MM:SS,mmm\nтекст\n\n.

ТИПИЗИРОВАННОЕ СОСТОЯНИЕ — новый файл Sources/SceneShot/Views/TranscriptResultsView.swift, по образцу ResultsView.swift:
  enum TranscriptResult {
      case done(dir: URL, txtURL: URL, srtURL: URL, text: String, segments: Int, language: String?, srtWarning: String?)
      case empty(dir: URL)
      case error(message: String, technical: String?)
      case cancelled
  }
  struct TranscriptResultsView: View { let result: TranscriptResult; … switch как в ResultsView }
- `text` читается ОДИН раз в фоновом completion движка (try String(contentsOf: txtURL, encoding:.utf8)), а не во вью — вью не должна блокировать главный поток дисковым I/O (как и ResultsView, которая трогает только уже готовые файлы).
- `segments` = число непустых строк в TXT.

ВИД .done (повтори идиомы ResultsView):
- Заголовок: Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) + Text("Готово: \(segments) \(Self.pluralSegments(segments))").bold(). Если language != nil — caption "распознан язык: \(language!.uppercased())".foregroundStyle(.secondary).
- Предпросмотр (прокручиваемый, ВЫДЕЛЯЕМЫЙ): ScrollView { Text(text).font(.system(.callout)).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading).padding(8) }.frame(maxHeight:260) внутри RoundedRectangle(cornerRadius:8).fill(Color.secondary.opacity(0.06)). Модификатор textSelection(.enabled) — тот же, что ResultsView уже применяет к техлогу.
- Если srtWarning != nil — выше кнопок Label(srtWarning, systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).
- Кнопки (переиспользуй точные обработчики из ResultsView):
    Button { NSWorkspace.shared.activateFileViewerSelecting([txtURL]) } label: { Label("Показать в Finder", systemImage:"folder") }
    Button { NSWorkspace.shared.open(dir) } label: { Label("Открыть папку", systemImage:"arrow.up.forward.app") }
    Button { copyText(text) } label: { Label(copied ? "Скопировано" : "Копировать текст", systemImage: copied ? "checkmark" : "doc.on.doc") }
  copyText(_:): NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType:.string); copied=true; DispatchQueue.main.asyncAfter(deadline:.now()+1.5){ copied=false }. (@State private var copied=false.)
- Обёртка: .padding(12).frame(maxWidth:.infinity).background(RoundedRectangle(cornerRadius:10).fill(Color.green.opacity(0.08))).

ВИД .empty: Image(systemName:"magnifyingglass").foregroundStyle(.orange) + Text("Речь не распознана").bold(); caption "В видео не обнаружено разборчивой речи. Проверьте, что в ролике есть голос."; Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label:{ Label("Показать в Finder", systemImage:"folder") }. Оранжевая карточка как emptyView. Без «повторить с большей чувствительностью».

ВИД .error: возьми ОДИН-В-ОДИН errorView(message:technical:) из ResultsView (красная карточка + сворачиваемый DisclosureGroup "Технический лог" с моноширинным ScrollView и textSelection(.enabled)).

ВИД .cancelled: helper simple("Отменено.", icon:"xmark.circle", tint:.secondary) — как в ResultsView.

ПУСТОЙ РЕЗУЛЬТАТ (детект): после успешного запуска (exit 0) прочитай TXT; если файла нет ИЛИ text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty → движок возвращает .empty(dir:outDir), а ContentView ставит TranscriptResult.empty. Иначе .done.

ПРОВЕРКА ТАЙМКОДОВ SRT (static func, НЕ фатальная):
  static func srtSanityWarning(_ srt: String) -> String? — раздели на строки; arrow = строки, содержащие " --> "; валидной считается строка, целиком matching `^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$` (NSRegularExpression или ручной разбор); проверь также, что старты не убывают (парси HH,MM,SS,mmm в секунды). Если arrow пуст, либо валидных меньше, чем arrow, либо старты убывают → верни "Файл субтитров (SRT) мог записаться с ошибкой таймкодов — проверьте перед использованием.". Иначе nil. Эта проверка НИКОГДА не превращает .done в ошибку — только заполняет srtWarning. SRT тоже читается в фоне в completion (try? String(contentsOf: srtURL)).

ПЛЮРАЛИЗАЦИЯ (добавь в TranscriptResultsView, скопируй алгоритм из ResultsView.pluralFrames):
  static func pluralSegments(_ n: Int) -> String { mod10/mod100 → "фрагмент"/"фрагмента"/"фрагментов" }

@AppStorage в ContentView для вкладки транскрипции (НЕ переиспользуй ключи «Кадров»):
  @AppStorage("transcriptOutputFolderPath") private var transcriptOutputFolderPath = ""
  @AppStorage("transcriptLanguage") private var transcriptLanguage = "auto"   // потребляется движком; здесь только для caption языка
language для caption: если движок вернул определённый язык (из stderr whisper строки "auto-detected language: ru" или из выбранного кода), прокинь его в .done(language:); если "auto" и не определён — nil.

ИНТЕГРАЦИЯ (минимально, чтобы слайс компилировался и показывался):
- Преврати тело ContentView в TabView с двумя вкладками: существующий UX → .tabItem { Label("Кадры", systemImage:"film.stack") }; новая вкладка «Транскрипция» → .tabItem { Label("Транскрипция", systemImage:"text.bubble") }.
- Во вкладке «Транскрипция» добавь @State private var transcriptResult: TranscriptResult? и @State private var transcribing = false, и рендери `if let transcriptResult, !transcribing { TranscriptResultsView(result: transcriptResult) }` — так же, как «Кадры» гейтят `if let result, !extracting`.
- Функция transcribe() по форме как extract(): строит outDir транскрипт-суффиксом, зовёт соседний движок Transcriber (его сигнатуру определяет другой слайс; ожидай async throws → enum с .done(dir,txtURL,srtURL,text,segments,language,srtWarning)/.empty(dir)/.cancelled), на .done вызывает NSWorkspace.shared.activateFileViewerSelecting([dir]) (как extract() на .done) и ставит transcriptResult. Ошибки маппь через describeError() в .error(message,technical).
- ЕСЛИ движок Transcriber ещё не существует в дереве — НЕ создавай его здесь; вместо этого временно заполни transcriptResult фиктивным .done из реально записанных whisper-файлов недоступно, поэтому ограничься компиляцией TranscriptResultsView + TranscriptResult и TabView-каркасом, оставив TODO-комментарий в месте вызова Transcriber. Не ломай сборку «Кадров».

Никаких stderr-дампов в лицо пользователю (только в сворачиваемом «Техническом логе»). Все подписи — на русском. Абсолютные пути в коде не хардкодить — только через FileManager, как в makeOutputDir.
```

**Критерии приёмки:**

- ./Scripts/build.sh (или FAST=1 ./Scripts/build.sh) собирает dist/SceneShot.app без ворнингов; codesign --verify проходит. Окно показывает TabView с вкладками «Кадры» и «Транскрипция»; вкладка «Кадры» работает как раньше (регрессий нет).
- После успешной транскрипции в папке ~/Movies/SceneShot/<имя>-transcript-<stamp>/ лежат РОВНО два файла: transcript.txt и transcript.srt (никаких transcript.txt.txt). При заданном «Папка вывода» (transcriptOutputFolderPath) файлы пишутся туда; stamp в формате yyyy-MM-dd_HH-mm-ss.
- Экран результата .done показывает: счётчик "Готово: N фрагмент/фрагмента/фрагментов" (проверь N=1→«фрагмент», N=2→«фрагмента», N=5→«фрагментов»), прокручиваемый предпросмотр текста, в котором текст МОЖНО ВЫДЕЛИТЬ мышью и скопировать (Cmd+C), и три рабочие кнопки.
- «Показать в Finder» открывает Finder с выделенным transcript.txt; «Открыть папку» открывает саму папку; «Копировать текст» кладёт весь текст в буфер обмена (проверка: вставить в TextEdit) и на ~1.5 с меняет подпись на «Скопировано».
- Видео без речи (или whisper выдал пустой TXT при exit 0) даёт состояние .empty с заголовком «Речь не распознана» и оранжевой карточкой, БЕЗ кнопки «повторить с большей чувствительностью»; кнопка «Показать в Finder» работает.
- Корректный SRT (валидные таймкоды HH:MM:SS,mmm --> HH:MM:SS,mmm, не убывающие старты) → srtWarning == nil, предупреждение не показывается. Искусственно испорченный SRT (битый таймкод или нет ни одной строки "-->") → показывается оранжевое предупреждение про SRT, но результат ОСТАЁТСЯ .done (не превращается в ошибку).
- Ошибка движка показывается коротким русским текстом + сворачиваемый «Технический лог» с моноширинным выделяемым stderr; никакого сырого stderr вне лога. Отмена даёт состояние «Отменено.».
- Чтение TXT/SRT происходит в фоне (в completion движка), UI при больших файлах не подвисает; во вью передаётся уже готовая строка text.
- В коде нет захардкоженных абсолютных путей — папка строится через FileManager (как ContentView.makeOutputDir); ключи @AppStorage транскрипции отдельны от ключей «Кадров».


---


## Срез F-packaging


**Измерение:** Build / packaging / signing / DMG / licensing for the bundled whisper.cpp binary + ggml-base model


**Резюме:** This slice extends the existing hand-assembled-.app pipeline to bundle a CPU-only whisper.cpp CLI (whisper-cli) per-arch plus the ~150 MB ggml-base.bin model, sign them under hardened runtime, ship the license, and grow the DMG to ~280 MB — all while preserving the project's gold-standard "pinned URL + sha256, no moving-latest" convention from fetch-ffmpeg.sh.

Exact files touched (all paths absolute under /Users/anatoliivovchok/Desktop/scenedetector):
- NEW  Scripts/fetch-whisper.sh        — downloads whisper-cli per arch + ggml-base.bin, pinned URL+sha256, FORCE refresh, verify loop (mirrors fetch-ffmpeg.sh exactly).
- EDIT Scripts/build.sh                — extend the Helpers copy/chmod/ad-hoc-sign name filter to include whisper-cli; add a Models copy block; bundle WHISPER-LICENSE.txt.
- EDIT Scripts/sign.sh                 — extend the nested-binary find name filter to include whisper-cli (Developer ID path).
- EDIT Scripts/make-dmg.sh             — copy Resources/WHISPER-LICENSE.txt into the DMG stage.
- NEW  Resources/WHISPER-LICENSE.txt   — MIT (whisper.cpp) + model attribution, Russian, mirrors FFMPEG-LICENSE.txt tone.
- NEW  Resources/Models/ggml-base.bin  — produced by fetch-whisper.sh (gitignored / fetched, like Helpers/*).
- NEW  Resources/Helpers/<arch>/whisper-cli (x2) — produced by fetch-whisper.sh.
- EDIT Resources/SceneShot.entitlements— DECISION: NO new entitlement needed (documented inline); CPU/GGML whisper does not JIT.
- EDIT README.md, PLAN.md              — fetch-whisper step, ~280 MB DMG note, model pin note, license section, structure table.

KEY DECISION (entitlements): A CPU-only ggml-base whisper-cli does NOT need com.apple.security.cs.allow-jit nor com.apple.security.cs.allow-unsigned-executable-memory. The GGML CPU backend runs precompiled NEON/AVX SIMD kernels; it never maps writable+executable (W^X) memory. Only the Metal/Core ML GPU backends would — and those are explicitly NOT used (offline, zero-config, CPU). The existing com.apple.security.cs.disable-library-validation is sufficient and is exactly what already lets the separately-signed nested ffmpeg launch under hardened runtime. I add an explanatory comment + commented-out fallback rather than a live JIT entitlement (least-privilege; avoids a notarization-attention flag).

KEY DECISION (per-arch, NOT universal): whisper-cli is bundled as a single-arch Mach-O under Helpers/arm64/ and Helpers/x86_64/ — identical to ffmpeg/ffprobe. The Swift FFmpeg.swift toolURL already resolves per-arch from Bundle.main via #if arch(arm64). The model ggml-base.bin is arch-independent → one copy under Resources/Models/ (NOT duplicated per arch), saving ~150 MB.

KEY DECISION (model pin): pin the ggml-base.bin download to a commit-pinned raw Hugging Face URL (resolve/<commit-sha>/ggml-base.bin) + sha256, NOT resolve/main/, exactly to dodge the moving-latest time-bomb the fetch-ffmpeg.sh header warns about.


**Технические детали:**

=== A) EXISTING-CODE FACTS THAT DRIVE THE DIFFS ===

1) build.sh lines 62-67 copy+chmod ONLY ffmpeg/ffprobe by name:
     find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' \) -exec chmod +x {} \;
   The `cp -R "$ROOT/Resources/Helpers/." ...` ALREADY copies whisper-cli too (it copies everything under Helpers), so only the chmod name-filter must grow. Likewise the ad-hoc codesign at lines 77-79 uses the same name filter → must grow or whisper-cli ships unsigned and Gatekeeper kills the nested launch.

2) sign.sh lines 26-29 (Developer ID path) find nested binaries by:
     find "$APP/Contents/Resources/Helpers" -type f \( -name ffmpeg -o -name ffprobe \)
   → must grow to include whisper-cli, else notarization fails ("unsigned nested code").
   NOTE: the ad-hoc branch of sign.sh ($IDENTITY = "-") signs each `$f` from the same find, so the single filter edit covers both branches.

3) make-dmg.sh line 15 copies FFMPEG-LICENSE.txt only. Add a sibling line for WHISPER-LICENSE.txt.

4) Resources/Models/ does NOT exist. build.sh has no Models block at all.

5) ffmpeg helpers are single-arch Mach-O (verified: lipo -archs Helpers/arm64/ffmpeg → arm64). whisper-cli must match this per-arch layout.

6) notarize.sh notarizes the whole dist/SceneShot.dmg generically → NO change needed for whisper.

=== B) EXACT DIFFS ===

--- Scripts/build.sh ---
(b1) Grow the chmod filter (line 66). Replace:
    find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' \) -exec chmod +x {} \;
with:
    find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' \) -exec chmod +x {} \;

(b2) Grow the ad-hoc codesign filter (line 78). Replace:
    find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' \) -exec codesign -s - --force {} \;
with:
    find "$APP/Contents/Resources/Helpers" -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'whisper-cli' \) -exec codesign -s - --force {} \;

(b3) Add a Models copy block — insert AFTER the Helpers `fi` (after line 67), BEFORE the AppIcon line:
    # Bundled whisper.cpp model (added with the Транскрипция tab). Arch-independent → one copy.
    if [ -d "$ROOT/Resources/Models" ]; then
        log "bundling whisper model"
        mkdir -p "$APP/Contents/Resources/Models"
        cp -R "$ROOT/Resources/Models/." "$APP/Contents/Resources/Models/"
    fi

(b4) Bundle the whisper license — insert AFTER the FFMPEG-LICENSE copy (after line 73):
    [ -f "$ROOT/Resources/WHISPER-LICENSE.txt" ] && cp "$ROOT/Resources/WHISPER-LICENSE.txt" "$APP/Contents/Resources/WHISPER-LICENSE.txt"

--- Scripts/sign.sh ---
(s1) Grow the nested-binary find (line 28). Replace:
    < <(find "$APP/Contents/Resources/Helpers" -type f \( -name ffmpeg -o -name ffprobe \))
with:
    < <(find "$APP/Contents/Resources/Helpers" -type f \( -name ffmpeg -o -name ffprobe -o -name whisper-cli \))
(Comment on line 25 can read: "Nested helper binaries (ffmpeg, ffprobe, whisper-cli) MUST be signed before the app bundle.")
NOTE: the model ggml-base.bin is plain data, NOT a Mach-O — it is correctly NOT in the find and must NOT be code-signed; it is covered by the app bundle's seal as a resource.

--- Scripts/make-dmg.sh ---
(d1) Insert AFTER line 15 (the FFMPEG-LICENSE copy):
    [ -f "Resources/WHISPER-LICENSE.txt" ] && cp "Resources/WHISPER-LICENSE.txt" "$STAGE/WHISPER-LICENSE.txt"

--- Resources/SceneShot.entitlements (DECISION: keep as-is, add explanatory comment) ---
Replace the existing comment block so the rationale is recorded. New content:
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Not sandboxed. The app launches bundled, separately-signed helpers (ffmpeg, ffprobe,
         whisper-cli); this entitlement keeps the hardened runtime from blocking that under
         Developer ID signing. -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <!-- NOTE: whisper-cli here is CPU-only (ggml-base, no Metal/Core ML). The GGML CPU backend
         runs precompiled NEON/AVX kernels and never maps W^X (writable+executable) memory, so it
         needs NEITHER com.apple.security.cs.allow-jit NOR
         com.apple.security.cs.allow-unsigned-executable-memory. If a future Metal/Core ML build is
         ever bundled, add allow-jit then (and re-test notarization). -->
</dict>
</plist>

--- Scripts/fetch-whisper.sh (NEW, mode 0755) ---
Mirror fetch-ffmpeg.sh structure exactly: pinned VERSION, url_for(), expected_sha(), FORCE refresh, verify loop, host smoke test. Full content:

#!/usr/bin/env bash
# Download static whisper.cpp CLI (whisper-cli) for macOS arm64 + x86_64 into
# Resources/Helpers/<arch>/, and the ggml BASE model into Resources/Models/.
#
# LICENSE NOTE: whisper.cpp is MIT (no copyleft) — far simpler than ffmpeg's GPL.
# Ship WHISPER-LICENSE.txt for attribution. The ggml-base model is OpenAI Whisper (MIT)
# converted by the whisper.cpp project; attribution is in the same license file.
#
# Re-run with FORCE=1 to refresh existing files.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HELPERS="$ROOT/Resources/Helpers"
MODELS="$ROOT/Resources/Models"

# Pinned exact build so URL + sha256 always describe the SAME artifact (no moving /latest/).
WHISPER_VERSION="v1.7.4"   # <-- pin to a real tag at implementation time, then re-pin sha256 below

# whisper-cli binary, per arch. Pin to the release-asset URL for WHISPER_VERSION.
url_for_bin() { # <arch>
    case "$1" in
        arm64)  echo "https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}/whisper-cli-macos-arm64";;
        x86_64) echo "https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}/whisper-cli-macos-x86_64";;
        *) echo "";;
    esac
}
# Model: commit-PINNED raw URL (NOT resolve/main/) to dodge the moving-latest time-bomb.
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/<COMMIT_SHA>/ggml-base.bin"

# Pinned sha256 — re-pin if you bump WHISPER_VERSION or the model commit.
sha_bin() { case "$1" in
    arm64)  echo "<SHA256_ARM64_WHISPER_CLI>";;
    x86_64) echo "<SHA256_X86_64_WHISPER_CLI>";;
    *) echo "";; esac; }
MODEL_SHA="<SHA256_GGML_BASE_BIN>"

ARCHS=(arm64 x86_64)

fetch_bin() { # <arch>
    local arch="$1" url dest tmp
    url="$(url_for_bin "$arch")"; [ -n "$url" ] || { echo "ERROR: no URL for $arch" >&2; exit 1; }
    dest="$HELPERS/$arch/whisper-cli"
    if [ "${FORCE:-0}" != "1" ] && [ -x "$dest" ]; then echo "  $arch/whisper-cli present (FORCE=1 to refresh)"; return; fi
    mkdir -p "$HELPERS/$arch"; tmp="$(mktemp -d)"
    echo "  downloading $arch/whisper-cli ..."
    curl -fsSL -m 600 -o "$tmp/whisper-cli" "$url"
    mv "$tmp/whisper-cli" "$dest"; chmod +x "$dest"; rm -rf "$tmp"
}

fetch_model() {
    local dest="$MODELS/ggml-base.bin" tmp
    if [ "${FORCE:-0}" != "1" ] && [ -f "$dest" ]; then echo "  ggml-base.bin present (FORCE=1 to refresh)"; return; fi
    mkdir -p "$MODELS"; tmp="$(mktemp -d)"
    echo "  downloading ggml-base.bin (~150 MB) ..."
    curl -fsSL -m 1200 -o "$tmp/ggml-base.bin" "$MODEL_URL"
    mv "$tmp/ggml-base.bin" "$dest"; rm -rf "$tmp"
}

for arch in "${ARCHS[@]}"; do fetch_bin "$arch"; done
fetch_model

echo "== sha256 verify =="
fail=0
for arch in "${ARCHS[@]}"; do
    f="$HELPERS/$arch/whisper-cli"; got="$(shasum -a 256 "$f" | awk '{print $1}')"; want="$(sha_bin "$arch")"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then printf "  %-7s whisper-cli MISMATCH\n    expected %s\n    got      %s\n" "$arch" "$want" "$got"; fail=1
    else printf "  %-7s whisper-cli OK %s\n" "$arch" "$got"; fi
done
mf="$MODELS/ggml-base.bin"; mgot="$(shasum -a 256 "$mf" | awk '{print $1}')"
if [ -n "$MODEL_SHA" ] && [ "$MODEL_SHA" != "$mgot" ]; then printf "  model   ggml-base   MISMATCH\n    expected %s\n    got      %s\n" "$MODEL_SHA" "$mgot"; fail=1
else printf "  model   ggml-base   OK %s\n" "$mgot"; fi
[ "$fail" = "0" ] || { echo "ERROR: checksum verification failed" >&2; exit 1; }

host="$(uname -m)"
echo "== host ($host) whisper-cli version =="
"$HELPERS/$host/whisper-cli" --help 2>/dev/null | head -1 || echo "  (cannot run host binary)"
echo "done -> $HELPERS , $MODELS"

IMPLEMENTATION NOTE on the placeholders: at build time the agent must (1) pick a real whisper.cpp release tag that publishes macOS arm64 + x86_64 whisper-cli assets — if the chosen release does NOT ship prebuilt per-arch macOS binaries, fall back to building from source with `cmake -B build -DGGML_METAL=OFF -DWHISPER_BUILD_TESTS=OFF && cmake --build build -j --config Release` per arch (output build/bin/whisper-cli), which guarantees the CPU-only no-JIT property this slice relies on; (2) resolve the model commit sha via `curl -sI https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin` then pin that commit in MODEL_URL; (3) download once and paste the four real sha256 values (run shasum -a 256). The model is ~148 MB; the per-arch whisper-cli is ~1-3 MB each.

--- Resources/WHISPER-LICENSE.txt (NEW) ---
whisper.cpp и модель распознавания речи — лицензия
==================================================

В состав SceneShot входит исполняемый файл whisper-cli (проект whisper.cpp,
автор Georgi Gerganov и контрибьюторы), распространяемый под лицензией MIT.

Исходный код:
  • https://github.com/ggml-org/whisper.cpp

Модель ggml-base.bin — это модель OpenAI Whisper, конвертированная в формат GGML
проектом whisper.cpp. Веса Whisper распространяются под лицензией MIT.
  • https://github.com/openai/whisper
  • https://huggingface.co/ggerganov/whisper.cpp

Текст лицензии MIT:
  • https://opensource.org/license/mit/

Примечание
----------
SceneShot вызывает whisper-cli как отдельный исполняемый процесс (не линкуется с
ним) и использует его только для офлайн-распознавания речи в видео с выдачей
текста (TXT) и субтитров (SRT). Распознавание выполняется локально, на CPU;
данные никуда не отправляются.

=== C) DMG SIZE ===
Current ffmpeg-only DMG: 4 helper binaries totaling ~314 MB raw, UDZO-compressed to whatever it is now. Adding whisper-cli (~2-6 MB total both arches) + ggml-base.bin (~148 MB, ALREADY heavily quantized binary → near-incompressible under UDZO) raises the compressed DMG by roughly the model's full size. Net expected DMG: ~280 MB (matches the brief). make-dmg.sh already prints `du -h` of the result at line 32 — no change needed to surface the size, but README/PLAN must state the ~280 MB expectation so reviewers don't think the build is broken.

=== D) WHY NOTHING ELSE CHANGES ===
- notarize.sh: notarizes the whole DMG; content-agnostic. No change.
- release.sh: orchestrates build→sign→dmg→notarize; the edits above flow through. No change.
- The `cp -R Resources/Helpers/.` in build.sh already copies whisper-cli (only chmod/sign filters needed widening) — minimal-surface change.
- Info.plist: no new keys (model/binary are plain bundle resources; the Swift engine slice resolves them from Bundle.main).


**Ключевые решения:**

- ENTITLEMENTS: NO new entitlement. CPU-only ggml-base whisper-cli runs precompiled NEON/AVX SIMD kernels and never maps W^X memory → needs neither com.apple.security.cs.allow-jit nor allow-unsigned-executable-memory. Existing com.apple.security.cs.disable-library-validation already suffices (it is what lets the separately-signed nested ffmpeg launch under hardened runtime). Record the rationale in an entitlements comment + a commented-out fallback for any future Metal/Core ML build. This is least-privilege and avoids an extra notarization-attention flag.
- PER-ARCH binary, NOT universal: whisper-cli ships as single-arch Mach-O under Helpers/arm64/ and Helpers/x86_64/ — identical to ffmpeg/ffprobe (verified single-arch via lipo). The Swift toolURL already resolves per-arch from Bundle.main via #if arch(arm64).
- MODEL is arch-independent → ONE ggml-base.bin under Resources/Models/, NOT duplicated per arch (saves ~150 MB and one chmod headache).
- MODEL PIN: download from a commit-pinned Hugging Face raw URL (resolve/<commit-sha>/ggml-base.bin) + sha256, never resolve/main/ — exactly the moving-latest time-bomb the fetch-ffmpeg.sh header warns about.
- MINIMAL-SURFACE build.sh edit: `cp -R Resources/Helpers/.` already copies whisper-cli; only the chmod and ad-hoc-codesign NAME FILTERS need widening (add -o -name whisper-cli). Add a small Models copy block + a WHISPER-LICENSE copy line.
- SIGN ORDER preserved: whisper-cli is added to the SAME nested-binary find that already signs ffmpeg/ffprobe BEFORE the app bundle (one filter edit covers both the ad-hoc and Developer ID branches of sign.sh).
- ggml-base.bin is DATA, not code: it is deliberately excluded from the codesign find (signing data is wrong) and is instead sealed as a bundle resource — tampering breaks the app's codesign --verify.
- LICENSE: whisper.cpp is MIT (no copyleft) — much lighter than ffmpeg's GPL. Ship a short Russian WHISPER-LICENSE.txt with whisper.cpp + OpenAI-Whisper-model attribution; bundle it (build.sh) and put it in the DMG (make-dmg.sh).
- notarize.sh and release.sh are UNCHANGED: notarize operates on the whole DMG (content-agnostic) and release just orchestrates the edited scripts.
- NEW fetch-whisper.sh mirrors fetch-ffmpeg.sh 1:1 (pinned VERSION/URL/sha256, FORCE refresh, verify loop, host smoke test) so it matches repo convention and is reviewable at a glance.

**Риски:**

- whisper.cpp releases may NOT publish prebuilt macOS arm64 + x86_64 whisper-cli assets for every tag (asset naming/availability varies across versions). Mitigation baked into fetch-whisper.sh notes: if no per-arch release asset exists, build from source per arch with `cmake -B build -DGGML_METAL=OFF -DWHISPER_BUILD_TESTS=OFF -DCMAKE_OSX_ARCHITECTURES=<arch>` (output build/bin/whisper-cli). The -DGGML_METAL=OFF is mandatory to preserve the CPU-only / no-JIT property the entitlements decision relies on.
- CLI NAME drift: whisper.cpp renamed the CLI from `main` to `whisper-cli`. If the chosen release still ships `main`, either rename on fetch to whisper-cli (keep the bundle path stable for the Swift engine slice) or the engine slice must agree on the name. Pin a recent enough version to get whisper-cli.
- DMG bloat: ggml-base.bin (~148 MB) is near-incompressible under UDZO, so the DMG jumps to ~280 MB. If that is too big for distribution, a later option is to NOT bundle the model and fetch-on-first-run — but the LOCKED decision is offline/zero-config bundling, so this slice bundles it and just documents the size.
- GPU entitlement regret: if anyone later swaps in a Metal/Core ML whisper build to speed things up, it WILL map W^X memory and Gatekeeper/hardened-runtime will kill it without com.apple.security.cs.allow-jit. The entitlements comment + fallback note flags this so it is not a silent surprise.
- Notarization size/time: a ~280 MB DMG takes longer to upload to Apple's notary service; notarytool --wait may need patience. No code change, just operator expectation.
- sha256 placeholders: fetch-whisper.sh ships with <SHA256...>/<COMMIT_SHA> placeholders that MUST be replaced with real values at implementation time; acceptance criteria explicitly grep for leftover placeholders to prevent shipping an unverifiable fetch script.
- Per-arch whisper-cli from GitHub releases might itself be a universal binary in some releases; the acceptance check `lipo -archs` enforces single-arch to match the ffmpeg convention — if upstream ships universal, run `lipo -extract` per arch or accept universal (harmless but doubles ~2-6 MB; the model dwarfs it anyway).

**Файлы (добавить/изменить):**

- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/fetch-whisper.sh (NEW, 0755)
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/build.sh (EDIT: widen chmod+ad-hoc-sign name filters to include whisper-cli; add Models copy block; copy WHISPER-LICENSE.txt)
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/sign.sh (EDIT: widen nested-binary find to include whisper-cli; update comment)
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/make-dmg.sh (EDIT: copy WHISPER-LICENSE.txt into DMG stage)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/SceneShot.entitlements (EDIT: keep disable-library-validation only; add comment recording the no-JIT decision)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/WHISPER-LICENSE.txt (NEW)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Models/ggml-base.bin (NEW, fetched by fetch-whisper.sh; ~150 MB)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/whisper-cli (NEW, fetched)
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/x86_64/whisper-cli (NEW, fetched)
- /Users/anatoliivovchok/Desktop/scenedetector/README.md (EDIT: fetch-whisper step, ~280 MB DMG note, whisper license section, structure table)
- /Users/anatoliivovchok/Desktop/scenedetector/PLAN.md (EDIT: §3 structure, §4 prerequisites, §8 risks)

**Команды:**

```bash
./Scripts/fetch-whisper.sh
FORCE=1 ./Scripts/fetch-whisper.sh
lipo -archs Resources/Helpers/arm64/whisper-cli
lipo -archs Resources/Helpers/x86_64/whisper-cli
./Scripts/build.sh
test -x dist/SceneShot.app/Contents/Resources/Helpers/arm64/whisper-cli && echo OK-arm64
test -x dist/SceneShot.app/Contents/Resources/Helpers/x86_64/whisper-cli && echo OK-x86_64
test -f dist/SceneShot.app/Contents/Resources/Models/ggml-base.bin && echo OK-model
test -f dist/SceneShot.app/Contents/Resources/WHISPER-LICENSE.txt && echo OK-license
lipo -archs dist/SceneShot.app/Contents/MacOS/SceneShot
./Scripts/sign.sh
codesign --verify --deep --strict --verbose=2 dist/SceneShot.app
codesign -dv dist/SceneShot.app/Contents/Resources/Helpers/arm64/whisper-cli
grep -n 'resolve/main' Scripts/fetch-whisper.sh || echo NO-MOVING-LATEST
grep -c 'allow-jit\|allow-unsigned-executable-memory' Resources/SceneShot.entitlements
./Scripts/make-dmg.sh
du -h dist/SceneShot.dmg
hdiutil attach dist/SceneShot.dmg -nobrowse -mountpoint /tmp/ssdmg && ls -la /tmp/ssdmg && ls /tmp/ssdmg/SceneShot.app/Contents/Resources/Helpers/*/whisper-cli && hdiutil detach /tmp/ssdmg
./Scripts/release.sh
```

**Черновик промпта для этапа:**


```text
Этап W-PKG — Упаковка, подпись, DMG и лицензии для вшитого whisper.cpp + модели

Контекст: SceneShot собирается БЕЗ Xcode (только Command Line Tools), .app собирается вручную в Scripts/build.sh (swiftc + lipo), подписывается ad-hoc или Developer ID в Scripts/sign.sh, упаковывается в DMG в Scripts/make-dmg.sh. Вшитые бинарники ffmpeg/ffprobe лежат по-архитектурно в Resources/Helpers/<arch>/ (каждый — одноархитектурный Mach-O, НЕ universal). Добавляем офлайн-транскрипцию через whisper.cpp: бинарник whisper-cli (по-архитектурно) + модель ggml-base.bin (~150 МБ, общая для всех арх).

Все пути абсолютные относительно корня репозитория.

1) СОЗДАЙ Scripts/fetch-whisper.sh (chmod 0755), ТОЧНО по образцу Scripts/fetch-ffmpeg.sh (прочитай его сначала): pinned VERSION + pinned URL + pinned sha256, поддержка FORCE=1, цикл проверки sha256 с exit 1 при несовпадении, смоук-тест хост-бинарника в конце. Скрипт качает:
   - whisper-cli под arm64 и x86_64 в Resources/Helpers/arm64/whisper-cli и Resources/Helpers/x86_64/whisper-cli (chmod +x, одноархитектурные Mach-O — как ffmpeg);
   - ggml-base.bin в Resources/Models/ggml-base.bin (ОДНА копия, модель архитектурно-независима).
   ВАЖНО про пины:
   - Для whisper-cli выбери реальный тег релиза whisper.cpp (репозиторий github.com/ggml-org/whisper.cpp), у которого ОПУБЛИКОВАНЫ готовые macOS-ассеты arm64 и x86_64. Если готовых per-arch бинарников в релизе НЕТ — собери из исходников per arch: `cmake -B build -DGGML_METAL=OFF -DWHISPER_BUILD_TESTS=OFF -DCMAKE_OSX_ARCHITECTURES=<arch> && cmake --build build -j --config Release`, бинарник окажется в build/bin/whisper-cli. Флаг -DGGML_METAL=OFF ОБЯЗАТЕЛЕН — нам нужен CPU-only бинарник (см. пункт 4 про entitlements).
   - Для модели пинуй URL на КОНКРЕТНЫЙ коммит Hugging Face (resolve/<commit-sha>/ggml-base.bin), НЕ resolve/main/ — иначе sha поедет, как предупреждает шапка fetch-ffmpeg.sh. Коммит узнай: curl -sI https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin.
   - Скачай всё один раз и впиши РЕАЛЬНЫЕ sha256 (shasum -a 256) — четыре значения (две арх бинарника + модель… модель одна, итого три sha).

2) ОТРЕДАКТИРУЙ Scripts/build.sh:
   (a) В строке chmod для Helpers (сейчас `\( -name 'ffmpeg' -o -name 'ffprobe' \)`) ДОБАВЬ `-o -name 'whisper-cli'`.
   (b) В строке ad-hoc codesign для Helpers — то же самое: добавь `-o -name 'whisper-cli'`.
   (c) СРАЗУ ПОСЛЕ блока копирования Helpers (после его `fi`) добавь блок копирования модели:
       if [ -d "$ROOT/Resources/Models" ]; then
           log "bundling whisper model"
           mkdir -p "$APP/Contents/Resources/Models"
           cp -R "$ROOT/Resources/Models/." "$APP/Contents/Resources/Models/"
       fi
   (d) Рядом со строкой копирования FFMPEG-LICENSE.txt добавь копирование WHISPER-LICENSE.txt:
       [ -f "$ROOT/Resources/WHISPER-LICENSE.txt" ] && cp "$ROOT/Resources/WHISPER-LICENSE.txt" "$APP/Contents/Resources/WHISPER-LICENSE.txt"
   (`cp -R Resources/Helpers/.` уже копирует whisper-cli — менять его НЕ нужно, только фильтры chmod/codesign.)

3) ОТРЕДАКТИРУЙ Scripts/sign.sh: в find вложенных бинарников (сейчас `\( -name ffmpeg -o -name ffprobe \)`) ДОБАВЬ `-o -name whisper-cli`. Модель ggml-base.bin — это данные, НЕ Mach-O: НЕ подписывай её отдельно (она покрывается печатью бандла как ресурс). Обнови комментарий: "Nested helper binaries (ffmpeg, ffprobe, whisper-cli) MUST be signed before the app bundle."

4) ОТРЕДАКТИРУЙ Resources/SceneShot.entitlements — РЕШЕНИЕ: новых entitlement НЕ добавляем. CPU-only whisper (ggml-base, без Metal/Core ML) выполняет предкомпилированные NEON/AVX-ядра и НЕ мапит W^X-память, поэтому НЕ нужны ни com.apple.security.cs.allow-jit, ни com.apple.security.cs.allow-unsigned-executable-memory. Существующего com.apple.security.cs.disable-library-validation достаточно (он же позволяет запускать отдельно подписанный ffmpeg под hardened runtime). Замени комментарий, чтобы зафиксировать это решение, и добавь закомментированную заметку-фоллбэк: если когда-нибудь будет вшит Metal/Core ML-бинарник — тогда добавить allow-jit и перепроверить нотаризацию. Точный текст — в technicalDetails.

5) ОТРЕДАКТИРУЙ Scripts/make-dmg.sh: рядом со строкой копирования FFMPEG-LICENSE.txt в $STAGE добавь:
   [ -f "Resources/WHISPER-LICENSE.txt" ] && cp "Resources/WHISPER-LICENSE.txt" "$STAGE/WHISPER-LICENSE.txt"

6) СОЗДАЙ Resources/WHISPER-LICENSE.txt — MIT whisper.cpp + атрибуция модели Whisper (OpenAI, MIT), на русском, в тоне Resources/FFMPEG-LICENSE.txt. Текст — в technicalDetails.

7) ОБНОВИ README.md и PLAN.md:
   - README «Сборка»: добавь шаг `./Scripts/fetch-whisper.sh` рядом с fetch-ffmpeg; в таблице структуры добавь `Helpers/<arch>/whisper-cli` и `Models/ggml-base.bin`, упомяни fetch-whisper в списке скриптов.
   - README «Распространение»: припиши, что DMG теперь ~280 МБ (вшита модель распознавания речи ~150 МБ).
   - README: добавь раздел «Лицензия whisper.cpp» (MIT, ссылки) по образцу раздела ffmpeg.
   - PLAN.md: в §3 (структура репозитория) добавь Helpers/<arch>/whisper-cli, Resources/Models/ggml-base.bin, Scripts/fetch-whisper.sh; в §8 (риски) добавь пункт про пин модели/бинарника whisper и размер DMG ~280 МБ; в §4 (предусловия) добавь fetch-whisper.sh как разовый шаг.

8) НЕ трогай Scripts/notarize.sh и Scripts/release.sh — notarize нотаризует весь DMG (контент-агностично), release просто оркеструет изменённые скрипты.

Проверка: ./Scripts/fetch-whisper.sh проходит sha-верификацию; ./Scripts/release.sh (или build→sign→make-dmg) даёт dist/SceneShot.dmg ~280 МБ, внутри .app есть Contents/Resources/Helpers/arm64/whisper-cli, Contents/Resources/Helpers/x86_64/whisper-cli, Contents/Resources/Models/ggml-base.bin, Contents/Resources/WHISPER-LICENSE.txt; codesign --verify --deep --strict проходит; с CODESIGN_IDENTITY=Developer ID нотаризация проходит.
```

**Критерии приёмки:**

Слайс считается выполненным, когда ВСЕ пункты верны (команды запускать из корня репозитория, пути абсолютные):

1) ПИНЫ (no moving-latest):
   - `grep -n "resolve/main" Scripts/fetch-whisper.sh` НИЧЕГО не находит (модель пинется на конкретный commit-sha, не main).
   - В Scripts/fetch-whisper.sh заданы реальные (не плейсхолдер `<...>`) sha256 для arm64/whisper-cli, x86_64/whisper-cli и ggml-base.bin; `grep -n "<SHA256" Scripts/fetch-whisper.sh` пусто.
   - `./Scripts/fetch-whisper.sh` завершается с кодом 0 и печатает "OK" для всех трёх артефактов; при искусственной порче sha (или FORCE=1 с битым URL) завершается с кодом != 0 (как fetch-ffmpeg.sh).

2) АРХИТЕКТУРА И НАЛИЧИЕ:
   - `lipo -archs Resources/Helpers/arm64/whisper-cli` → `arm64`; `lipo -archs Resources/Helpers/x86_64/whisper-cli` → `x86_64` (per-arch, НЕ universal — как ffmpeg).
   - `test -f Resources/Models/ggml-base.bin` истинно; модель присутствует РОВНО в одном месте (нет Helpers/<arch>/ggml-base.bin).

3) СБОРКА БАНДЛА (./Scripts/build.sh, универсальная):
   - В собранном dist/SceneShot.app существуют: Contents/Resources/Helpers/arm64/whisper-cli (+x), Contents/Resources/Helpers/x86_64/whisper-cli (+x), Contents/Resources/Models/ggml-base.bin, Contents/Resources/WHISPER-LICENSE.txt, Contents/Resources/FFMPEG-LICENSE.txt.
   - `test -x dist/SceneShot.app/Contents/Resources/Helpers/arm64/whisper-cli` истинно (бит исполнения выставлен).
   - `lipo -archs dist/SceneShot.app/Contents/MacOS/SceneShot` → `arm64 x86_64`.

4) ПОДПИСЬ:
   - Ad-hoc (по умолчанию): `codesign --verify --deep --strict --verbose=2 dist/SceneShot.app` проходит; `codesign -dv dist/SceneShot.app/Contents/Resources/Helpers/arm64/whisper-cli` показывает валидную подпись (whisper-cli подписан как вложенный бинарник, НЕ остался неподписанным).
   - ggml-base.bin отдельно НЕ подписан (это ресурс-данные), но входит в печать бандла: модификация байта в модели после подписи ломает `codesign --verify` всего .app.
   - С `CODESIGN_IDENTITY="Developer ID Application: …"`: `./Scripts/sign.sh` подписывает whisper-cli ПЕРЕД .app (порядок виден в выводе), `codesign --verify --deep --strict` проходит, нет ошибок "unsigned nested code".

5) ENTITLEMENTS (решение зафиксировано):
   - `grep -c "allow-jit\|allow-unsigned-executable-memory" Resources/SceneShot.entitlements` → 0 живых ключей (могут присутствовать только в комментарии-фоллбэке). disable-library-validation остаётся.
   - В Resources/SceneShot.entitlements есть комментарий, объясняющий, почему CPU-only whisper не требует JIT-entitlement.

6) DMG:
   - `./Scripts/make-dmg.sh` создаёт dist/SceneShot.dmg; при монтировании внутри присутствует WHISPER-LICENSE.txt рядом с FFMPEG-LICENSE.txt и КАК-ОТКРЫТЬ.txt.
   - Размер dist/SceneShot.dmg ≈ 280 МБ (в диапазоне ~250–320 МБ — модель почти не сжимается); README/PLAN явно называют ~280 МБ.
   - Внутри SceneShot.app в смонтированном DMG присутствуют оба whisper-cli и ggml-base.bin.

7) ПОЛНЫЙ ПАЙПЛАЙН:
   - `./Scripts/release.sh` (без env Developer ID) проходит до конца: build → sign (ad-hoc) → dmg → notarize (печатает "нотаризация пропущена"); на выходе валидно подписанный универсальный dist/SceneShot.dmg, содержащий whisper-cli для ОБЕИХ архитектур + модель + обе лицензии.
   - Scripts/notarize.sh и Scripts/release.sh НЕ изменялись (git diff по ним пуст).

8) ДОКУМЕНТАЦИЯ:
   - README.md содержит шаг `./Scripts/fetch-whisper.sh`, раздел лицензии whisper.cpp, упоминание размера DMG ~280 МБ, обновлённую таблицу структуры (whisper-cli + ggml-base.bin).
   - PLAN.md §3/§4/§8 обновлены (структура, предусловия, риск пина+размера).


---


## Срез G-testing


**Измерение:** Testing strategy, edge cases, performance


**Резюме:** Testing/edge-case/performance slice for the new «Транскрипция» tab (whisper.cpp, bundled ggml base model, TXT+SRT). I READ PLAN.md (§7 checklist, FFmpeg cheatsheet) and SceneExtractor.swift / FFmpeg.swift to match repo conventions, and I executed the audio-prep half of the headless test against the REAL bundled ffmpeg to confirm the exact commands work.

VERIFIED LOCALLY (this machine, arm64, macOS 26.5, 10 cores): `say -o /tmp/clip.aiff "Привет, это тест транскрипции."` produces a 1.70s AIFF; piping it through the bundled ffmpeg at /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/ffmpeg with `-ar 16000 -ac 1 -c:a pcm_s16le` yields /tmp/clip.wav probed as codec_name=pcm_s16le, sample_rate=16000, channels=1 — exactly whisper.cpp's required input. whisper-cli is NOT installed locally, so its half is specified from spec, not executed.

KEY GROUNDING FACTS for the implementing agent: bundled ffmpeg is GPL 8.1.1 (martin-riedl.de), has `-fps_mode vfr` (5.1+); binaries are arch-resolved from Bundle.main.resourceURL/Helpers/<arch>/{ffmpeg,ffprobe} via FFmpeg.toolURL (#if arch(arm64) -> arm64 else x86_64). There is NO Tests/ dir and Package.swift declares only the executable target (no test target) — so tests are SHELL scripts (Scripts/test-transcribe.sh), matching how the repo already validates via build.sh acceptance criteria, NOT XCTest. The Process wrapper (FFmpeg.launch) drains stdout+stderr concurrently via Pipe.readabilityHandler on background queues with a 3-enter DispatchGroup (stdout EOF / stderr EOF / termination) and cancels via Running.cancel()->process.terminate(); the whisper engine MUST reuse this exact pattern. whisper.cpp writes its progress + detected-language lines to STDERR (parse there), and prints transcript to stdout; SRT/TXT are written by `-osrt -otxt -of <prefix>`.

Decision: the engine (WhisperTranscriber.swift) should mirror SceneExtractor.swift one-to-one — build args, launch via the shared Process wrapper, parse progress from a stderr stream, cancel via terminate, collect output files (TXT+SRT) at the end. Whisper needs a SEPARATE tool enum case + a model-path resolver (Helpers/Models/ggml-base.bin) and a separate launch path because FFmpeg.swift's FFmpegTool enum only knows ffmpeg/ffprobe.


**Технические детали:**

TOOLING / PATHS (exact):
- Bundled ffmpeg (arm64): /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/ffmpeg ; (x86_64): .../Helpers/x86_64/ffmpeg. Version 8.1.1, GPL.
- whisper binary to bundle: Resources/Helpers/<arch>/whisper-cli (modern name; old name was `main`). Add a fetch+build script Scripts/fetch-whisper.sh that builds both arches and pins sha256, mirroring Scripts/fetch-ffmpeg.sh (pinned URLs, expected_sha(), chmod +x, host-arch smoke `whisper-cli --help`).
- Bundled model: Resources/Helpers/Models/ggml-base.bin (~142 MB, ggml BASE, multilingual — NOT base.en, since Russian is required). Resolved at runtime from Bundle.main.resourceURL/Helpers/Models/ggml-base.bin. build.sh must copy Resources/Helpers/Models/ into Contents/Resources/Helpers/Models/.

ENGINE CONTRACT (WhisperTranscriber.swift, mirrors SceneExtractor.swift):
- Step 1 (audio prep) reuses FFmpeg.shared.launch(.ffmpeg, args:[...]) to make a 16k mono s16le WAV in a temp dir: ["-y","-hide_banner","-nostats","-i",source.ffmpegInput,"-vn","-ar","16000","-ac","1","-c:a","pcm_s16le","-progress","pipe:1", wavURL.path]. For remote, prepend the SAME reconnect flags SceneExtractor uses. Progress 0..1 from stdout out_time / durationSeconds (reuse SceneExtractor.parseProgress/parseHMS verbatim).
- Step 2 (transcribe) launches whisper-cli. Because FFmpeg.FFmpegTool only has ffmpeg/ffprobe, add a parallel minimal runner OR extend the wrapper. Recommended args:
  whisper-cli -m <model> -f <wav> -l <auto|ru> -t <threads> -otxt -osrt -of <outPrefix> -pp
  where outPrefix has NO extension (whisper appends .txt/.srt). `-pp` prints progress to stderr as "whisper_print_progress_callback: progress = NN%"; parse NN -> 0..1. Detected language appears on stderr as "auto-detected language: ru (p = ...)". Forced Russian = `-l ru`; auto = `-l auto`. Threads: default to min(physicalCores, 8); on this machine sysctl hw.physicalcpu=10 -> use 8.
- Cancellation: store the Running handle (FFmpeg.Running) and call .cancel(); whisper-cli handles SIGTERM and exits; delete the partial temp WAV and any half-written .txt/.srt.
- Output collection: after exit 0, read <outPrefix>.txt and <outPrefix>.srt; if .txt is empty or whitespace-only -> the «почти пусто» (music/non-speech) branch.

HEADLESS TEST — EXACT COMMANDS (Scripts/test-transcribe.sh; arm64 path shown, parametrize ARCH):
  set -euo pipefail
  ROOT=/Users/anatoliivovchok/Desktop/scenedetector
  ARCH=$(uname -m)
  FF="$ROOT/Resources/Helpers/$ARCH/ffmpeg"
  WH="$ROOT/Resources/Helpers/$ARCH/whisper-cli"
  MODEL="$ROOT/Resources/Helpers/Models/ggml-base.bin"
  TMP=$(mktemp -d)
  # 1) real Russian speech via macOS say  (VERIFIED: makes 1.70s AIFF)
  say -o "$TMP/clip.aiff" "Привет, это тест транскрипции."
  # 2) ffmpeg -> 16k mono s16le wav  (VERIFIED: codec_name=pcm_s16le sample_rate=16000 channels=1)
  "$FF" -y -hide_banner -loglevel error -i "$TMP/clip.aiff" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/clip.wav"
  # 3) whisper-cli -> TXT + SRT, forced Russian for determinism
  "$WH" -m "$MODEL" -f "$TMP/clip.wav" -l ru -t 8 -otxt -osrt -of "$TMP/clip"
  # 4) assertions
  grep -qi "тест" "$TMP/clip.txt"          # TXT contains a spoken word
  grep -qiE "привет|транскрип" "$TMP/clip.txt"
  grep -qE "[0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3}" "$TMP/clip.srt"  # SRT timecodes
  test -s "$TMP/clip.srt" && test -s "$TMP/clip.txt"
  echo "OK"; rm -rf "$TMP"
(Note: whisper may transcribe "тест" or normalize punctuation/case; assertions are case-insensitive and OR-grouped to tolerate minor recognition variance. If the grep on a single word is too brittle across model variance, assert that .txt is non-empty AND .srt has >=1 timecode line — that is the load-bearing guarantee.)

PERFORMANCE (base model, CPU, Apple Silicon):
- whisper.cpp base on M-series CPU runs ~5-12x faster than realtime with 4-8 threads (e.g. 1 min audio -> ~5-12s). On this 10-core machine expect the top of that range. Intel x86_64 is markedly slower (~1.5-4x realtime) — long videos on Intel are the real ETA concern.
- Threads: throughput saturates around physical core count; more threads than physical cores hurts. Use min(hw.physicalcpu, 8).
- Memory: base model resident footprint ~250-400 MB (model ~142 MB on disk + working state); flat regardless of audio length because whisper processes in 30s windows — long videos do NOT blow up RAM, but DO take long, so ETA matters.
- Metal: whisper.cpp can use Metal/Core ML, but for the BASE model on CPU the win is modest and adds bundling/signing complexity (Core ML needs a separate ~/Library cache + an encoder model). Recommendation: ship CPU-only (zero-config, offline, both arches identical code path); Metal is NOT worth it for base. Document as a deferred optimization.

EDGE CASES (each maps to a UI state in the idle/probing/working/done/empty/error/cancelled machine):
- No-audio video: ffprobe shows no audio stream OR step-1 WAV is empty -> short Russian error «В этом видео нет звуковой дорожки» (do NOT run whisper). Test: ffmpeg make a silent-video-no-audio mp4 (`-f lavfi -i color=c=black:s=320x240:d=2 -an out.mp4`) and assert the early-out.
- Music/non-speech: whisper returns empty/garbage -> .txt empty -> «Речь не распознана (возможно, в видео нет голоса)» empty-state. Test: a tone (`-f lavfi -i sine=frequency=440:duration=5`) -> expect near-empty TXT.
- Language auto vs forced ru: auto = `-l auto` (parse "auto-detected language:"); forced = `-l ru`. Test asserts the say-clip with `-l auto` detects ru.
- Very long video: assert progress advances monotonically and ETA shows; assert RAM stays bounded (model windows). Smoke with a synthesized ~10-min audio (loop the say clip).
- Cancel mid-run: terminate() during step 2; assert process gone, temp WAV + partial outputs cleaned, UI returns to idle.
- Missing model fallback: rename/remove ggml-base.bin -> resolver returns nil -> Russian error «Не найдена модель распознавания. Переустановите приложение.» (mirrors FFmpegError.toolMissing copy). Test: run with a bogus -m path, assert non-zero exit handled.
- Both architectures: run the whole test-transcribe.sh under arm64 and (Rosetta/Intel) x86_64 by parametrizing ARCH; assert identical pass.

REPO-CONVENTION NOTES: there is no XCTest target; follow the existing pattern of shell-based acceptance scripts under Scripts/. All user-facing strings stay Russian and short, matching FFmpegError.errorDescription style (human message in UI, raw stderr only in the collapsible «Технический лог»).


**Ключевые решения:**

- Tests are SHELL scripts under Scripts/ (Scripts/test-transcribe.sh), NOT XCTest — verified there is no Tests/ dir and Package.swift has no test target; this matches the repo's existing acceptance-by-script convention.
- Use the MULTILINGUAL ggml base model (ggml-base.bin), not base.en, because Russian transcription is a locked requirement.
- Ship CPU-only; explicitly DEFER Metal/Core ML — for the base model the speedup is modest and Core ML adds a separate encoder model + cache + signing complexity, conflicting with offline/zero-config.
- Audio prep (->16k mono s16le WAV) reuses the existing FFmpeg.shared.launch(.ffmpeg,...) wrapper; only the whisper-cli step needs a new runner since FFmpegTool enum is ffmpeg/ffprobe-only.
- Threads = min(hw.physicalcpu, 8); over-subscribing past physical cores hurts whisper throughput.
- Parse whisper PROGRESS and detected-LANGUAGE from STDERR (not stdout) using `-pp`; outputs via `-otxt -osrt -of <prefix-without-ext>`.
- Headless assertions are tolerance-aware (case-insensitive, OR-grouped words) with the load-bearing guarantee being non-empty TXT + >=1 SRT timecode, to survive base-model recognition variance.
- VERIFIED the say->ffmpeg->16k-mono-s16le half end-to-end against the real bundled ffmpeg (codec_name=pcm_s16le, sample_rate=16000, channels=1); whisper-cli half is spec-derived since it is not installed locally.

**Риски:**

- whisper-cli is NOT installed on this machine, so its exact flag set and stderr progress format are spec-derived (current whisper.cpp) — the implementing agent must run `whisper-cli --help` after fetch-whisper.sh and reconcile flag names (e.g. -pp / --print-progress, -of, -otxt/-osrt) before finalizing test-transcribe.sh.
- Base-model recognition of a 1.7s synthetic `say` clip may normalize words/punctuation; a strict single-word grep could be flaky. Mitigation already baked in: OR-grouped case-insensitive match plus the hard guarantee of non-empty TXT + a valid SRT timecode line.
- SRT timecode separator is a comma (HH:MM:SS,mmm) per spec, but the regex also accepts a dot to be safe across builds.
- Bundling whisper-cli + a 142 MB model grows the .app and DMG substantially and adds two more binaries to ad-hoc/Developer-ID signing (sign.sh) and Gatekeeper scope — must be signed BEFORE the .app like the ffmpeg helpers.
- x86_64 leg must be run via `arch -x86_64` / Rosetta on this Apple-Silicon machine; if Rosetta is absent the Intel test can only be validated on real Intel hardware.
- Static cross-arch whisper.cpp builds are not as turnkey as the martin-riedl ffmpeg downloads — fetch-whisper.sh may need to compile from source per-arch (cmake) rather than download a prebuilt, so pinning sha256 of self-built binaries is less reproducible than for ffmpeg.

**Файлы (добавить/изменить):**

- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/test-transcribe.sh
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/fetch-whisper.sh
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/whisper-cli
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/x86_64/whisper-cli
- /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/Models/ggml-base.bin
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/build.sh
- /Users/anatoliivovchok/Desktop/scenedetector/Scripts/sign.sh
- /Users/anatoliivovchok/Desktop/scenedetector/PLAN.md
- /Users/anatoliivovchok/Desktop/scenedetector/Sources/SceneShot/Engine/WhisperTranscriber.swift

**Команды:**

```bash
say -o /tmp/clip.aiff "Привет, это тест транскрипции."
/Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/ffmpeg -y -hide_banner -loglevel error -i /tmp/clip.aiff -vn -ar 16000 -ac 1 -c:a pcm_s16le /tmp/clip.wav
/Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/ffprobe -v error -show_entries stream=codec_name,sample_rate,channels -of default=noprint_wrappers=1 /tmp/clip.wav
/Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/whisper-cli -m /Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/Models/ggml-base.bin -f /tmp/clip.wav -l ru -t 8 -otxt -osrt -of /tmp/clip
grep -qiE "тест|привет|транскрип" /tmp/clip.txt && echo TXT_OK
grep -qE "[0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3}" /tmp/clip.srt && echo SRT_OK
/Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/ffmpeg -f lavfi -i color=c=black:s=320x240:d=2 -an -y /tmp/noaudio.mp4
/Users/anatoliivovchok/Desktop/scenedetector/Resources/Helpers/arm64/ffmpeg -f lavfi -i sine=frequency=440:duration=5 -y /tmp/tone.wav
./Scripts/test-transcribe.sh
./Scripts/fetch-whisper.sh
arch -x86_64 ./Scripts/test-transcribe.sh
```

**Черновик промпта для этапа:**


```text
Добавь чеклист и автотест для вкладки «Транскрипция» (whisper.cpp, вшитая модель ggml base, вывод TXT + SRT). Стиль и шаблоны бери из существующего кода: движок повторяет Sources/SceneShot/Engine/SceneExtractor.swift, запуск процессов — через Sources/SceneShot/Engine/FFmpeg.swift (одновременный дренаж stdout+stderr, DispatchGroup, отмена через terminate). Тестов XCTest в проекте НЕТ и тест-таргета в Package.swift НЕТ — поэтому тест делаем ШЕЛЛ-скриптом Scripts/test-transcribe.sh (как остальные acceptance-проверки в Scripts/).

1) Создай Scripts/test-transcribe.sh (chmod +x, set -euo pipefail). Он использует РЕАЛЬНУЮ речь через macOS say, вшитый ffmpeg и вшитый whisper-cli. Параметризуй ARCH=$(uname -m), чтобы тот же скрипт гонять и на arm64, и на x86_64 (под Rosetta). Точные шаги (раздел 1-2 уже проверены на этой машине и работают):

  ROOT=/Users/anatoliivovchok/Desktop/scenedetector
  ARCH=$(uname -m)
  FF="$ROOT/Resources/Helpers/$ARCH/ffmpeg"
  WH="$ROOT/Resources/Helpers/$ARCH/whisper-cli"
  MODEL="$ROOT/Resources/Helpers/Models/ggml-base.bin"
  TMP=$(mktemp -d)
  say -o "$TMP/clip.aiff" "Привет, это тест транскрипции."
  "$FF" -y -hide_banner -loglevel error -i "$TMP/clip.aiff" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/clip.wav"
  # подтверди формат (должно быть pcm_s16le / 16000 / 1):
  "$ROOT/Resources/Helpers/$ARCH/ffprobe" -v error -show_entries stream=codec_name,sample_rate,channels -of default=noprint_wrappers=1 "$TMP/clip.wav"
  "$WH" -m "$MODEL" -f "$TMP/clip.wav" -l ru -t 8 -otxt -osrt -of "$TMP/clip"
  # ПРОВЕРКИ:
  test -s "$TMP/clip.txt"   # TXT не пустой
  test -s "$TMP/clip.srt"   # SRT не пустой
  grep -qiE "тест|привет|транскрип" "$TMP/clip.txt"   # есть распознанные слова
  grep -qE "[0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3}" "$TMP/clip.srt"  # есть таймкоды
  echo "PASS"; rm -rf "$TMP"
  trap 'rm -rf "$TMP"' EXIT
Если grep по одному слову окажется хрупким из-за вариативности модели — оставь как обязательное только: TXT непустой И в SRT есть >=1 строка таймкода (это и есть гарантируемый контракт).

2) Создай Scripts/fetch-whisper.sh по образцу Scripts/fetch-ffmpeg.sh: качает/собирает whisper-cli в Resources/Helpers/arm64/ и Resources/Helpers/x86_64/ (chmod +x), и качает модель ggml-base.bin (мультиязычная BASE, ~142 МБ, НЕ base.en) в Resources/Helpers/Models/ggml-base.bin. Пин версий и sha256 (expected_sha()), как для ffmpeg. В конце — smoke хост-арки: "$WH" --help | head -1.

3) build.sh: при сборке бандла копируй Resources/Helpers/<arch>/whisper-cli и Resources/Helpers/Models/ в Contents/Resources/Helpers/<arch>/ и Contents/Resources/Helpers/Models/. sign.sh: подписывай whisper-cli как остальные вложенные бинарники ПЕРЕД .app.

4) Добавь в PLAN.md §7 новый блок «Чеклист тестирования — Транскрипция» (галочки):
  - [ ] Реальная речь (say -> ffmpeg 16k mono -> whisper-cli): TXT содержит слова, SRT содержит таймкоды (Scripts/test-transcribe.sh PASS).
  - [ ] Видео без звука: ранний выход, текст «В этом видео нет звуковой дорожки», whisper не запускается. (Проверка: ffmpeg -f lavfi -i color=c=black:s=320x240:d=2 -an /tmp/noaudio.mp4)
  - [ ] Музыка/не-речь: почти пустой результат -> состояние «Речь не распознана». (Проверка: ffmpeg -f lavfi -i sine=frequency=440:duration=5 /tmp/tone.wav)
  - [ ] Язык: авто (-l auto, парсинг «auto-detected language:») и принудительный русский (-l ru).
  - [ ] Очень длинное видео: прогресс растёт монотонно, показывается ETA, память не растёт (whisper обрабатывает окнами по 30с). (Смоук: склей say-клип в ~10 минут.)
  - [ ] Отмена в середине: процесс whisper останавливается (terminate), временный WAV и недописанные .txt/.srt удаляются, UI возвращается в idle.
  - [ ] Нет модели: убери/переименуй ggml-base.bin -> понятная ошибка «Не найдена модель распознавания. Переустановите приложение.»
  - [ ] Обе архитектуры: Scripts/test-transcribe.sh PASS на Apple Silicon и на Intel (под Rosetta).
  - [ ] Производительность: base на Apple Silicon ~5-12x быстрее реального времени (8 потоков); на Intel заметно медленнее — ETA обязателен.

5) Движок WhisperTranscriber.swift (по образцу SceneExtractor.swift), на что обратить внимание в тестах:
  - Шаг 1: подготовка аудио через FFmpeg.shared.launch(.ffmpeg, args: ["-y","-hide_banner","-nostats","-i",source.ffmpegInput,"-vn","-ar","16000","-ac","1","-c:a","pcm_s16le","-progress","pipe:1", wav]) (для remote — те же reconnect-флаги, что в SceneExtractor). Прогресс 0..1 из stdout out_time/duration (переиспользуй SceneExtractor.parseProgress).
  - Шаг 2: whisper-cli -m <model> -f <wav> -l <auto|ru> -t <min(physicalcpu,8)> -otxt -osrt -of <prefix> -pp. Прогресс парси из STDERR «progress = NN%»; определённый язык — из stderr «auto-detected language:». prefix без расширения (whisper сам добавит .txt/.srt).
  - Отмена: храни FFmpeg.Running, .cancel() -> terminate(); подчисти temp.
  - Пустой TXT (только пробелы) -> empty-состояние.
  - Все тексты ошибок — короткие, на русском (как FFmpegError.errorDescription); raw stderr только в сворачиваемый «Технический лог».

Критерий приёмки: ./Scripts/fetch-whisper.sh кладёт whisper-cli (обе арки) и Models/ggml-base.bin с верными sha256; ./Scripts/test-transcribe.sh печатает PASS на обеих архитектурах; ./Scripts/build.sh кладёт whisper-cli и модель в бандл, sign.sh подписывает whisper-cli; чеклист §7 (Транскрипция) пройден.
```

**Критерии приёмки:**

1) HEADLESS REAL-SPEECH TEST: `./Scripts/test-transcribe.sh` prints PASS. Internally it runs `say -o /tmp/...aiff "Привет, это тест транскрипции."` -> bundled ffmpeg `-vn -ar 16000 -ac 1 -c:a pcm_s16le` (VERIFIED on this machine: output probes codec_name=pcm_s16le, sample_rate=16000, channels=1) -> bundled whisper-cli `-m ggml-base.bin -f clip.wav -l ru -otxt -osrt -of clip`, and ASSERTS: clip.txt is non-empty, clip.srt is non-empty, clip.txt matches /тест|привет|транскрип/i, clip.srt contains >=1 line matching /\d\d:\d\d:\d\d[,.]\d{3} --> \d\d:\d\d:\d\d[,.]\d{3}/.
2) BOTH ARCHITECTURES: the same script passes under arm64 and under x86_64 (Rosetta), resolving binaries from Resources/Helpers/<arch>/ and the model from Resources/Helpers/Models/ggml-base.bin.
3) EDGE CASES each produce the correct Russian UI state (no relitigation of the state machine — reuse idle/probing/working/done/empty/error/cancelled): no-audio video -> early error «В этом видео нет звуковой дорожки» without launching whisper; music/tone -> empty-state «Речь не распознана»; -l auto detects ru on the say-clip; -l ru forces Russian; cancel mid-run terminates whisper and deletes temp WAV + partial .txt/.srt; missing model -> «Не найдена модель распознавания. Переустановите приложение.».
4) LONG VIDEO: progress advances monotonically with a visible ETA and RSS stays bounded (model processes in 30s windows — RAM is flat vs length).
5) PERFORMANCE documented and met: base model on Apple Silicon CPU runs >=4x realtime with threads=min(hw.physicalcpu,8); resident memory ~250-400 MB; Metal/Core ML explicitly deferred (CPU-only ships, both arches identical). Intel is slower, so ETA is mandatory, not optional.
6) PACKAGING: ./Scripts/fetch-whisper.sh fetches whisper-cli (both arches) + ggml-base.bin with pinned sha256; build.sh copies whisper-cli and Models/ into the bundle; sign.sh signs whisper-cli before the .app. PLAN.md §7 gains the «Транскрипция» checklist and it is fully checked.


---
