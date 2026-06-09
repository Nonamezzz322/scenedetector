// Tiny DOM helpers.

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
    else if (v === true) node.setAttribute(k, "");
    else if (v !== false && v != null) node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    if (c == null) continue;
    node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

export function show(node, on = true) {
  if (node) node.hidden = !on;
}

export function clear(node) {
  if (node) node.replaceChildren();
}

/** Set the active button in a segmented control by data attribute. */
export function setSegActive(container, attr, value) {
  $$(".seg-btn", container).forEach((b) => {
    b.classList.toggle("is-active", b.getAttribute(attr) === String(value));
  });
}

export function fmtDuration(sec) {
  if (!isFinite(sec) || sec < 0) return "";
  const t = Math.round(sec);
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  const p2 = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${p2(m)}:${p2(s)}` : `${m}:${p2(s)}`;
}

export function fmtClock(sec) {
  const t = Math.max(0, Math.round(sec || 0));
  const p2 = (n) => String(n).padStart(2, "0");
  return `${p2(Math.floor(t / 60))}:${p2(t % 60)}`;
}

export function stamp() {
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}_${p2(d.getHours())}-${p2(d.getMinutes())}-${p2(d.getSeconds())}`;
}
