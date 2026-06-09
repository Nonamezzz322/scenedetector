// SceneShot Web — locked-down CORS proxy (Cloudflare Worker).
//
// Lets the static GitHub Pages site fetch DIRECT video files + Dropbox / Google Drive
// direct-download links, by refetching them server-side and adding CORS headers.
//
// This is NOT a general open proxy:
//   • only requests from ALLOWED_ORIGINS are answered (CORS Origin check);
//   • only non-HTML (media/octet-stream) responses are passed back;
//   • Dropbox/Drive share links are normalized to direct downloads here.
//
// It does NOT (and cannot) handle YouTube / TikTok / Instagram — those are HTML pages with
// encrypted streams and need yt-dlp on a real server.
//
// Deploy: see README.md in this folder. After deploy, paste the Worker URL into the app:
//   Настройки → «Прокси для ссылок».

// 👇 EDIT THIS to your site origin(s). Keep localhost for local testing.
const ALLOWED_ORIGINS = [
  "https://nonamezzz322.github.io",
  "http://localhost:8000",
  "http://127.0.0.1:8000",
];

export default {
  async fetch(request) {
    const origin = request.headers.get("Origin") || "";
    const cors = corsHeaders(origin);

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method !== "GET" && request.method !== "HEAD") return json({ error: "method" }, 405, cors);
    if (origin && !isAllowedOrigin(origin)) return json({ error: "origin not allowed" }, 403, cors);

    const target = new URL(request.url).searchParams.get("url");
    if (!target) return json({ error: "missing ?url=" }, 400, cors);

    let resolved;
    try { resolved = resolveTarget(target); }
    catch { return json({ error: "bad url" }, 400, cors); }

    let upstream;
    try { upstream = await fetch(resolved, fetchOpts()); }
    catch { return json({ error: "upstream fetch failed" }, 502, cors); }

    // Google Drive large-file "can't scan for viruses" confirm dance.
    const ct0 = upstream.headers.get("content-type") || "";
    if (/text\/html/i.test(ct0) && /google\.com/i.test(resolved)) {
      const html = await upstream.text();
      const confirmed = gdriveConfirmUrl(resolved, html);
      if (confirmed) {
        try { upstream = await fetch(confirmed, fetchOpts()); }
        catch { return json({ error: "gdrive confirm fetch failed" }, 502, cors); }
      }
    }

    if (!upstream.ok && upstream.status !== 206) {
      return json({ error: `upstream ${upstream.status}` }, upstream.status === 404 ? 404 : 502, cors);
    }
    const ct = upstream.headers.get("content-type") || "";
    if (/^text\/html/i.test(ct)) return json({ error: "not a media file (got an HTML page)" }, 415, cors);

    const headers = new Headers(cors);
    headers.set("Content-Type", ct || "application/octet-stream");
    const len = upstream.headers.get("content-length");
    if (len) headers.set("Content-Length", len);
    headers.set("Cache-Control", "no-store");
    return new Response(upstream.body, { status: upstream.status === 206 ? 206 : 200, headers });
  },
};

function fetchOpts() {
  return { redirect: "follow", headers: { "User-Agent": "Mozilla/5.0 (compatible; SceneShotProxy/1.0)" } };
}

function isAllowedOrigin(origin) { return ALLOWED_ORIGINS.includes(origin); }

function corsHeaders(origin) {
  return {
    "Access-Control-Allow-Origin": isAllowedOrigin(origin) ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Range, Content-Type",
    "Access-Control-Expose-Headers": "Content-Length, Content-Type, Content-Range, Accept-Ranges",
    "Vary": "Origin",
  };
}

function json(obj, status, cors) {
  return new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

// Normalize Dropbox / Google Drive share links to direct downloads.
function resolveTarget(raw) {
  const u = new URL(raw);
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("scheme");
  const host = u.hostname.toLowerCase();

  if (host.endsWith("dropbox.com")) {
    u.searchParams.set("dl", "1");        // force direct download (follows redirect to content host)
    return u.toString();
  }
  if (host.endsWith("drive.google.com") || host.endsWith("docs.google.com")) {
    const id = gdriveId(u);
    if (id) return `https://drive.usercontent.google.com/download?id=${id}&export=download&confirm=t`;
  }
  return raw;
}

function gdriveId(u) {
  const m = u.pathname.match(/\/file\/d\/([^/]+)/) || u.pathname.match(/\/d\/([^/]+)/);
  return m ? m[1] : u.searchParams.get("id");
}

// Best-effort confirm-token extraction for large Drive files (Google changes this periodically).
function gdriveConfirmUrl(prevUrl, html) {
  const action = html.match(/action="([^"]*drive\.usercontent\.google\.com\/download[^"]*)"/i);
  if (action) {
    let url = action[1].replace(/&amp;/g, "&");
    const fields = {};
    for (const m of html.matchAll(/name="([^"]+)"\s+value="([^"]*)"/g)) fields[m[1]] = m[2];
    const qs = new URLSearchParams(fields).toString();
    return qs ? url + (url.includes("?") ? "&" : "?") + qs : url;
  }
  const c = html.match(/confirm=([0-9A-Za-z_\-]+)/);
  if (c) { const u = new URL(prevUrl); u.searchParams.set("confirm", c[1]); return u.toString(); }
  return null;
}
