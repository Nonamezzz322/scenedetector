// Quick poster thumbnail for the folder grid: load a video, seek ~10% in, capture one small frame.

export async function makeThumbnail(file, maxW = 320) {
  const video = document.createElement("video");
  video.muted = true;
  video.preload = "auto";
  video.playsInline = true;
  const url = URL.createObjectURL(file);
  video.src = url;
  try {
    await new Promise((res, rej) => {
      video.addEventListener("loadedmetadata", res, { once: true });
      video.addEventListener("error", () => rej(new Error("decode")), { once: true });
    });
    const dur = isFinite(video.duration) ? video.duration : 1;
    const t = Math.min(Math.max(0.1, dur * 0.1), Math.max(0, dur - 0.05));
    await new Promise((res) => {
      const to = setTimeout(res, 3000);
      video.addEventListener("seeked", () => { clearTimeout(to); res(); }, { once: true });
      try { video.currentTime = t; } catch { res(); }
    });
    const vw = video.videoWidth || 16, vh = video.videoHeight || 9;
    const w = Math.min(maxW, vw), h = Math.max(1, Math.round(vh * (w / vw)));
    const c = new OffscreenCanvas(w, h);
    c.getContext("2d").drawImage(video, 0, 0, w, h);
    const blob = await c.convertToBlob({ type: "image/jpeg", quality: 0.7 });
    return { url: URL.createObjectURL(blob), width: vw, height: vh, duration: dur };
  } catch {
    return null;
  } finally {
    try { video.removeAttribute("src"); video.load(); } catch {}
    URL.revokeObjectURL(url);
  }
}
