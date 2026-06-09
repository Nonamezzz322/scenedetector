// Scene-change metric — the browser-native analog of ffmpeg's `scene` value.
//
// ffmpeg's select=gt(scene,thr) compares each frame to the previous one and yields a 0..1
// "fraction changed" number. We reproduce that by downscaling each sampled frame to a small
// grayscale buffer and taking the mean absolute luma difference (normalized 0..1). Hard cuts
// land ~0.2..0.6, near-identical frames ~0.0..0.05 — comparable in scale to ffmpeg's metric,
// so the same sensitivity presets (Low 0.45 / Medium 0.30 / High 0.18) behave sensibly.
//
// This is an approximation of frame-accurate scene detection (we sample, ffmpeg sees every
// frame), honest in the same way the desktop app is about its cut metrics.

export const ANALYZE_W = 64;
export const ANALYZE_H = 36;

let _ctx = null;
function ctx() {
  if (!_ctx) _ctx = new OffscreenCanvas(ANALYZE_W, ANALYZE_H).getContext("2d", { willReadFrequently: true });
  return _ctx;
}

/** Downscale a drawable to ANALYZE_W x ANALYZE_H grayscale (Uint8Array). */
export function grayFrame(drawable) {
  const c = ctx();
  c.clearRect(0, 0, ANALYZE_W, ANALYZE_H);
  c.drawImage(drawable, 0, 0, ANALYZE_W, ANALYZE_H);
  const data = c.getImageData(0, 0, ANALYZE_W, ANALYZE_H).data;
  const px = new Uint8Array(ANALYZE_W * ANALYZE_H);
  for (let i = 0; i < px.length; i++) {
    px[i] = (0.299 * data[i * 4] + 0.587 * data[i * 4 + 1] + 0.114 * data[i * 4 + 2]) | 0;
  }
  return px;
}

/** Mean absolute luma difference between two equal-size gray buffers, normalized 0..1. */
export function frameDiff(a, b) {
  if (!a || !b || a.length !== b.length) return 1;
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
  return (sum / a.length) / 255;
}
