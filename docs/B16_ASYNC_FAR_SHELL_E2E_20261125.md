# B16 — Asynchronous B11 far-shell reconstruction

**Date:** 2026-11-25
**Result:** `B16_ASYNC_FAR_SHELL_VULKAN_E2E_PASS` (**headless-functional; interactive visual pending**)
**Actions:** https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45683407793
**Source baseline:** `checkpoint/b15-7-headless-frame-pacing-20261125` with the **user-visually-approved B15.5 configuration**, and B15.6 conservative culling explicitly disabled in both comparison arms.

## Justification

The B11 distant terrain shell is an 89×89 CPU-generated height grid. Under a normal 18 m/s camera route, crossing a snapped 48 m center boundary rebuilds the entire mesh using CPU SDF samples, normal calculations and index generation directly inside `maintain_far_coverage` in Bevy's `Update` schedule. Although the renderer already keeps the prior shell during a delayed replacement, geometry generation was still synchronous and added ~1.9 ms to the main thread on each crossing.

This is a **specific observed main-thread cost** with a safe asynchronous boundary, not another speculative p95 frame-time optimization.

## Change

The opt-in `SANDBOX_B16_ASYNC_FAR_SHELL=1`:

- Keeps initial shell construction synchronous, preserving first-load coverage.
- Spawns **at most one** background native worker to compute only `shell_geometry(center)` for subsequent snapped camera positions; no `Commands`, `Assets<Mesh>` or renderer data leave Bevy's main thread.
- Uses a bounded single-result `sync_channel(1)` and a `Mutex<Receiver>` resource so the worker never blocks the Update thread; the Update system merely polls `try_recv`.
- Discards results for obsolete snapped centers when the camera moves, without altering the existing rendered shell.
- Creates the Bevy `Mesh` asset and stages the replacement on the main thread only after a matching worker result is ready; preserves the existing eight-frame overlap and old-mesh retention.
- Keeps the original synchronous behavior when the flag is absent/0, including B15.5/B15.6.
- Does not change terrain SDF, rocks, water, physics, 130 m horizon, GPU extraction, LOD seams, fixed GPU slabs, edit transactions, or persistence.

**Safety limitations:** the background worker consumes CPU time (it is moved, not eliminated); native OS scheduling and lock contention remain possible. `std::thread` is appropriate for the Windows desktop MVP, but a longer-term task pool may be more appropriate for other targets. Full presented-pixel seamlessness still needs an interactive visual check before default promotion.

## Minimal Windows Vulkan E2E

One Rust Release build, then **two matched** GPU-headless 1920×1080 runs through the standard 18m/s B11 survey, fixed B15.5 32MiB GPU slabs, six scripted edits, and three screenshots per arm. B15.6 frustum culling was disabled to avoid adding an unapproved visual change. All other flags and instrumentation were identical.

| Measurement | B15.5 sync far-shell control | B16 async far-shell candidate |
|---|---:|---:|
| Published far-shell builds | 13 (12 after initial) | 13 (12 after initial) |
| Worker jobs scheduled/completed | 0 / 0 | **12 / 12** |
| Main-thread shell rebuild cost p95, excluding initial | **1,888 µs** | **10 µs** |
| Reduction in main-thread shell rebuild cost p95 | — | **99.5%** |
| Worker-only geometry computation, mean | — | **1,862 µs** |
| MainWorld B14 frame-gap p95 t20–44s | 19 ms | 19 ms |
| MainWorld B14 max frame-gap t20–44s | 55 ms | 53 ms |
| Six scripted SDF edits / published edited meshes | 6 / 22 | 6 / 22 |
| Maximum edit publication latency | 38.610 ms | 36.971 ms |
| GPU live-mesh relocation events | 0 | 0 |
| Missing required frames / LOD-invalid frames / runtime errors | 0 / 0 / 0 | 0 / 0 / 0 |
| 1920×1080 screenshots | 3 | 3 |

The three matched screenshot pairs (same scripted route at t12,35,46s) were opened and compared. Each was 1920×1080 with matching broad terrain, rock and water coverage. Mean per-channel absolute RGB pixel differences across pairs were `(0.228,0.283,0.211)`, `(0.733,1.238,0.645)` and `(0.591,0.756,0.468)` out of 255, reflecting scene timing/pose variation. These are descriptive and do **not** establish continuous absence of one-frame disappearance.

**Conclusion:** Asynchronous shell computation removed an independently measured recurrent B11 main-thread task with no observed regression. It did **not** establish an improvement in 19ms B14 p95 or an external 60FPS/16.7ms present-time qualification. Do not overstate.

## Next gate / promotion

- Checkpoint B16 as an **E2E-qualified opt-in experiment**; leave `main` untouched.
- Preserve `checkpoint/b15-5-visual-approved-20261125` as the last **user-visually-approved** reference.
- **No additional Vulkan/PresentMon/FFmpeg benchmark campaigns are required** to finish B16. A single normal interactive session observing 18m/s movement and rapid camera rotations is sufficient before enabling this feature by default.
- Until interactive approval, the flag remains off by default.
- Longer-term improvements to water shore masks or rock persistence scalability should be prioritized separately based on actual MVP requirements; do not bundle them into this latency change.

**Artifacts:** `b16-async-far-shell-e2e-evidence` (GitHub Actions artifact `15054164816`), and `b16-windows-runtime` (artifact `15054344917`).
