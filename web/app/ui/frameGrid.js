// Frame selection grid with click-order numbering (the desktop FrameSelectGrid behaviour:
// click frames in the order you want; the badge shows that order; click again to deselect).

import { el, clear, fmtClock } from "./dom.js";

/**
 * @param {HTMLElement} container
 * @param {Array} frames  [{ id, url, time }]
 * @param {string[]} order  ordered list of selected ids (mutated via callbacks)
 * @param {(order:string[])=>void} onChange
 */
export function renderFrameGrid(container, frames, order, onChange) {
  clear(container);
  for (const f of frames) {
    const pos = order.indexOf(f.id);
    const selected = pos >= 0;
    const cell = el("div", { class: "frame-cell" + (selected ? " selected" : "") }, [
      el("img", { src: f.url, alt: "", loading: "lazy" }),
      selected ? el("div", { class: "order-badge", text: String(pos + 1) }) : null,
      el("div", { class: "time-badge", text: fmtClock(f.time) }),
    ]);
    cell.addEventListener("click", () => {
      const i = order.indexOf(f.id);
      if (i >= 0) order.splice(i, 1);
      else order.push(f.id);
      onChange(order);
    });
    container.appendChild(cell);
  }
}
