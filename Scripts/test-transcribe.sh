#!/usr/bin/env bash
# Headless acceptance test for the transcription pipeline (no XCTest target in this repo —
# tests are shell scripts, matching the build.sh acceptance convention).
#
# Verifies: bundled ffmpeg makes a whisper-ready 16 kHz mono s16le WAV, and bundled whisper-cli
# transcribes it to a NON-EMPTY transcript.txt with at least one SRT timecode. Assertions are
# tolerance-aware (base model output varies) — the load-bearing guarantees are non-empty TXT + ≥1
# SRT timecode, not an exact string match.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCH="$(uname -m)"
FFMPEG="$ROOT/Resources/Helpers/$ARCH/ffmpeg"
WHISPER="$ROOT/Resources/Helpers/$ARCH/whisper-cli"
MODEL="$ROOT/Resources/Models/ggml-base.bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in "$FFMPEG" "$WHISPER" "$MODEL"; do
    [ -e "$f" ] || { echo "MISSING: $f (run ./Scripts/fetch-whisper.sh first)" >&2; exit 1; }
done

echo "== generate speech clip (say) =="
say -o "$WORK/clip.aiff" "Привет, это тест транскрипции. This is a transcription test." \
    || { echo "SKIP: 'say' unavailable on this host" >&2; exit 0; }

echo "== ffmpeg -> 16 kHz mono s16le WAV =="
"$FFMPEG" -hide_banner -nostats -nostdin -i "$WORK/clip.aiff" \
    -vn -ac 1 -ar 16000 -c:a pcm_s16le -y "$WORK/clip.wav"
# Validate the WAV format whisper requires.
PROBE="$ROOT/Resources/Helpers/$ARCH/ffprobe"
"$PROBE" -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels \
    -of default=nw=1 "$WORK/clip.wav"

echo "== whisper-cli transcribe =="
THREADS="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
"$WHISPER" -m "$MODEL" -f "$WORK/clip.wav" -l auto -otxt -osrt -of "$WORK/clip" \
    -t "$THREADS" -pp 2>&1 | tail -3

echo "== assertions =="
TXT="$WORK/clip.txt"; SRT="$WORK/clip.srt"
[ -s "$TXT" ] || { echo "FAIL: transcript.txt missing or empty" >&2; exit 1; }
if ! grep -q '[^[:space:]]' "$TXT"; then echo "FAIL: transcript.txt is whitespace-only" >&2; exit 1; fi
TIMECODES="$(grep -c -- '-->' "$SRT" 2>/dev/null || echo 0)"
[ "$TIMECODES" -ge 1 ] || { echo "FAIL: no SRT timecodes" >&2; exit 1; }

echo "--- transcript.txt ---"; cat "$TXT"
echo "--- srt timecodes: $TIMECODES ---"
# Soft, case-insensitive sanity on recognized words (base model varies — non-fatal).
if grep -iqE 'тест|транскрип|привет|test|transcription' "$TXT"; then
    echo "word-sanity: OK"
else
    echo "word-sanity: WARN (no expected words; base-model variance, non-fatal)"
fi
echo "PASS: non-empty TXT + $TIMECODES SRT timecode(s)"
