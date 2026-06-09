---
name: review-changes
description: Run a SceneShot-specific review of the current changes using the project's reviewer subagents (Swift correctness/concurrency + release/UX), then aggregate the findings. Use before declaring a stage done or cutting a release.
---

# Review SceneShot changes

1. Determine scope: files changed since the last commit (or all of `Sources/` + `Scripts/` if there is no VCS, or on explicit request).
2. Spawn in parallel via the Agent tool:
   - `swift-code-reviewer` — correctness, concurrency, and the Process-deadlock / main-thread / comma-escaping / cancellation pitfalls.
   - `release-ux-reviewer` — only if `Scripts/`, signing, the DMG, or Info.plist changed (packaging + zero-console UX).
3. Aggregate their findings into one de-duplicated list ordered **Blocker → Should-fix → Nit**, each with `path:line` and a concrete fix.
4. State a single verdict: safe to ship / fix blockers first. Do NOT apply fixes unless the user asks — this is a review, not an edit pass.
