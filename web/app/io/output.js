// Writes result jobs either into a local folder (File System Access API) or as a ZIP download.
//
// jobs: [{ folder?: string, files: [{ name, blob }] }]

import { getSubdir, writeFile, ensureWritePermission } from "./localFolder.js";
import { zipAndDownload } from "./save.js";

/**
 * @param {Object} opts
 * @param {FileSystemDirectoryHandle|null} opts.baseDirHandle  write target (folder mode)
 * @param {string} opts.zipName  fallback ZIP filename
 * @returns {Promise<{mode:'folder'|'zip'}>}
 */
export async function writeJobs(jobs, { baseDirHandle, zipName }) {
  if (baseDirHandle && (await ensureWritePermission(baseDirHandle))) {
    for (const job of jobs) {
      const dir = job.folder ? await getSubdir(baseDirHandle, sanitizeDir(job.folder)) : baseDirHandle;
      for (const f of job.files) await writeFile(dir, f.name, f.blob);
    }
    return { mode: "folder" };
  }
  const entries = [];
  for (const job of jobs) {
    for (const f of job.files) {
      entries.push({ path: job.folder ? `${sanitizeDir(job.folder)}/${f.name}` : f.name, blob: f.blob });
    }
  }
  await zipAndDownload(entries, zipName);
  return { mode: "zip" };
}

function sanitizeDir(name) {
  return String(name).replace(/[/\\:*?"<>|]/g, "_");
}
