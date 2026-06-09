// Port of SceneExtractor.dHash + normalizedHamming (Swift).
// 64-bit difference hash: downscale to 9x8 grayscale, compare horizontally adjacent pixels.
// Stored as a Uint8Array(64) of bits (avoids BigInt). Distance is the normalized Hamming
// distance (0..1) — the same perceptual metric the desktop dedup relies on.

const W = 9, H = 8;
let _ctx = null;
function ctx() {
  if (!_ctx) _ctx = new OffscreenCanvas(W, H).getContext("2d", { willReadFrequently: true });
  return _ctx;
}

export function dHash(drawable) {
  try {
    const c = ctx();
    c.clearRect(0, 0, W, H);
    c.drawImage(drawable, 0, 0, W, H);
    const data = c.getImageData(0, 0, W, H).data;
    const px = new Float64Array(W * H);
    for (let i = 0; i < W * H; i++) {
      px[i] = 0.299 * data[i * 4] + 0.587 * data[i * 4 + 1] + 0.114 * data[i * 4 + 2];
    }
    const bits = new Uint8Array(64);
    let bit = 0;
    for (let row = 0; row < H; row++)
      for (let col = 0; col < W - 1; col++) {
        bits[bit++] = px[row * W + col] < px[row * W + col + 1] ? 1 : 0;
      }
    return bits;
  } catch {
    return null;
  }
}

export function hammingNormalized(a, b) {
  if (!a || !b) return null;
  let d = 0;
  for (let i = 0; i < 64; i++) if (a[i] !== b[i]) d++;
  return d / 64;
}
