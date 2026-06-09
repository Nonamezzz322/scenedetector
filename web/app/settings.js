// Persistent settings store (localStorage), mirroring the desktop app's @AppStorage keys.

// Bump the version to roll out new defaults (e.g. High sensitivity) to existing browsers.
const KEY = "ss_settings_v2";

const DEFAULTS = {
  // frames
  threshold: 0.18,        // 0.05..0.9, lower = more frames. Default = High sensitivity.
  minInterval: 0.0,       // seconds, 0 = off
  format: "jpg",          // "jpg" | "png"
  jpegQuality: 3,         // 2..31 (ffmpeg scale, lower = better) -> mapped to canvas quality
  maxWidth: 0,            // 0 = original
  maxFrames: 0,           // 0 = unlimited
  filenameTemplate: "scene_{index}_{time}",
  dedupScenes: true,
  settleDelay: 0.4,       // seconds after the cut, 0 = at the cut
  rejectLowDetail: true,
  stitchFrames: true,
  // transcription
  tx_language: "auto",    // "auto" | "ru" | "uk" | "en"
  tx_txt: true,
  tx_srt: true,
  tx_device: "auto",      // "auto" | "webgpu" | "wasm"
  // optional CORS proxy (Cloudflare Worker) for Dropbox / Google Drive / non-CORS direct links
  proxyUrl: "",
  // UI state (persisted so choices survive reloads, like the desktop @AppStorage toggles)
  vid_frames: true,
  vid_transcribe: false,
  batchDoFrames: true,
  batchDoTranscribe: false,
  activeTab: "video",     // "video" | "folder"
};

let state = load();

function load() {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) || "{}");
    return { ...DEFAULTS, ...raw };
  } catch {
    return { ...DEFAULTS };
  }
}

function persist() {
  localStorage.setItem(KEY, JSON.stringify(state));
}

export function get(key) { return state[key]; }
export function all() { return { ...state }; }

export function set(key, value) {
  state[key] = value;
  persist();
}

/** Build the ExtractParams object the scene engine expects (validated/clamped). */
export function extractParams(sourceName = "video") {
  return {
    threshold: clamp(num(state.threshold, 0.30), 0.05, 0.9),
    minInterval: Math.max(0, num(state.minInterval, 0)),
    format: state.format === "png" ? "png" : "jpg",
    jpegQuality: clamp(Math.round(num(state.jpegQuality, 3)), 2, 31),
    maxWidth: Math.max(0, Math.round(num(state.maxWidth, 0))),
    maxFrames: Math.max(0, Math.round(num(state.maxFrames, 0))),
    filenameTemplate: state.filenameTemplate || "scene_{index}_{time}",
    dedup: !!state.dedupScenes,
    settleDelay: Math.max(0, num(state.settleDelay, 0.4)),
    rejectLowDetail: !!state.rejectLowDetail,
    sourceName,
  };
}

/** Build transcription params. */
export function transcribeParams() {
  return {
    language: ["auto", "ru", "uk", "en"].includes(state.tx_language) ? state.tx_language : "auto",
    writeTxt: !!state.tx_txt,
    writeSrt: !!state.tx_srt,
    device: ["auto", "webgpu", "wasm"].includes(state.tx_device) ? state.tx_device : "auto",
  };
}

function num(v, d) { const n = Number(v); return Number.isFinite(n) ? n : d; }
function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
