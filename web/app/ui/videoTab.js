// "Видео" tab: one input, checkboxes for frames and/or transcription, frame selection + save,
// transcript preview/download. Mirrors the desktop VideoView (minus cloud links and UK translation).

import { $, $$, el, show, clear, setSegActive, fmtDuration, stamp } from "./dom.js";
import { t, savedFrames, saveSelected, selectedOf, stitchedSuffix, downloadingModelPct } from "../i18n.js";
import * as settings from "../settings.js";
import { extractScenes, disposeFrames, CancelledError } from "../scene/sceneEngine.js";
import { stitchFrames } from "../scene/stitch.js";
import { baseName } from "../scene/filename.js";
import { transcribe } from "../transcribe/whisper.js";
import { buildSRT, buildTXT } from "../transcribe/srt.js";
import { probeVideo } from "../scene/frameSampler.js";
import { renderFrameGrid } from "./frameGrid.js";
import { writeJobs } from "../io/output.js";
import { isFSAccessSupported, pickDirectory } from "../io/localFolder.js";
import { downloadBlob } from "../io/save.js";

export function initVideoTab() {
  const ui = {
    drop: $("#videoDrop"), input: $("#videoInput"), pick: $("#videoPick"),
    summary: $("#videoSummary"), notice: $("#videoNotice"),
    doFrames: $("#videoDoFrames"), doTranscribe: $("#videoDoTranscribe"),
    langRow: $("#videoLangRow"), lang: $("#videoLang"),
    progress: $("#videoProgress"), phase: $("#videoPhase"), barFill: $("#videoBarFill"),
    pct: $("#videoPct"), eta: $("#videoEta"), cancel: $("#videoCancel"),
    runBar: $("#videoRunBar"), run: $("#videoRun"), pickHint: $("#videoPickHint"),
    select: $("#videoSelect"), grid: $("#videoFrameGrid"), selCount: $("#videoSelCount"),
    selectAll: $("#videoSelectAll"), clearAll: $("#videoClearAll"), save: $("#videoSave"),
    saved: $("#videoSaved"), result: $("#videoResult"), transcript: $("#videoTranscript"),
  };

  const state = {
    file: null, info: null, working: false, abort: null, startTime: 0,
    frames: [], order: [], savedDone: false,
  };

  // ---------- input ----------
  ui.pick.addEventListener("click", () => ui.input.click());
  ui.input.addEventListener("change", () => { if (ui.input.files[0]) setFile(ui.input.files[0]); ui.input.value = ""; });
  ui.drop.addEventListener("dragover", (e) => { e.preventDefault(); ui.drop.classList.add("drag"); });
  ui.drop.addEventListener("dragleave", () => ui.drop.classList.remove("drag"));
  ui.drop.addEventListener("drop", (e) => {
    e.preventDefault(); ui.drop.classList.remove("drag");
    const f = e.dataTransfer?.files?.[0];
    if (f) setFile(f);
  });

  async function setFile(file) {
    resetResults();
    state.file = file; state.info = null;
    setNotice("");
    show(ui.summary, true);
    ui.summary.innerHTML = `<div class="name">${escapeHtml(file.name)}</div><div class="meta"><span class="spinner"></span></div>`;
    updateRunEnabled();
    try {
      const info = await probeVideo(file);
      state.info = info;
      ui.summary.innerHTML =
        `<div class="name">${escapeHtml(file.name)}</div>` +
        `<div class="meta">` +
        (info.duration ? `<span>⏱ ${fmtDuration(info.duration)}</span>` : "") +
        (info.width ? `<span>🖼 ${info.width}×${info.height}</span>` : "") +
        `</div>`;
    } catch {
      ui.summary.innerHTML =
        `<div class="name">${escapeHtml(file.name)}</div>` +
        `<div class="meta"><span class="warn">${escapeHtml(decodeMsg())}</span></div>`;
    }
    updateRunEnabled();
  }

  // ---------- action toggles ----------
  ui.doFrames.addEventListener("change", updateRunEnabled);
  ui.doTranscribe.addEventListener("change", () => { show(ui.langRow, ui.doTranscribe.checked); updateRunEnabled(); });
  setSegActive(ui.lang, "data-lang", settings.get("tx_language"));
  $$("#videoLang .seg-btn").forEach((b) =>
    b.addEventListener("click", () => { settings.set("tx_language", b.getAttribute("data-lang")); setSegActive(ui.lang, "data-lang", settings.get("tx_language")); })
  );

  function anyAction() { return ui.doFrames.checked || ui.doTranscribe.checked; }
  function updateRunEnabled() {
    ui.run.disabled = !state.file || !anyAction() || state.working;
    show(ui.pickHint, !!state.file && !anyAction());
  }

  // ---------- run ----------
  ui.run.addEventListener("click", run);
  ui.cancel.addEventListener("click", () => state.abort?.abort());

  async function run() {
    if (!state.file || !anyAction()) return;
    const doFrames = ui.doFrames.checked;
    const doTx = ui.doTranscribe.checked;
    const both = doFrames && doTx;
    resetResults();
    state.working = true; state.abort = new AbortController(); state.startTime = performance.now();
    show(ui.progress, true); show(ui.runBar, false); setNotice("");
    updateRunEnabled();

    try {
      if (doFrames) {
        setPhase(t("analyzing"));
        const params = settings.extractParams(baseName(state.file.name));
        const { frames } = await extractScenes(state.file, params, {
          onProgress: (p) => setProgress(both ? p * 0.5 : p),
          signal: state.abort.signal,
        });
        state.frames = frames;
        if (!frames.length) showResult("frames-empty");
      }
      if (doTx) {
        const tp = settings.transcribeParams();
        setPhase(t("recognizing"));
        const r = await transcribe(state.file, {
          language: tp.language, device: tp.device, signal: state.abort.signal,
          onStage: (s) => setPhase(s === "decoding" ? t("recognizing") : s === "loading-model" ? t("loadingModel") : t("recognizing")),
          onModelProgress: (pct) => setPhase(downloadingModelPct(pct)),
        });
        if (both) setProgress(1);
        showTranscript(r, tp);
      }
    } catch (e) {
      if (e instanceof CancelledError || e?.code === "cancelled" || e?.name === "AbortError") {
        setNotice(t("cancelled"));
      } else if (e?.code === "no-audio") {
        showResult("no-audio");
      } else {
        showResult("error", e);
      }
    } finally {
      state.working = false; state.abort = null;
      show(ui.progress, false); show(ui.runBar, true);
      updateRunEnabled();
      if (state.frames.length) showSelection();
    }
  }

  // ---------- progress ----------
  function setPhase(text) { ui.phase.textContent = text; }
  function setProgress(p) {
    const pct = Math.max(0, Math.min(100, Math.round(p * 100)));
    ui.barFill.style.width = pct + "%";
    ui.pct.textContent = pct + "%";
    ui.eta.textContent = etaText(p);
  }
  function etaText(p) {
    if (p <= 0.03) return "";
    const elapsed = (performance.now() - state.startTime) / 1000;
    const remaining = Math.max(0, elapsed / p - elapsed);
    const tsec = Math.round(remaining);
    const s = t("remaining");
    return tsec >= 60 ? `· ${s}${Math.floor(tsec / 60)}м ${tsec % 60}с` : `· ${s}${tsec}с`;
  }

  // ---------- frame selection ----------
  function showSelection() {
    show(ui.select, true);
    state.order = [];
    const refresh = () => {
      renderFrameGrid(ui.grid, state.frames, state.order, () => { refresh(); });
      ui.selCount.textContent = selectedOf(state.order.length, state.frames.length);
      ui.save.disabled = state.order.length === 0;
      ui.save.textContent = saveSelected(state.order.length);
    };
    refresh();
    ui.selectAll.onclick = () => { state.order = state.frames.map((f) => f.id); refresh(); };
    ui.clearAll.onclick = () => { state.order = []; refresh(); };
    ui.save.onclick = saveFrames;
  }

  async function saveFrames() {
    if (!state.order.length) return;
    const fmt = settings.get("format");
    const selected = state.order.map((id) => state.frames.find((f) => f.id === id)).filter(Boolean);
    const files = selected.map((f) => ({ name: f.filename, blob: f.blob }));
    if (settings.get("stitchFrames") && selected.length) {
      const blob = await stitchFrames(selected.map((f) => f.bitmap), { format: fmt, jpegQuality: settings.get("jpegQuality") });
      if (blob) files.push({ name: `combined.${fmt}`, blob });
    }
    const folder = `${baseName(state.file.name)}-${stamp()}`;
    ui.save.disabled = true;
    let baseDirHandle = null;
    if (isFSAccessSupported()) {
      baseDirHandle = await pickDirectory();
      if (!baseDirHandle) { ui.save.disabled = false; return; } // cancelled
    }
    try {
      const res = await writeJobs([{ folder, files }], { baseDirHandle, zipName: `${folder}.zip` });
      showSaved(selected.length, res.mode);
      show(ui.select, false);
    } catch (e) {
      // folder write failed → fall back to ZIP
      try {
        const { zipAndDownload } = await import("../io/save.js");
        await zipAndDownload(files.map((f) => ({ path: `${folder}/${f.name}`, blob: f.blob })), `${folder}.zip`);
        showSaved(selected.length, "zip");
        show(ui.select, false);
      } catch {
        setNotice(t("errorTitle")); ui.save.disabled = false;
      }
    }
  }

  function showSaved(count, mode) {
    state.savedDone = true;
    show(ui.saved, true);
    const suffix = settings.get("stitchFrames") ? stitchedSuffix() : "";
    const modeNote = mode === "folder"
      ? { ru: "Сохранено в выбранную папку.", uk: "Збережено в обрану папку.", en: "Saved to the chosen folder." }
      : { ru: "Скачано ZIP-архивом.", uk: "Завантажено ZIP-архівом.", en: "Downloaded as a ZIP." };
    ui.saved.innerHTML = `<div class="row">✅ <strong>${escapeHtml(savedFrames(count) + suffix)}</strong></div><p class="hint">${escapeHtml(pickLang(modeNote))}</p>`;
  }

  // ---------- transcript ----------
  function showTranscript(r, tp) {
    if (!r.text) { showResult("no-speech"); return; }
    show(ui.transcript, true);
    const card = ui.transcript;
    card.innerHTML = "";
    card.appendChild(el("h3", { text: t("transcriptDone") }));
    const pre = el("pre", { text: r.text });
    card.appendChild(pre);
    const actions = el("div", { class: "card-actions" });
    if (tp.writeTxt) actions.appendChild(el("button", { class: "btn small", text: t("download") + " TXT", onclick: () => downloadBlob(new Blob([buildTXT(r.text)], { type: "text/plain" }), "transcript.txt") }));
    if (tp.writeSrt && r.chunks.length) actions.appendChild(el("button", { class: "btn small", text: t("download") + " SRT", onclick: () => downloadBlob(new Blob([buildSRT(r.chunks)], { type: "text/plain" }), "transcript.srt") }));
    const copyBtn = el("button", { class: "btn small", text: t("copyText"), onclick: async () => { await navigator.clipboard.writeText(r.text); copyBtn.textContent = t("copied"); setTimeout(() => (copyBtn.textContent = t("copyText")), 1500); } });
    actions.appendChild(copyBtn);
    card.appendChild(actions);
  }

  // ---------- result cards ----------
  function showResult(kind, err) {
    show(ui.result, true);
    let title = "", body = "";
    if (kind === "frames-empty") { title = t("noScenesTitle"); body = t("retryHint"); }
    else if (kind === "no-speech") { title = t("noSpeechTitle"); body = t("noSpeechMsg"); }
    else if (kind === "no-audio") { title = t("noSpeechTitle"); body = t("noAudioTrack"); }
    else { title = t("errorTitle"); body = (err && (err.message || String(err))) || ""; }
    ui.result.innerHTML = `<h3>${escapeHtml(title)}</h3><p class="hint">${escapeHtml(body)}</p>`;
  }

  function setNotice(text, isError = false) {
    ui.notice.textContent = text;
    ui.notice.classList.toggle("error", isError);
    show(ui.notice, !!text);
  }

  function resetResults() {
    disposeFrames(state.frames);
    state.frames = []; state.order = []; state.savedDone = false;
    show(ui.select, false); clear(ui.grid);
    show(ui.saved, false); show(ui.result, false); show(ui.transcript, false);
    setNotice("");
  }

  function decodeMsg() {
    return pickLang({ ru: "Браузер не смог прочитать это видео (кодек/формат). Попробуйте MP4 (H.264).", uk: "Браузер не зміг прочитати це відео (кодек/формат). Спробуйте MP4 (H.264).", en: "The browser couldn't read this video (codec/format). Try MP4 (H.264)." });
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function pickLang(map) { return map[document.documentElement.lang] || map.ru; }
