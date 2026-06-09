#!/usr/bin/env bash
# Build a universal (arm64+x86_64) whisper.cpp CLI from source and download the ggml-base model
# into Resources/Helpers/<arch>/whisper-cli and Resources/Models/ggml-base.bin.
#
# WHY FROM SOURCE: whisper.cpp ships no official runnable universal macOS CLI artifact to pin, so a
# source build is the only deterministic, license-clean path. whisper.cpp is MIT.
#
# CLT-ONLY / CPU-ONLY: Metal shader tooling (metal/metallib) is absent under Command Line Tools, so
# the build MUST be CPU-only (-DGGML_METAL=OFF). cmake is required (install once: brew install cmake;
# Homebrew lives at ~/.brew). git + make are already present in CLT.
#
# Re-run with FORCE=1 to rebuild/redownload. Set LIPO_FALLBACK is the default (per-arch + lipo);
# set SINGLE_CONFIGURE=1 to instead use one multi-arch cmake configure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HELPERS="$ROOT/Resources/Helpers"
MODELS="$ROOT/Resources/Models"
BUILD="$ROOT/dist/.build/whisper"
SRC="$BUILD/whisper.cpp"

WHISPER_REF="v1.7.4"   # pinned tag; bump deliberately
ARCHS=(arm64 x86_64)

# --- model pin -------------------------------------------------------------
# ggml-org publishes no model checksum, so we pin size now and sha-on-first-fetch (like fetch-ffmpeg.sh).
MODEL_URL="https://huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.bin"
MODEL_URL_FALLBACK="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
EXPECTED_SIZE=147951465
EXPECTED_SHA256="60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"

log() { printf '==> %s\n' "$*"; }

# --- prerequisites ---------------------------------------------------------
if ! command -v cmake >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        log "cmake missing — installing via Homebrew"
        brew install cmake
    else
        echo "ERROR: cmake required. Install Homebrew (~/.brew) then: brew install cmake" >&2
        exit 1
    fi
fi
command -v git  >/dev/null 2>&1 || { echo "ERROR: git not found (xcode-select --install)" >&2; exit 1; }

# --- clone -----------------------------------------------------------------
if [ "${FORCE:-0}" = "1" ]; then rm -rf "$SRC"; fi
if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$BUILD"
    log "clone whisper.cpp $WHISPER_REF"
    git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp "$SRC"
else
    log "whisper.cpp source present ($SRC)"
fi

CMAKE_COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    -DGGML_METAL=OFF
    -DGGML_METAL_EMBED_LIBRARY=OFF
    -DWHISPER_COREML=OFF
    -DGGML_NATIVE=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DBUILD_SHARED_LIBS=OFF
)

FAT="$BUILD/whisper-cli-universal"

build_per_arch() {
    local slices=()
    for arch in "${ARCHS[@]}"; do
        local bdir="$BUILD/build-$arch"
        log "configure+build $arch"
        # Single non-empty config array avoids bash-3.2 empty-array + set -u issues.
        local cfg=("${CMAKE_COMMON[@]}" -DCMAKE_OSX_ARCHITECTURES="$arch")
        if [ "$arch" = "x86_64" ]; then cfg+=(-DGGML_AVX=OFF -DGGML_AVX2=OFF); fi  # generic baseline
        cmake -S "$SRC" -B "$bdir" "${cfg[@]}" >/dev/null
        cmake --build "$bdir" --config Release -j --target whisper-cli >/dev/null
        local bin
        bin="$(find "$bdir" -type f -name whisper-cli | head -1)"
        [ -n "$bin" ] || { echo "ERROR: whisper-cli not produced for $arch" >&2; exit 1; }
        slices+=("$bin")
    done
    lipo -create "${slices[@]}" -output "$FAT"
}

build_single_configure() {
    local bdir="$BUILD/build-universal"
    log "configure+build universal (single configure)"
    cmake -S "$SRC" -B "$bdir" "${CMAKE_COMMON[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" >/dev/null
    cmake --build "$bdir" --config Release -j --target whisper-cli >/dev/null
    local bin
    bin="$(find "$bdir" -type f -name whisper-cli | head -1)"
    [ -n "$bin" ] || { echo "ERROR: whisper-cli not produced" >&2; exit 1; }
    cp "$bin" "$FAT"
}

if [ "${SINGLE_CONFIGURE:-0}" = "1" ]; then build_single_configure; else build_per_arch; fi

# --- assert static linkage -------------------------------------------------
# Only the indented dependency lines matter; skip otool's path/"(architecture …)" headers.
# Allowed: system libs only (/usr/lib, /System/Library — libSystem, Accelerate, libc++).
log "otool -L (deps must be /usr/lib + /System/Library only)"
if otool -L "$FAT" | grep -E '^[[:space:]]' | grep -Eqv '/usr/lib/|/System/Library/'; then
    echo "ERROR: whisper-cli has unexpected dynamic deps (expected system-only):" >&2
    otool -L "$FAT" >&2
    exit 1
fi
otool -L "$FAT" | grep -E '^[[:space:]]' | sort -u | sed 's/^/    /'

# --- install binary into both arch dirs ------------------------------------
for arch in "${ARCHS[@]}"; do
    mkdir -p "$HELPERS/$arch"
    cp "$FAT" "$HELPERS/$arch/whisper-cli"
    chmod +x "$HELPERS/$arch/whisper-cli"
done
log "lipo -info: $(lipo -info "$HELPERS/arm64/whisper-cli" | sed 's/.*: //')"

# --- model -----------------------------------------------------------------
mkdir -p "$MODELS"
MODEL="$MODELS/ggml-base.bin"
need_model=1
if [ "${FORCE:-0}" != "1" ] && [ -f "$MODEL" ]; then
    sz="$(stat -f%z "$MODEL" 2>/dev/null || echo 0)"
    [ "$sz" = "$EXPECTED_SIZE" ] && need_model=0
fi
if [ "$need_model" = "1" ]; then
    log "download ggml-base.bin (~142 MiB)"
    if ! curl -fL --retry 3 -m 1200 -o "$MODEL" "$MODEL_URL"; then
        log "primary URL failed, trying fallback host"
        curl -fL --retry 3 -m 1200 -o "$MODEL" "$MODEL_URL_FALLBACK"
    fi
else
    log "model present (size ok; FORCE=1 to refresh)"
fi

sz="$(stat -f%z "$MODEL" 2>/dev/null || echo 0)"
if [ "$sz" != "$EXPECTED_SIZE" ]; then
    echo "ERROR: ggml-base.bin size $sz != expected $EXPECTED_SIZE (truncated/blocked download?)" >&2
    exit 1
fi
got_sha="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
if [ "$EXPECTED_SHA256" = "REPLACE_AFTER_FIRST_FETCH" ]; then
    echo "!! ACTION REQUIRED: pin the model sha256 in Scripts/fetch-whisper.sh:"
    echo "!!   EXPECTED_SHA256=\"$got_sha\""
elif [ "$EXPECTED_SHA256" != "$got_sha" ]; then
    echo "ERROR: ggml-base.bin sha256 mismatch" >&2
    echo "  expected $EXPECTED_SHA256" >&2
    echo "  got      $got_sha" >&2
    exit 1
else
    echo "  model sha256 OK $got_sha"
fi

# --- sanity ----------------------------------------------------------------
host="$(uname -m)"
log "host ($host) whisper-cli --help"
"$HELPERS/$host/whisper-cli" --help 2>/dev/null | head -1 || echo "  (cannot run host binary)"
echo "done -> $HELPERS/<arch>/whisper-cli + $MODEL"
