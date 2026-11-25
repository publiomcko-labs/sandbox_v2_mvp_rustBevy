# B15.3 — Matched DXGI/NVENC local 120-second matrix review

**2026-11-25 verdict:** `B15_3_DXGI_MATRIX_HOLD`. Both 120s captures succeeded at approximately 58 encoded FPS; six automated SDF edits per arm completed with logical coverage intact, but **the 16.7ms strict frame-time budget is not met**. No runtime errors or B14 logical seam violations. Neither absence of brief visual flickers nor mouse-to-pixel latency has been proved. **Do not promote to main or functional checkpoints.**

## Evidence and exact environment

The user provided archives `b15-2-Auto-shell1-atomic1-20261125-103808.zip`, `b15-2-Auto-shell0-atomic1-20261125-104111.zip` and `b15-3-dxgi-matrix-20261125-103808.json`.

Both use the same B15.2 Windows release executable, Win10/11 Vulkan desktop at 1920×1080, FFmpeg **7.1.1**, `ddagrab` DXGI→D3D11→`h264_nvenc`, `SANDBOX_B15_2_EDIT_ATOMIC=1`, B14 trace, scripted `survey` 18m/s path with six edits at t=25,28,31,34,37,40s, new persisted state per run. The only deliberate engine variable was `SANDBOX_B15_2_FAR_FIELD=1` versus `0`.

The video capture starts around game t=20.2s in both arms; thus **the six edits fall inside the recordings** (unlike earlier 15s local captures). The prescribed route becomes stationary around game t=120, explaining its low motion in the final portion of the 120s video.

## Corrected findings from raw B14/FFmpeg traces

| Metric | B11 on | B11 off |
|---|---:|---:|
| Actual encoded video frames / 120s | 6,992 / 58.27fps | 6,956 / 57.97fps |
| B14 frame rows across ~167 game seconds | 9,942 | 9,891 |
| B14 wall-clock frame interval p95, all rows | 24ms | 26ms |
| B14 wall-clock p95 inside recorded window | 23ms | 24ms |
| B14 game-time delta p95 | ~18.6ms | ~18.3ms |
| Wall-clock frame interval max **during video** | 369ms | 274ms |
| Wall-clock intervals >=33ms during video | 4 | 4 |
| Six scripted edits / atomic cohorts | 6 / 6 | 6 / 6 |
| Edited GPU mesh publications | **22** | **22** |
| Max edited-mesh publication latency | **42.5264ms** | **44.4789ms** |
| Edited mesh publications >100ms | 0 | 0 |
| Cancelled LOD work near edits | **24** | **1** |
| Post-edit seam-repair blocks | **20** | **1** |
| Stale LOD seam reconciliation events | **3** | **1** |
| B11 far-shell update events | 43 | 0 |
| GPU mesh relocations (sum of warning counts) | 6,076 | 5,998 |
| B14 logical coverage missing after 20s | 0 | 0 |
| B14 invalid LOD frames | 0 | 0 |
| Vulkan/runtime `ERROR` lines | 0 | 0 |

**The submitted matrix JSON incorrectly recorded 0 edited mesh publications, 0ms edit latency, and 0 post-edit seam repairs in both arms.** Rust tracing inserts ANSI SGR markers *between log keys and equal signs*; the original parser matched `latency_ms=...` and `b15_2_post_edit_repair_blocks=...` without stripping ANSI. The corrected analysis strips `\x1b\[[0-9;]*m`, reveals 22/22 publications and 20/1 seam repairs, and treats missing edition-publication telemetry as `HOLD`. The parser implementation and a synthetic ANSI regression test were added to `scripts/b15-3-local-dxgi-matrix.ps1` and the B15.3 workflow. The report did correctly identify the 24/26ms wall-clock p95 `HOLD`.

## Video checks and limitations

Reviewed 12 decoded 480×270 excerpts from each full recording at ten-second spacing. Both routes follow essentially the same camera path; B11 toggling changes distant scene coverage as intended. No obvious broad disappearing terrain regions were found at this sampling rate. Also decoded **all actual encoded frames** to 96×54 grayscale without frame-rate duplication (6,992 on/6,956 off) and screened for a strong *whole-frame* single-frame change immediately reverting on the next frame; none exceeded the tested absolute per-frame global luma-difference thresholds. **These checks cannot exclude small, local one-frame SDF cracks, shell boundary flashes, or GPU present issues.** Approximately 8.1% of decoded frame pairs were identical in both recordings, including legitimate stationary-route repeats; encoded frame count is not a Vulkan presentation oracle.

Three post-edit seam repair bursts (4/12/4 blocks) occur in B11-on at scripted edits #4/#5/#6, versus a one-block repair at edit #2 in B11-off. All edited-mesh publication log latencies stay below 45ms, but those values start *after synchronous persistent journal save* and end at a GPU-ready publication point, not an independently observed display-present time. The `B11 on` p95 is actually slightly **better** than `B11 off`; do not attribute the overall frame-time budget miss solely to B11 or treat the difference in seam repairs as causal proof.

## Decision

1. **B15.3 capture intervention is successful**: DXGI/NVENC increased actual local capture from `gdigrab` ~29.47fps to ~58fps in matched long runs, exposing edits during recording. No more long capture is needed solely to prove acquisition works.
2. **Game performance and visual correctness are not fully qualified**: p95 still >16.7ms; 369/274ms external audit spikes occurred within the recorded windows; monitor presentation and small-region one-frame flickers remain unproven.
3. Next focused experiment should instrument and correlate **B11 far-shell rebuilds, LOD job cancellations, post-edit seam regenerations, GPU mesh allocator relocations and external per-frame/present timestamps** on the same deterministic route with equal instrumentation. Prioritize inspecting the edit #4/#5/#6 ~game t34–40s windows and reproduce with/without B11. Avoid repeating the full 120s collection unless a candidate correction or new evidence dimension requires it. Avoid premature changes to SDF/LOD mesh publication before the root cause is isolated.
