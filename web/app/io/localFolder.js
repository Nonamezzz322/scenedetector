// Local folder access. Two paths:
//   1. File System Access API (Chrome/Edge): pick a folder, list videos, write results back in place.
//   2. Fallback (Safari/Firefox): <input webkitdirectory> gives a FileList; results are ZIP-downloaded.

const VIDEO_EXT = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "m2ts", "mts", "mpg", "mpeg", "wmv", "flv", "3gp", "ogv", "ts"];

export function isFSAccessSupported() {
  return typeof window.showDirectoryPicker === "function";
}

export function isVideoFile(name) {
  const ext = (name.split(".").pop() || "").toLowerCase();
  return VIDEO_EXT.includes(ext);
}

export function listVideoFiles(fileList) {
  return Array.from(fileList).filter((f) => isVideoFile(f.name));
}

/** Returns a directory handle, or null if cancelled / unsupported. */
export async function pickDirectory() {
  if (!isFSAccessSupported()) return null;
  try {
    return await window.showDirectoryPicker({ mode: "readwrite" });
  } catch (e) {
    if (e && (e.name === "AbortError" || e.name === "NotAllowedError")) return null;
    throw e;
  }
}

/** Lists video File objects directly under a directory handle, with their handles. */
export async function listVideosInHandle(dirHandle) {
  const out = [];
  for await (const [name, handle] of dirHandle.entries()) {
    if (handle.kind === "file" && isVideoFile(name)) {
      out.push({ name, handle });
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

export async function getSubdir(dirHandle, name) {
  return dirHandle.getDirectoryHandle(name, { create: true });
}

export async function writeFile(dirHandle, name, blob) {
  const fh = await dirHandle.getFileHandle(name, { create: true });
  const w = await fh.createWritable();
  await w.write(blob);
  await w.close();
}

/** Verify/obtain readwrite permission on a handle (Chrome prompts once). */
export async function ensureWritePermission(handle) {
  if (!handle.queryPermission) return true;
  const opts = { mode: "readwrite" };
  if ((await handle.queryPermission(opts)) === "granted") return true;
  return (await handle.requestPermission(opts)) === "granted";
}
