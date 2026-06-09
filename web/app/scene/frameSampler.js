// Browser-native frame sampler — the analog of ffmpeg's scene-detect pass.
//
// Walks a video by seeking at a fixed step, computes the scene-change metric between
// consecutive sampled frames, and runs the SAME capture state machine as the desktop app's
// ffmpeg `select` expression:
//   - the opening frame is always kept (eq(n,0));
//   - settleDelay > 0  → arm a timer on a change and capture the SETTLED frame `delay` seconds
//     later (a fade's many spikes yield one frame); a fresh change while armed refreshes the timer;
//   - settleDelay == 0 → capture at the change itself, optionally gated by a minimum interval.
//
// Returns captured candidates as { time, bitmap } (already scaled to maxWidth). Post-processing
// (low-detail rejection, perceptual dedup, max-frames cap, encoding) happens in sceneEngine.

import { grayFrame, frameDiff } from "./sceneMetric.js";

const SAMPLE_STEP = 0.2;        // seconds between analysis samples (~5 fps)
const MAX_SAMPLES = 2000;       // safety bound on seeks
const SAFETY_CAPTURE_CAP = 1200; // safety bound on captured candidates

export class CancelledError extends Error {
  constructor() { super("cancelled"); this.name = "AbortError"; }
}

export async function probeVideo(fileOrUrl) {
  const { video, cleanup } = makeVideo(fileOrUrl);
  try {
    await loadedMetadata(video);
    return {
      duration: video.duration,
      width: video.videoWidth,
      height: video.videoHeight,
    };
  } finally {
    cleanup();
  }
}

export async function sampleScenes(fileOrUrl, params, { onProgress, signal } = {}) {
  const { video, cleanup } = makeVideo(fileOrUrl);
  try {
    await loadedMetadata(video);
    const duration = video.duration;
    const vw = video.videoWidth, vh = video.videoHeight;
    if (!isFinite(duration) || duration <= 0 || !vw || !vh) {
      throw new Error("no-video-stream");
    }

    const outW = params.maxWidth > 0 ? Math.min(params.maxWidth, vw) : vw;
    const outH = Math.max(1, Math.round(vh * (outW / vw)));
    const outCanvas = new OffscreenCanvas(outW, outH);
    const outCtx = outCanvas.getContext("2d");

    const step = chooseStep(duration);
    const captures = [];
    let prevGray = null;
    let armed = 0;          // scheduled capture time (ld0); 0 = not armed
    let lastSelectedT = -Infinity;
    let sampleIndex = 0;

    for (let t = 0; t < duration + step; t += step) {
      if (signal?.aborted) throw new CancelledError();
      const target = Math.min(t, Math.max(0, duration - 0.001));
      const actualT = await seekTo(video, target);
      const gray = grayFrame(video);
      const diff = prevGray ? frameDiff(prevGray, gray) : 1;
      prevGray = gray;

      let capture = false;
      let captureT = actualT;

      if (sampleIndex === 0) {
        capture = true; // opening frame always kept
      } else if (params.settleDelay > 0) {
        if (armed <= 0) {
          if (diff > params.threshold) armed = actualT + params.settleDelay;
        } else if (actualT >= armed) {
          capture = true; armed = 0;
        } else if (diff > params.threshold) {
          armed = actualT + params.settleDelay; // refresh
        }
      } else {
        if (diff > params.threshold) {
          if (params.minInterval <= 0 || actualT - lastSelectedT >= params.minInterval) {
            capture = true;
          }
        }
      }

      if (capture) {
        outCtx.drawImage(video, 0, 0, outW, outH);
        const bitmap = await createImageBitmap(outCanvas);
        captures.push({ time: captureT, bitmap });
        lastSelectedT = actualT;
        if (captures.length >= SAFETY_CAPTURE_CAP) break;
      }

      onProgress?.(Math.min(1, target / duration));
      sampleIndex++;
      if (sampleIndex > MAX_SAMPLES) break;
    }

    onProgress?.(1);
    return { captures, duration, width: outW, height: outH };
  } finally {
    cleanup();
  }
}

// ---------- helpers ----------

function chooseStep(duration) {
  const n = duration / SAMPLE_STEP;
  return n > MAX_SAMPLES ? duration / MAX_SAMPLES : SAMPLE_STEP;
}

function makeVideo(fileOrUrl) {
  const video = document.createElement("video");
  video.muted = true;
  video.defaultMuted = true;
  video.preload = "auto";
  video.playsInline = true;
  video.crossOrigin = "anonymous";
  let objectURL = null;
  if (typeof fileOrUrl === "string") {
    video.src = fileOrUrl;
  } else {
    objectURL = URL.createObjectURL(fileOrUrl);
    video.src = objectURL;
  }
  const cleanup = () => {
    try { video.removeAttribute("src"); video.load(); } catch {}
    if (objectURL) URL.revokeObjectURL(objectURL);
  };
  return { video, cleanup };
}

function loadedMetadata(video) {
  return new Promise((resolve, reject) => {
    if (video.readyState >= 1 && video.videoWidth) return resolve();
    const onMeta = () => { cleanup(); resolve(); };
    const onErr = () => { cleanup(); reject(new Error("decode-failed")); };
    const cleanup = () => {
      video.removeEventListener("loadedmetadata", onMeta);
      video.removeEventListener("error", onErr);
    };
    video.addEventListener("loadedmetadata", onMeta);
    video.addEventListener("error", onErr);
  });
}

function seekTo(video, t) {
  return new Promise((resolve, reject) => {
    // Already at this time WITH a decoded frame available → no seek needed.
    if (video.readyState >= 2 && Math.abs(video.currentTime - t) < 1e-3) {
      return resolve(video.currentTime);
    }
    // Setting currentTime to its current value does NOT fire 'seeked' (e.g. the opening frame
    // at t=0 right after loadedmetadata) — nudge it so a real seek happens and a frame decodes.
    let target = t;
    if (Math.abs(video.currentTime - target) < 1e-3) target = t + 1e-3;

    let done = false;
    const onSeeked = () => { if (done) return; done = true; cleanup(); resolve(video.currentTime); };
    const onErr = () => { if (done) return; done = true; cleanup(); reject(new Error("seek-failed")); };
    const cleanup = () => {
      video.removeEventListener("seeked", onSeeked);
      video.removeEventListener("error", onErr);
      clearTimeout(timer);
    };
    // Fallback in case 'seeked' never arrives for some codec/container.
    const timer = setTimeout(() => { if (!done) { done = true; cleanup(); resolve(video.currentTime); } }, 4000);
    video.addEventListener("seeked", onSeeked);
    video.addEventListener("error", onErr);
    try { video.currentTime = target; } catch (e) { cleanup(); reject(e); }
  });
}
