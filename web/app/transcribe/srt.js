// Build TXT and SRT from Whisper chunks ({ start, end, text }).

export function formatSrtTime(sec) {
  if (!isFinite(sec) || sec < 0) sec = 0;
  // Round to whole milliseconds first so a .9996 fraction carries into seconds/minutes/hours
  // instead of emitting an invalid ',1000' field.
  const totalMs = Math.round(sec * 1000);
  const ms = totalMs % 1000;
  const totalSec = Math.floor(totalMs / 1000);
  const p2 = (n) => String(n).padStart(2, "0");
  const p3 = (n) => String(n).padStart(3, "0");
  return `${p2(Math.floor(totalSec / 3600))}:${p2(Math.floor((totalSec % 3600) / 60))}:${p2(totalSec % 60)},${p3(ms)}`;
}

export function buildSRT(chunks) {
  let out = "";
  let i = 1;
  for (const c of chunks) {
    const text = (c.text || "").trim();
    if (!text) continue;
    let start = Number.isFinite(c.start) ? c.start : 0;
    let end = Number.isFinite(c.end) ? c.end : start + 2;
    if (!(end > start)) end = start + 0.5;
    out += `${i}\n${formatSrtTime(start)} --> ${formatSrtTime(end)}\n${text}\n\n`;
    i++;
  }
  return out;
}

export function buildTXT(text) {
  return (text || "").trim() + "\n";
}
