// Scene extraction pipeline — ports the post-processing in SceneExtractor.extract (Swift):
// sample → reject low-detail (absolute floor + relative-to-median) → perceptual dedup →
// max-frames cap → encode + template filename. Returns frames ready for the selection grid.

import { sampleScenes, CancelledError } from "./frameSampler.js";
import { detailScore } from "./detail.js";
import { dHash } from "./dhash.js";
import { dedupDistinct } from "./dedup.js";
import { canvasToBlob } from "./encode.js";
import { makeFilename, baseName } from "./filename.js";

export { CancelledError };

/**
 * @returns {Promise<{frames: Array, duration: number}>}
 *   frames: [{ id, index, time, blob, url, filename, bitmap, width, height }]
 */
export async function extractScenes(fileOrUrl, params, { onProgress, signal } = {}) {
  const { captures, duration } = await sampleScenes(fileOrUrl, params, {
    onProgress: (p) => onProgress?.(p * 0.85),
    signal,
  });
  if (signal?.aborted) throw new CancelledError();
  if (!captures.length) return { frames: [], duration };

  // Pair each capture with a detail/sharpness score and a perceptual hash.
  let scored = captures.map((c) => ({
    time: c.time,
    bitmap: c.bitmap,
    detail: detailScore(c.bitmap),
    dhash: dHash(c.bitmap),
  }));

  // Drop near-black / low-contrast / transition-haze frames (never reject everything).
  if (params.rejectLowDetail && scored.length > 1) {
    const sorted = scored.map((s) => s.detail).slice().sort((a, b) => a - b);
    const median = sorted[Math.floor(sorted.length / 2)];
    const floor = Math.max(0.008, 0.2 * median);
    const kept = scored.filter((s) => s.detail >= floor);
    if (kept.length) {
      for (const s of scored) if (s.detail < floor) closeBitmap(s.bitmap);
      scored = kept;
    }
  }

  // Cross-frame dedup: keep distinct scenes; among near-dups keep the sharpest.
  if (params.dedup) {
    scored = dedupDistinct(scored, params.threshold, (dropped) => closeBitmap(dropped.bitmap));
  }

  // Cap AFTER post-processing (matches the desktop order).
  if (params.maxFrames > 0 && scored.length > params.maxFrames) {
    for (const s of scored.slice(params.maxFrames)) closeBitmap(s.bitmap);
    scored = scored.slice(0, params.maxFrames);
  }

  onProgress?.(0.9);

  const frames = [];
  const usedNames = new Set();
  for (let i = 0; i < scored.length; i++) {
    if (signal?.aborted) { disposeFrames(frames); throw new CancelledError(); }
    const s = scored[i];
    const blob = await encodeBitmap(s.bitmap, params);
    let filename = makeFilename({
      index: i + 1, time: s.time, template: params.filenameTemplate,
      source: params.sourceName, ext: params.format,
    });
    if (usedNames.has(filename)) filename = `${baseName(filename)}-${i + 1}.${params.format}`;
    usedNames.add(filename);
    frames.push({
      id: `f${i}`, index: i + 1, time: s.time, blob,
      url: URL.createObjectURL(blob), filename,
      bitmap: s.bitmap, width: s.bitmap.width, height: s.bitmap.height,
    });
    onProgress?.(0.9 + ((i + 1) / scored.length) * 0.1);
  }
  onProgress?.(1);
  return { frames, duration };
}

async function encodeBitmap(bitmap, params) {
  const c = new OffscreenCanvas(bitmap.width, bitmap.height);
  c.getContext("2d").drawImage(bitmap, 0, 0);
  return canvasToBlob(c, params.format, params.jpegQuality);
}

function closeBitmap(b) { try { b?.close?.(); } catch {} }

/** Free all bitmaps + object URLs held by a frame array. */
export function disposeFrames(frames) {
  for (const f of frames || []) {
    closeBitmap(f.bitmap);
    if (f.url) { try { URL.revokeObjectURL(f.url); } catch {} }
  }
}
