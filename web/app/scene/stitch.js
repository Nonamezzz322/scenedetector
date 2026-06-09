// Port of FrameStitcher.stitch (Swift).
// Combines several frames into a single image, left-to-right in the given order.
// All frames are scaled to a common height (the MEDIAN of the inputs) so vertical and
// horizontal frames line up cleanly. White background, fixed spacing between frames.

import { canvasToBlob } from "./encode.js";

export async function stitchFrames(bitmaps, { format = "jpg", jpegQuality = 3, spacing = 8 } = {}) {
  const imgs = bitmaps.filter((b) => b && b.width > 0 && b.height > 0);
  if (!imgs.length) return null;

  const heights = imgs.map((b) => b.height).sort((a, b) => a - b);
  const targetH = heights[Math.floor(heights.length / 2)];

  const scaled = [];
  let totalW = 0;
  for (const b of imgs) {
    const w = b.width * (targetH / b.height);
    scaled.push({ b, w });
    totalW += w;
  }
  totalW += spacing * (imgs.length - 1);

  const cw = Math.ceil(totalW), ch = Math.ceil(targetH);
  const canvas = new OffscreenCanvas(cw, ch);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, cw, ch);
  let x = 0;
  for (const s of scaled) {
    ctx.drawImage(s.b, x, 0, s.w, targetH);
    x += s.w + spacing;
  }
  return canvasToBlob(canvas, format, jpegQuality);
}
