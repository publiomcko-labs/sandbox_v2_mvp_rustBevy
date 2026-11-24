# B15.2 — Coherent edit/seam publication and B11 far-shell isolation

**Result (2026-11-24):** `B15_2_WINDOWS_VULKAN_MATRIX_PASS_VISUAL_PENDING`. The Windows/Vulkan A/B/C test passed in the experimental branch; **visual defects and strict 60 FPS have not been qualified as resolved**. Main and B13/B15.1 checkpoints were not modified.

## Initial evidence and defect

The real B15.1 local survey (13 edits) showed 6 additional seam-mask regeneration bursts beginning 29–58 ms after edits, spanning 66 neighboring chunks; 0 logical horizon holes after 20s, 0 flagged LOD seam frames and 6042 GPU relocations. This is *not* pixel evidence, because the gdigrab `title=` video was visually frozen. Read `B15_1_DIAGNOSTICO_LOCAL_20261124.md` in the chat for the original local diagnostics.

B15.1 prioritized the edited chunk before previously queued LOD replacements. At edit time, nearby LOD targets could have been prepared with a different seam snapshot. The subsequent reconciliation can schedule additional GPU meshes. B15.2 addresses that specific scheduling hazard, not every possible raster defect.

## Implementation

- `SANDBOX_B15_2_EDIT_ATOMIC=1` (default in this experimental B15.2 branch): read one visible LOD snapshot, find edited chunks plus the 3x3x3 seam dependency neighborhood, compute required revisions and seam masks, replace only genuinely changed meshes, and publish the coherent GPU-ready edit cohort together. **Do not cancel unrelated in-flight LOD jobs.** Mode `0` is the unchanged B15.1 edit-priority reference in the same executable.
- `SANDBOX_B15_2_FAR_FIELD=0`: suppress only the B11 distant visual shell. B11 stage, canonical 130m SDF streaming, mixed LOD, physics and all telemetry remain active. Default is shell on. This isolates a distinct source of visual cutoff/swap artifacts.
- `scripts/b15-2-local-60fps.ps1`: interactive regional gdigrab capture based on `GetClientRect` + `ClientToScreen`, not `title=` window capture or the entire desktop. An eight-second preflight demands visible camera motion and compares two decoded gray images. `Auto` honors the scripted route's twelve-second initial hold. It reports actual encoded FPS and packages video, B14 trace and logs. The preflight was syntax-checked in the CI but still requires Windows interactive desktop verification.
- B14 logical visibility and LOD-seam audit are unchanged. A ready signal is emitted after GPU dispatch recording; it is **not** a GPU fence or a proof that a given monitor frame was presented.

## Evidence anchors

- Source branch tested: `fix/b15-2-edit-cohort-far-coverage-20261124`, commit `4ae403fb11e9021cba76b6fc84720e4dae2b7c0b`.
- Successful Windows/Vulkan matrix: https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45472442434
- Artifacts: `b15-2-vulkan-matrix-evidence` ID `14956199211` and `b15-2-windows-release` ID `14957568442`.
- `B15_2_MATRIX_SUMMARY.json` and per-arm `B15_2_ARM.json` are in the evidence artifact.

All arms use 16MiB GPU slabs, B11 SDF world, the same scripted route with 18m/s turns/revisits, six scripted alternating add/subtract edits, B14 per-frame trace, and three 1920×1080 GPU capture images.

| Metric | B15.1 edit logic / B11 on | B15.2 atomic / B11 on | B15.2 atomic / B11 off |
|---|---:|---:|---:|
| Scripted edits | 6 | 6 | 6 |
| Modified chunk publications | 22 | 22 | 22 |
| Maximum edited-chunk publication (ms) | 37.372 | 39.374 | 40.860 |
| Edited-chunk publications >100ms | 0 | 0 | 0 |
| GPU mesh relocations | 6017 | 6014 | 6038 |
| B15.2 edit cohort commits requested | 0 | 6 | 6 |
| Edited/repaired cohort chunks tracked | 0 | 22 | 22 |
| Canceled LOD jobs | 0 | 4 | 0 |
| Post-edit seam repairs, B15.2-only instrumentation | N/A | 4 | 0 |
| Total seam-reconciliation log events | 0 | 1 | 0 |
| B11 distant shell changes | 23 | 23 | 0 |
| Missing logical required frames after 20s | 0 | 0 | 0 |
| LOD seam invalid frames | 0 | 0 | 0 |
| GPU/runtime errors | 0 | 0 | 0 |
| B14 recorded frame rows | 4295 | 4301 | 4291 |
| p95 logical frame interval (ms) | 23.6 | 23.1 | 23.5 |
| Frame intervals >100ms | 11 | 11 | 11 |

The first B15.2 attempt canceled 68 and 121 LOD jobs and generated additional seam repairs. It was **not accepted**; the code was revised to preserve unaffected neighboring LOD targets. This final matrix reduced those cancelations to four/zero without losing the edit 100ms gate. Results show no clear overall FPS gain yet.

## Boundaries and next gate

**Qualified:** Rust release, SDF/streaming tests, PowerShell 5.1 script parser, three Windows/Vulkan runs, 6 edits per arm, logical 130m coverage after startup, LOD seam audit, frame telemetry and B11 off/on control.

**Not qualified:** zero one-frame flickers, exact GPU present timing, mouse-to-pixel latency, complete edited voxel/LOD topology correctness, strict 16.7ms full frame budget, and confirmed motion capture on the interactive Vulkan window. Four post-edit seam repairs still occurred in the atomic+B11-on arm; these may or may not be related to the user's visual defect.

Next: run `scripts/b15-2-local-60fps.ps1` on the local interactive Windows desktop with `-FarShell 1 -AtomicEdits 1`, move during the preflight, edit while moving/turning and revisit modified areas, run `scripts/b15-correlate-video.py` on the captured session. If a movement flicker recurs, repeat with `-FarShell 0` under similar conditions. Keep `main` and B13 unchanged until pixel evidence identifies the failure or clears the issue.
