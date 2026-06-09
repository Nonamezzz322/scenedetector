// Local folder helpers for the folder-tab input (read-only, via <input webkitdirectory>).
// We deliberately do NOT use the File System Access API here: Chrome blocklists sensitive
// folders (Downloads/Desktop/Documents/…), which is exactly what users want to pick.

const VIDEO_EXT = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "m2ts", "mts", "mpg", "mpeg", "wmv", "flv", "3gp", "ogv", "ts"];

export function isVideoFile(name) {
  const ext = (name.split(".").pop() || "").toLowerCase();
  return VIDEO_EXT.includes(ext);
}

export function listVideoFiles(fileList) {
  return Array.from(fileList).filter((f) => isVideoFile(f.name));
}
