// Canvas → Blob encoding, with the desktop JPEG-quality scale mapped to canvas quality.
// ffmpeg -q:v uses 2 (best) .. 31 (worst); canvas wants 0..1 (1 = best). We map linearly
// onto 1.0..0.3 so the default q=3 stays visually lossless-ish (~0.93).

export function jpegQualityToCanvas(q) {
  const clamped = Math.min(31, Math.max(2, q || 3));
  return 1 - ((clamped - 2) / 29) * 0.7;
}

export function mimeFor(format) {
  return format === "png" ? "image/png" : "image/jpeg";
}

/** Works for both OffscreenCanvas (convertToBlob) and HTMLCanvasElement (toBlob). */
export function canvasToBlob(canvas, format, jpegQuality) {
  const mime = mimeFor(format);
  const quality = format === "png" ? undefined : jpegQualityToCanvas(jpegQuality);
  if (typeof canvas.convertToBlob === "function") {
    return canvas.convertToBlob(quality == null ? { type: mime } : { type: mime, quality });
  }
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b), mime, quality));
}
