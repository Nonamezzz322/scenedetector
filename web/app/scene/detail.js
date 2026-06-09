// Port of SceneExtractor.detailScore (Swift).
// A 0..1 detail/sharpness proxy: mean absolute gradient of a 64x48 grayscale downscale.
// Near-black / uniform / low-contrast (transition-haze) frames score ~0; textured frames higher.
// On failure returns 1 (so the frame is kept), matching the Swift behaviour.

const W = 64, H = 48;
let _ctx = null;
function ctx() {
  if (!_ctx) _ctx = new OffscreenCanvas(W, H).getContext("2d", { willReadFrequently: true });
  return _ctx;
}

export function detailScore(drawable) {
  try {
    const c = ctx();
    c.clearRect(0, 0, W, H);
    c.drawImage(drawable, 0, 0, W, H);
    const data = c.getImageData(0, 0, W, H).data;
    const px = new Float64Array(W * H);
    for (let i = 0; i < W * H; i++) {
      px[i] = 0.299 * data[i * 4] + 0.587 * data[i * 4 + 1] + 0.114 * data[i * 4 + 2];
    }
    let sum = 0, count = 0;
    for (let r = 0; r < H; r++)
      for (let col = 0; col < W - 1; col++) { sum += Math.abs(px[r * W + col] - px[r * W + col + 1]); count++; }
    for (let r = 0; r < H - 1; r++)
      for (let col = 0; col < W; col++) { sum += Math.abs(px[r * W + col] - px[(r + 1) * W + col]); count++; }
    return count > 0 ? (sum / count) / 255 : 0;
  } catch {
    return 1;
  }
}
