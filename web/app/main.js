// App bootstrap: i18n, tab switching, settings overlay, and tab wiring.

import { $, $$, show } from "./ui/dom.js";
import { applyI18n, onLangChange } from "./i18n.js";
import { initSettingsPanel } from "./ui/settingsPanel.js";
import { initVideoTab } from "./ui/videoTab.js";
import { initFolderTab } from "./ui/folderTab.js";

function initTabs() {
  const buttons = $$("#tabbar .seg-btn");
  buttons.forEach((btn) =>
    btn.addEventListener("click", () => {
      const tab = btn.getAttribute("data-tab");
      buttons.forEach((b) => b.classList.toggle("is-active", b === btn));
      $$(".tab-panel").forEach((p) => p.classList.toggle("is-active", p.id === `tab-${tab}`));
    })
  );
}

function initSettingsOverlay() {
  const overlay = $("#settingsOverlay");
  $("#settingsBtn").addEventListener("click", () => show(overlay, true));
  $("#settingsDone").addEventListener("click", () => show(overlay, false));
  overlay.addEventListener("click", (e) => { if (e.target === overlay) show(overlay, false); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !overlay.hidden) show(overlay, false); });
}

function boot() {
  applyI18n(document);
  initTabs();
  initSettingsOverlay();
  initSettingsPanel();
  initVideoTab();
  initFolderTab();
  onLangChange(() => applyI18n(document));
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
else boot();
