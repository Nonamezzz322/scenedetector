// Load a video by URL into an in-memory File, so the rest of the pipeline treats it exactly
// like a local upload (same-origin blob URL → no canvas tainting).
//
// Routing:
//   • direct video file  → fetch directly; if blocked by CORS and a proxy is set, retry via proxy.
//   • Dropbox / Google Drive → always via the CORS proxy (they don't send CORS headers; the proxy
//     also normalizes the share link to a direct download).
//   • YouTube / TikTok / Instagram → NOT possible (HTML pages + encrypted streams need yt-dlp).
//
// The proxy is an optional Cloudflare Worker the user deploys (see /cloudflare-proxy). No backend
// is required for plain CORS-enabled direct links.

export class RemoteError extends Error {
  constructor(code) { super(code); this.name = "RemoteError"; this.code = code; }
}

const SOCIAL = /(?:^|\.)(?:youtube\.com|youtu\.be|tiktok\.com|instagram\.com|facebook\.com|fb\.watch|vimeo\.com)$/i;
const CLOUD = /(?:^|\.)(?:dropbox\.com|dropboxusercontent\.com|drive\.google\.com|docs\.google\.com|drive\.usercontent\.google\.com)$/i;

function hostOf(url) { try { return new URL(url).hostname; } catch { return ""; } }

/** "social" | "cloud" | "direct" */
export function classifyLink(url) {
  const h = hostOf(url);
  if (SOCIAL.test(h)) return "social";
  if (CLOUD.test(h)) return "cloud";
  return "direct";
}

export async function loadVideoFromLink(url, { proxyUrl, onProgress, signal } = {}) {
  const kind = classifyLink(url);
  if (kind === "social") throw new RemoteError("social");

  if (kind === "cloud") {
    if (!proxyUrl) throw new RemoteError("needs-proxy");
    return fetchToFile(proxyUrl, url, { onProgress, signal });
  }

  // direct file: try straight, then via proxy if available
  try {
    return await fetchToFile(null, url, { onProgress, signal });
  } catch (e) {
    if (e instanceof RemoteError && e.code === "not-a-file") throw e;
    if (proxyUrl) return fetchToFile(proxyUrl, url, { onProgress, signal });
    throw new RemoteError("cors");
  }
}

/** If proxyBase is set → GET `${proxyBase}?url=<target>`; else GET target directly. */
async function fetchToFile(proxyBase, target, { onProgress, signal } = {}) {
  const fetchUrl = proxyBase
    ? `${proxyBase}${proxyBase.includes("?") ? "&" : "?"}url=${encodeURIComponent(target)}`
    : target;

  let res;
  try { res = await fetch(fetchUrl, { signal, mode: "cors", redirect: "follow" }); }
  catch { throw new RemoteError("fetch-failed"); }
  if (!res.ok) throw new RemoteError(`http-${res.status}`);

  const type = res.headers.get("content-type") || "";
  if (/^text\/html/i.test(type)) throw new RemoteError("not-a-file");

  const total = Number(res.headers.get("content-length")) || 0;
  let blob;
  if (res.body && onProgress && total > 0) {
    const reader = res.body.getReader();
    const chunks = [];
    let received = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      onProgress(Math.min(1, received / total));
    }
    blob = new Blob(chunks, { type });
  } else {
    blob = await res.blob();
  }
  return new File([blob], filenameFromUrl(target, type), { type: blob.type || type || "video/mp4" });
}

function filenameFromUrl(url, type) {
  try {
    const u = new URL(url);
    let base = decodeURIComponent((u.pathname.split("/").pop() || "").trim()) || "video";
    if (!/\.[a-z0-9]{2,5}$/i.test(base)) {
      const ext = ((type.split("/")[1] || "mp4").split(";")[0]).replace(/[^a-z0-9]/gi, "") || "mp4";
      base = `${base}.${ext}`;
    }
    return base.replace(/[/\\:*?"<>|]/g, "_");
  } catch {
    return "video.mp4";
  }
}
