// Port of SceneExtractor.fileName / sanitize (Swift).
// Template tokens: {index} (zero-padded to 4), {time} (hh-mm-ss), {name} (source basename).

export function makeFilename({ index, time, template, source, ext }) {
  const total = Math.round(time || 0);
  const p2 = (n) => String(n).padStart(2, "0");
  const timeStr = `${p2(Math.floor(total / 3600))}-${p2(Math.floor((total % 3600) / 60))}-${p2(total % 60)}`;

  let s = template && template.length ? template : "scene_{index}_{time}";
  s = s.replaceAll("{index}", String(index).padStart(4, "0"));
  s = s.replaceAll("{time}", timeStr);
  s = s.replaceAll("{name}", sanitize(source || "video"));
  s = sanitize(s);
  if (!s) s = `scene_${String(index).padStart(4, "0")}`;
  return `${s}.${ext}`;
}

export function baseName(filename) {
  const i = filename.lastIndexOf(".");
  return i > 0 ? filename.slice(0, i) : filename;
}

export function sanitize(s) {
  return String(s).replace(/[/\\:*?"<>|]/g, "_");
}
