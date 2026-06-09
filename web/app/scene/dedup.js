// Port of SceneExtractor.dedupDistinct (Swift).
// Keeps only frames whose perceptual difference from EVERY already-kept frame is >= a cutoff
// derived from the sensitivity. Among near-duplicates the SHARPER frame wins (higher detail),
// so a settled scene beats a soft/half-faded transition frame of the same shot.
//
// candidates: [{ id, time, detail, dhash, ...payload }] in capture order.
// onDrop(candidate) is called for every dropped candidate (so the caller can free bitmaps).
// Returns the kept candidates in order.

import { hammingNormalized } from "./dhash.js";

export function dedupDistinct(candidates, threshold, onDrop) {
  const cutoff = Math.min(0.45, Math.max(0.02, threshold * 0.5));
  const kept = [];
  for (const c of candidates) {
    let nearest = -1;
    let nearestDist = Infinity;
    if (c.dhash) {
      for (let i = 0; i < kept.length; i++) {
        const d = hammingNormalized(kept[i].dhash, c.dhash);
        if (d != null && d < nearestDist) { nearestDist = d; nearest = i; }
      }
    }
    if (nearest >= 0 && nearestDist < cutoff) {
      // Near-duplicate: keep whichever frame is sharper.
      if (c.detail > kept[nearest].detail) {
        if (onDrop) onDrop(kept[nearest]);
        kept[nearest] = c;
      } else if (onDrop) {
        onDrop(c);
      }
    } else {
      kept.push(c);
    }
  }
  return kept;
}
