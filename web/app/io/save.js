// Output: direct download of a single blob, or a ZIP of many entries (JSZip via CDN).

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

let _jszip = null;
async function loadJSZip() {
  if (!_jszip) {
    const mod = await import("https://cdn.jsdelivr.net/npm/jszip@3.10.1/+esm");
    _jszip = mod.default || mod;
  }
  return _jszip;
}

/** entries: [{ path: "sub/dir/file.jpg", blob }] */
export async function zipAndDownload(entries, zipName, onProgress) {
  const JSZip = await loadJSZip();
  const zip = new JSZip();
  for (const e of entries) zip.file(e.path, e.blob);
  const blob = await zip.generateAsync(
    { type: "blob", compression: "STORE" },
    onProgress ? (m) => onProgress(m.percent / 100) : undefined
  );
  downloadBlob(blob, zipName);
  return blob;
}
