---
name: implement-stage
description: Implement one stage (этап) of the SceneShot project from PLAN.md by routing to the right specialist subagent and verifying its acceptance criterion. Use when the user says "implement stage N", "сделай этап N", or "do the next stage" for this project.
---

# Implement a SceneShot stage

You are orchestrating implementation of **SceneShot** per `PLAN.md` (repo root). Argument: a stage number (1–9) or "next".

## Steps
1. **Read `PLAN.md` §5** and locate the requested stage. For "next", inspect the repo state and pick the first stage whose acceptance criterion is not yet met.
2. **Route to the right specialist** via the Agent tool, passing that stage's prompt text from PLAN.md verbatim plus "follow PLAN.md conventions":
   - Stages 1, 3, 5, 7 (UI / app layer / settings / results) → `swift-macos-engineer`.
   - Stages 2, 4, 6 (ffmpeg bundle, scene engine, URL handling) → `ffmpeg-engine-specialist`. Stage 2 also needs `fetch-ffmpeg.sh` → also bring in `macos-packaging-specialist`.
   - Stages 8, 9 (packaging, DMG, icon) → `macos-packaging-specialist`.
3. **Verify the acceptance criterion** stated for that stage. Build with `./Scripts/build.sh`. If it can't be auto-verified (visual/manual), say exactly what to check.
4. **Review**: spawn `swift-code-reviewer` (and `release-ux-reviewer` for stages 8–9) on the change. Fix blockers before declaring done.
5. Report: what was implemented, the acceptance-check result, and any follow-ups.

Do not skip the review step. Do not move past a failing acceptance criterion.
