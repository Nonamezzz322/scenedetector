// Wires the settings overlay controls to the persistent settings store + the app-language switch.

import { $, $$, show, setSegActive } from "./dom.js";
import * as settings from "../settings.js";
import { getLang, setLang } from "../i18n.js";

export function initSettingsPanel() {
  // ----- App language -----
  setSegActive($("#appLang"), "data-lang", getLang());
  $$("#appLang .seg-btn").forEach((b) =>
    b.addEventListener("click", () => {
      setLang(b.getAttribute("data-lang"));
      setSegActive($("#appLang"), "data-lang", getLang());
    })
  );

  // ----- Sensitivity (slider + presets + label) -----
  const threshold = $("#threshold");
  const thresholdVal = $("#thresholdVal");
  const sensPreset = $("#sensPreset");
  const syncThreshold = (v) => {
    threshold.value = v;
    thresholdVal.textContent = Number(v).toFixed(2);
    setSegActive(sensPreset, "data-val", nearestPreset(Number(v)));
  };
  syncThreshold(settings.get("threshold"));
  threshold.addEventListener("input", () => { settings.set("threshold", Number(threshold.value)); syncThreshold(threshold.value); });
  $$("#sensPreset .seg-btn").forEach((b) =>
    b.addEventListener("click", () => { const v = Number(b.getAttribute("data-val")); settings.set("threshold", v); syncThreshold(v); })
  );

  // ----- Checkboxes -----
  bindCheckbox("#dedupScenes", "dedupScenes");
  bindCheckbox("#rejectLowDetail", "rejectLowDetail");
  bindCheckbox("#stitchFrames", "stitchFrames");
  bindCheckbox("#txTxt", "tx_txt");
  bindCheckbox("#txSrt", "tx_srt");

  // ----- Numbers -----
  bindNumber("#settleDelay", "settleDelay");
  bindNumber("#minInterval", "minInterval");
  bindNumber("#maxWidth", "maxWidth");
  bindNumber("#maxFrames", "maxFrames");

  // ----- Text -----
  const tpl = $("#filenameTemplate");
  tpl.value = settings.get("filenameTemplate");
  tpl.addEventListener("change", () => settings.set("filenameTemplate", tpl.value || "scene_{index}_{time}"));

  // ----- JPEG quality + format -----
  const jq = $("#jpegQuality");
  const jqVal = $("#jpegQualityVal");
  jq.value = settings.get("jpegQuality");
  jqVal.textContent = settings.get("jpegQuality");
  jq.addEventListener("input", () => { settings.set("jpegQuality", Number(jq.value)); jqVal.textContent = jq.value; });

  const updateFormat = (v) => {
    settings.set("format", v);
    setSegActive($("#format"), "data-val", v);
    show($("#jpegQualityRow"), v === "jpg");
  };
  updateFormat(settings.get("format"));
  $$("#format .seg-btn").forEach((b) => b.addEventListener("click", () => updateFormat(b.getAttribute("data-val"))));

  // ----- Transcription language + device -----
  bindSegmented("#txLang", "data-lang", "tx_language");
  bindSegmented("#txDevice", "data-val", "tx_device");

  // ----- CORS proxy URL -----
  const proxy = $("#proxyUrl");
  proxy.value = settings.get("proxyUrl");
  proxy.addEventListener("change", () => settings.set("proxyUrl", proxy.value.trim().replace(/\/+$/, "")));
}

function bindCheckbox(sel, key) {
  const node = $(sel);
  node.checked = !!settings.get(key);
  node.addEventListener("change", () => settings.set(key, node.checked));
}

function bindNumber(sel, key) {
  const node = $(sel);
  node.value = settings.get(key);
  node.addEventListener("change", () => {
    const n = Number(node.value);
    settings.set(key, Number.isFinite(n) ? n : settings.get(key));
  });
}

function bindSegmented(containerSel, attr, key) {
  const container = $(containerSel);
  setSegActive(container, attr, settings.get(key));
  $$(`${containerSel} .seg-btn`).forEach((b) =>
    b.addEventListener("click", () => { const v = b.getAttribute(attr); settings.set(key, v); setSegActive(container, attr, v); })
  );
}

function nearestPreset(t) {
  return [0.45, 0.30, 0.18].reduce((a, b) => (Math.abs(b - t) < Math.abs(a - t) ? b : a), 0.30);
}
