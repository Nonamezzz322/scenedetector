// Load a direct video URL into an in-memory File, so the rest of the pipeline treats it
// exactly like a local upload (same-origin blob URL → no canvas tainting).
//
// No backend needed — but the remote server MUST allow cross-origin reads (CORS). Social
// platforms (YouTube/TikTok/Instagram) serve HTML watch pages and need yt-dlp, so they are
// not supported on a static host.

export class RemoteError extends Error {
  constructor(code) { super(code); this.name = "RemoteError"; this.code = code; }
}

export async function fetchUrlToFile(url, { onProgress, signal } = {}) {
  let res;
  try {
    res = await fetch(url, { signal, mode: "cors", redirect: "follow" });
  } catch {
    throw new RemoteError("fetch-failed"); // network error or CORS rejection
  }
  if (!res.ok) throw new RemoteError(`http-${res.status}`);

  const type = res.headers.get("content-type") || "";
  if (/^text\/html/i.test(type)) throw new RemoteError("not-a-file"); // e.g. a YouTube page

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
  return new File([blob], filenameFromUrl(url, type), { type: blob.type || type || "video/mp4" });
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
