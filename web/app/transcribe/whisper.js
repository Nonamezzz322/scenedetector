// Whisper transcription in the browser via transformers.js (ONNX Runtime, WebGPU/WASM).
// No translation step — task is always 'transcribe' (the desktop Ukrainian-translation pass
// is intentionally dropped). Model + library load lazily on first use and cache in the browser.

const MODEL = "Xenova/whisper-base"; // multilingual base model (includes ru/uk/en)
const CDN = "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1";

let _pipePromise = null;
let _pipeDevice = null;

export class TranscribeError extends Error {
  constructor(code, message) { super(message || code); this.name = "TranscribeError"; this.code = code; }
}

function resolveDevice(device) {
  if (device === "webgpu") return "webgpu";
  if (device === "wasm") return "wasm";
  return "gpu" in navigator || navigator.gpu ? "webgpu" : "wasm"; // auto
}

// Normalize transformers.js progress events into a single 0..100 percent.
function normalizeProgress(onModelProgress) {
  if (!onModelProgress) return undefined;
  return (m) => {
    if (!m || m.status !== "progress") return;
    let pct;
    if (m.total) pct = (m.loaded / m.total) * 100;
    else if (typeof m.progress === "number") pct = m.progress <= 1 ? m.progress * 100 : m.progress;
    else return;
    onModelProgress(Math.max(0, Math.min(100, Math.round(pct))), m.file);
  };
}

async function getPipeline(device, onModelProgress) {
  const requested = resolveDevice(device);
  if (_pipePromise && _pipeDevice === requested) return _pipePromise;
  const cb = normalizeProgress(onModelProgress);
  const promise = (async () => {
    const { pipeline, env } = await import(CDN);
    env.allowLocalModels = false; // always fetch from the HF CDN, cache in browser
    const dtype = requested === "webgpu" ? "fp32" : "q8";
    try {
      return await pipeline("automatic-speech-recognition", MODEL, {
        device: requested, dtype, progress_callback: cb,
      });
    } catch (e) {
      // WebGPU can fail to initialize on some machines — fall back to WASM once.
      if (requested === "webgpu") {
        return pipeline("automatic-speech-recognition", MODEL, {
          device: "wasm", dtype: "q8", progress_callback: cb,
        });
      }
      throw e;
    }
  })();
  // Cache ONLY on success — a transient first-load failure must not brick the session.
  _pipePromise = promise;
  _pipeDevice = requested;
  promise.catch(() => { if (_pipePromise === promise) { _pipePromise = null; _pipeDevice = null; } });
  return promise;
}

/**
 * @returns {Promise<{text: string, chunks: Array<{start:number,end:number|null,text:string}>, language: string|null}>}
 */
export async function transcribe(fileOrBlob, { language = "auto", device = "auto", onStage, onModelProgress, signal } = {}) {
  onStage?.("decoding");
  const audio = await decodeAudioTo16kMono(fileOrBlob);
  if (!audio || audio.length === 0) throw new TranscribeError("no-audio");
  if (signal?.aborted) throw new TranscribeError("cancelled");

  onStage?.("loading-model");
  const asr = await getPipeline(device, onModelProgress);
  if (signal?.aborted) throw new TranscribeError("cancelled");

  onStage?.("recognizing");
  const opts = {
    chunk_length_s: 30,
    stride_length_s: [5, 3],
    return_timestamps: true,
    task: "transcribe",
  };
  if (language && language !== "auto") opts.language = language;

  const out = await asr(audio, opts);
  const chunks = (out.chunks || [])
    .map((c) => ({
      start: Array.isArray(c.timestamp) ? c.timestamp[0] ?? 0 : 0,
      end: Array.isArray(c.timestamp) ? c.timestamp[1] : null,
      text: c.text || "",
    }))
    .filter((c) => c.text.trim());

  return {
    text: (out.text || "").trim(),
    chunks,
    language: language === "auto" ? null : language,
  };
}

async function decodeAudioTo16kMono(fileOrBlob) {
  const buf = await fileOrBlob.arrayBuffer();
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) throw new TranscribeError("no-audio", "Web Audio API unavailable");
  const tmp = new AC();
  let decoded;
  try {
    decoded = await tmp.decodeAudioData(buf.slice(0));
  } catch {
    try { await tmp.close(); } catch {}
    throw new TranscribeError("no-audio", "Could not decode an audio track");
  }
  try { await tmp.close(); } catch {}
  if (!decoded || decoded.length === 0) throw new TranscribeError("no-audio");

  const targetRate = 16000;
  const length = Math.max(1, Math.ceil(decoded.duration * targetRate));
  const off = new OfflineAudioContext(1, length, targetRate);
  const src = off.createBufferSource();
  src.buffer = decoded;
  src.connect(off.destination);
  src.start();
  const rendered = await off.startRendering();
  return rendered.getChannelData(0);
}
