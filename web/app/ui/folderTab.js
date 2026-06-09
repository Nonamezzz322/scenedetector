// "Папка" tab: pick a LOCAL folder (File System Access API or webkitdirectory fallback),
// pick videos from the grid, batch-extract frames and/or transcribe, then select frames per
// video and save subfolders back to the local folder (or as a ZIP). No cloud — local only.

import { $, $$, el, show, clear, setSegActive, stamp, fmtDuration } from "./dom.js";
import { t, selectedOf, processSelected, processingOf, summary, savedFrames, saveSelected, stitchedSuffix, downloadingModelPct } from "../i18n.js";
import * as settings from "../settings.js";
import { extractScenes, disposeFrames, CancelledError } from "../scene/sceneEngine.js";
import { stitchFrames } from "../scene/stitch.js";
import { baseName } from "../scene/filename.js";
import { transcribe } from "../transcribe/whisper.js";
import { buildSRT, buildTXT } from "../transcribe/srt.js";
import { renderFrameGrid } from "./frameGrid.js";
import { makeThumbnail } from "./thumbnail.js";
import { zipAndDownload } from "../io/save.js";
import { listVideoFiles } from "../io/localFolder.js";

// Top-level folder all output is grouped under (created on extract from the ZIP).
const APP_FOLDER = "SceneShot";

export function initFolderTab() {
  const ui = {
    pick: $("#folderPick"), input: $("#folderInput"), hint: $("#folderHint"),
    notice: $("#folderNotice"), body: $("#folderBody"), grid: $("#folderGrid"),
    selCount: $("#folderSelCount"), selectAll: $("#folderSelectAll"), clearAll: $("#folderClearAll"),
    doFrames: $("#folderDoFrames"), doTranscribe: $("#folderDoTranscribe"),
    langRow: $("#folderLangRow"), lang: $("#folderLang"),
    progress: $("#folderProgress"), phase: $("#folderPhase"), barFill: $("#folderBarFill"),
    pct: $("#folderPct"), cancel: $("#folderCancel"), statusList: $("#folderStatusList"),
    runBar: $("#folderRunBar"), run: $("#folderRun"),
    select: $("#folderSelect"), saveBar: $("#folderSaveBar"), saveAll: $("#folderSaveAll"),
    saved: $("#folderSaved"),
  };

  const state = {
    label: "", videos: [], results: [],
    working: false, abort: null, ran: false,
  };

  // ---------- input ----------
  // We use <input webkitdirectory> (not the File System Access showDirectoryPicker), because
  // Chrome's File System Access API blocklists sensitive folders — on macOS that includes
  // Downloads/Desktop/Documents ("содержит системные файлы"). webkitdirectory has no such
  // blocklist, so any folder (incl. Downloads) can be picked; it's read-only, which is all we need.
  ui.pick.addEventListener("click", () => ui.input.click());
  ui.input.addEventListener("change", () => {
    const all = listVideoFiles(ui.input.files);
    // Only videos directly in the chosen folder (not nested subfolders), matching the desktop app.
    const topLevel = all.filter((f) => (f.webkitRelativePath || "").split("/").length <= 2);
    const vids = topLevel.length ? topLevel : all;
    const label = (ui.input.files[0]?.webkitRelativePath || "").split("/")[0] || "batch";
    loadVideos(label, vids.map((f) => ({ name: f.name, getFile: () => Promise.resolve(f) })));
    ui.input.value = "";
  });

  async function loadVideos(label, items) {
    reset();
    state.label = label;
    if (!items.length) { setNotice(pickLang({ ru: "В этой папке нет видеофайлов.", uk: "У цій папці немає відеофайлів.", en: "No video files in this folder." }), true); return; }
    state.videos = items.map((it, i) => ({ id: `v${i}`, name: it.name, getFile: it.getFile, thumb: null, selected: false }));
    show(ui.body, true);
    renderGrid();
    updateRunLabel();
    // thumbnails in the background, sequentially (keeps memory/CPU sane)
    for (const v of state.videos) {
      try { const f = await v.getFile(); const th = await makeThumbnail(f); if (th) { v.thumb = th.url; v.duration = th.duration; renderGrid(); } } catch {}
    }
  }

  // ---------- grid ----------
  function renderGrid() {
    clear(ui.grid);
    for (const v of state.videos) {
      const cell = el("div", { class: "thumb-cell" + (v.selected ? " selected" : "") }, [
        v.thumb ? el("img", { class: "thumb-img", src: v.thumb, alt: "" }) : el("div", { class: "thumb-img" }),
        el("div", { class: "check-dot", text: v.selected ? "✓" : "" }),
        el("div", { class: "thumb-info" }, [
          el("div", { class: "thumb-name", text: v.name }),
          el("div", { class: "thumb-sub", text: v.duration ? fmtDuration(v.duration) : "" }),
        ]),
      ]);
      cell.addEventListener("click", () => { v.selected = !v.selected; renderGrid(); updateRunLabel(); });
      ui.grid.appendChild(cell);
    }
    ui.selCount.textContent = selectedOf(state.videos.filter((v) => v.selected).length, state.videos.length);
  }

  ui.selectAll.addEventListener("click", () => { state.videos.forEach((v) => (v.selected = true)); renderGrid(); updateRunLabel(); });
  ui.clearAll.addEventListener("click", () => { state.videos.forEach((v) => (v.selected = false)); renderGrid(); updateRunLabel(); });

  // ---------- actions (persisted) ----------
  ui.doFrames.checked = settings.get("batchDoFrames");
  ui.doTranscribe.checked = settings.get("batchDoTranscribe");
  show(ui.langRow, ui.doTranscribe.checked);
  ui.doTranscribe.addEventListener("change", () => { settings.set("batchDoTranscribe", ui.doTranscribe.checked); show(ui.langRow, ui.doTranscribe.checked); });
  ui.doFrames.addEventListener("change", () => { settings.set("batchDoFrames", ui.doFrames.checked); updateRunLabel(); });
  setSegActive(ui.lang, "data-lang", settings.get("tx_language"));
  $$("#folderLang .seg-btn").forEach((b) =>
    b.addEventListener("click", () => { settings.set("tx_language", b.getAttribute("data-lang")); setSegActive(ui.lang, "data-lang", settings.get("tx_language")); })
  );

  function anyAction() { return ui.doFrames.checked || ui.doTranscribe.checked; }
  function selectedVideos() { return state.videos.filter((v) => v.selected); }
  function updateRunLabel() {
    const n = selectedVideos().length;
    ui.run.textContent = processSelected(n);
    ui.run.disabled = n === 0 || !anyAction() || state.working;
    show(ui.runBar, state.videos.length > 0 && !state.ran);
  }

  // ---------- run ----------
  ui.run.addEventListener("click", run);
  ui.cancel.addEventListener("click", () => state.abort?.abort());

  async function run() {
    const vids = selectedVideos();
    if (!vids.length || !anyAction()) return;
    const doFrames = ui.doFrames.checked, doTx = ui.doTranscribe.checked, both = doFrames && doTx;
    state.working = true; state.ran = true; state.abort = new AbortController();
    state.results = vids.map((v) => ({ id: v.id, name: v.name, frames: [], order: [], transcript: null, error: null, status: "waiting" }));
    show(ui.runBar, false); show(ui.progress, true); show(ui.body, false);
    renderStatusList();

    const total = vids.length;
    for (let i = 0; i < total; i++) {
      if (state.abort.signal.aborted) { state.results[i].status = "cancelled"; break; }
      const v = vids[i], r = state.results[i];
      r.status = "processing"; renderStatusList();
      ui.phase.textContent = processingOf(i + 1, total);
      const setOverall = (ip) => setProgress((i + ip) / total);
      try {
        const file = await v.getFile();
        if (doFrames) {
          const params = settings.extractParams(baseName(v.name));
          const { frames } = await extractScenes(file, params, { onProgress: (p) => setOverall(both ? p * 0.5 : p), signal: state.abort.signal });
          r.frames = frames;
        }
        if (doTx) {
          const tp = settings.transcribeParams();
          const tr = await transcribe(file, {
            language: tp.language, device: tp.device, signal: state.abort.signal,
            onModelProgress: (pct) => { ui.phase.textContent = downloadingModelPct(pct); },
          });
          if (tr.text) r.transcript = { text: tr.text, chunks: tr.chunks, tp };
          if (both) setOverall(1);
        }
        r.status = "done";
      } catch (e) {
        if (e instanceof CancelledError || e?.code === "cancelled" || e?.name === "AbortError") { r.status = "cancelled"; renderStatusList(); break; }
        r.status = "failed"; r.error = errMsg(e);
      }
      setProgress((i + 1) / total);
      renderStatusList();
    }

    state.working = false; state.abort = null;
    show(ui.progress, false);
    showSelections();
  }

  function setProgress(p) {
    const pct = Math.max(0, Math.min(100, Math.round(p * 100)));
    ui.barFill.style.width = pct + "%"; ui.pct.textContent = pct + "%";
  }

  function renderStatusList() {
    clear(ui.statusList);
    for (const r of state.results) {
      const icon = { waiting: "🕓", processing: "⏳", done: "✅", failed: "❌", cancelled: "➖" }[r.status] || "🕓";
      const stTxt = { waiting: t("statusWaiting"), processing: t("statusProcessing"), done: t("statusDone"), failed: r.error || t("statusFailed"), cancelled: t("statusCancelled") }[r.status];
      ui.statusList.appendChild(el("div", { class: "batch-row" }, [
        el("span", { class: "b-icon", text: icon }),
        el("span", { class: "b-name", text: r.name }),
        el("span", { class: "b-status", text: stTxt }),
      ]));
    }
  }

  // ---------- per-video frame selection ----------
  function showSelections() {
    const staged = state.results.filter((r) => r.frames.length);
    const failures = state.results.filter((r) => r.status === "failed");
    show(ui.select, true);
    clear(ui.select);
    ui.select.appendChild(el("h3", { text: summary(state.results.filter((r) => r.status === "done").length, failures.length) }));
    for (const f of failures) ui.select.appendChild(el("p", { class: "hint", text: `• ${f.name}: ${f.error || ""}` }));

    if (!staged.length) { show(ui.saveBar, hasAnythingToSave()); updateSaveLabel(); if (hasAnythingToSave()) ui.saveAll.onclick = saveAll; return; }

    ui.select.appendChild(el("p", { class: "hint", text: t("selectFramesHint") }));
    for (const r of staged) {
      const block = el("div", { class: "video-block" });
      const head = el("div", { class: "vb-head" });
      const name = el("span", { class: "vb-name", text: r.name });
      const count = el("span", { class: "muted", text: selectedOf(r.order.length, r.frames.length) });
      const selAll = el("button", { class: "btn small", text: t("selectAll") });
      const clrAll = el("button", { class: "btn small", text: t("clearAll") });
      head.append(name, count, selAll, clrAll);
      const gridEl = el("div", { class: "frame-grid" });
      block.append(head, gridEl);
      ui.select.appendChild(block);

      const refresh = () => {
        renderFrameGrid(gridEl, r.frames, r.order, () => refresh());
        count.textContent = selectedOf(r.order.length, r.frames.length);
        updateSaveLabel();
      };
      selAll.onclick = () => { r.order = r.frames.map((f) => f.id); refresh(); };
      clrAll.onclick = () => { r.order = []; refresh(); };
      refresh();
    }
    show(ui.saveBar, true);
    updateSaveLabel();
    ui.saveAll.onclick = saveAll;
  }

  function totalSelected() { return state.results.reduce((n, r) => n + r.order.length, 0); }
  function hasAnythingToSave() { return state.results.some((r) => r.transcript || r.frames.length); }
  function updateSaveLabel() {
    ui.saveAll.textContent = saveSelected(totalSelected());
    ui.saveAll.disabled = totalSelected() === 0 && !state.results.some((r) => r.transcript);
  }

  async function saveAll() {
    const fmt = settings.get("format");
    const stitch = settings.get("stitchFrames");
    const folderName = `${state.label || "batch"}-batch-${stamp()}`;
    const entries = [];
    let framesTotal = 0;
    for (const r of state.results) {
      const selected = r.order.map((id) => r.frames.find((f) => f.id === id)).filter(Boolean);
      const files = selected.map((f) => ({ name: f.filename, blob: f.blob }));
      if (stitch && selected.length) {
        const blob = await stitchFrames(selected.map((f) => f.bitmap), { format: fmt, jpegQuality: settings.get("jpegQuality") });
        if (blob) files.push({ name: `combined.${fmt}`, blob });
      }
      if (r.transcript) {
        if (r.transcript.tp.writeTxt) files.push({ name: "transcript.txt", blob: new Blob([buildTXT(r.transcript.text)], { type: "text/plain" }) });
        if (r.transcript.tp.writeSrt && r.transcript.chunks.length) files.push({ name: "transcript.srt", blob: new Blob([buildSRT(r.transcript.chunks)], { type: "text/plain" }) });
      }
      if (!files.length) continue;
      // Each video gets its own subfolder, all under APP_FOLDER/<batch>/…
      for (const f of files) entries.push({ path: `${APP_FOLDER}/${folderName}/${baseName(r.name)}/${f.name}`, blob: f.blob });
      framesTotal += selected.length;
    }
    if (!entries.length) return;

    ui.saveAll.disabled = true;
    try {
      await zipAndDownload(entries, `${APP_FOLDER}-${folderName}.zip`);
      showSaved(framesTotal);
    } catch { setNotice(t("errorTitle"), true); ui.saveAll.disabled = false; }
  }

  function showSaved(count) {
    show(ui.select, false); show(ui.saveBar, false); show(ui.saved, true);
    const suffix = settings.get("stitchFrames") ? stitchedSuffix() : "";
    const note = {
      ru: `Скачано в «Загрузки» → распакуйте архив: внутри папка ${APP_FOLDER}.`,
      uk: `Завантажено в «Завантаження» → розпакуйте архів: усередині папка ${APP_FOLDER}.`,
      en: `Downloaded to Downloads → unzip it: contains a ${APP_FOLDER} folder.`,
    };
    ui.saved.innerHTML = `<div class="row">✅ <strong>${escapeHtml(savedFrames(count) + suffix)}</strong></div><p class="hint">${escapeHtml(pickLang(note))}</p>`;
  }

  // ---------- misc ----------
  function setNotice(text, isError = false) { ui.notice.textContent = text; ui.notice.classList.toggle("error", isError); show(ui.notice, !!text); }

  function reset() {
    for (const r of state.results) disposeFrames(r.frames);
    for (const v of state.videos) if (v.thumb) { try { URL.revokeObjectURL(v.thumb); } catch {} }
    state.label = ""; state.videos = []; state.results = []; state.ran = false;
    show(ui.body, false); show(ui.progress, false); show(ui.runBar, false);
    show(ui.select, false); show(ui.saveBar, false); show(ui.saved, false);
    clear(ui.grid); clear(ui.statusList); clear(ui.select);
    setNotice("");
  }

  function errMsg(e) {
    if (e?.code === "no-audio") return pickLang({ ru: "нет звука", uk: "немає звуку", en: "no audio" });
    return (e && (e.message || String(e))) || t("statusFailed");
  }
}

function escapeHtml(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function pickLang(map) { return map[document.documentElement.lang] || map.ru; }
