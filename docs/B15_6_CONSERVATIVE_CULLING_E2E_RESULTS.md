# B15.6 — Conservative GPU terrain frustum culling, essential Windows Vulkan E2E

**Date:** 2026-11-25
**Branch:** `exp/b15-6-conservative-terrain-frustum-20261125`
**E2E Windows run:** https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45629673662
**Status:** `B15_6_CONSERVATIVE_CULLING_HEADLESS_E2E_PASS_PRESENT_PENDING`
**Base:** user-visually-approved B15.5, `checkpoint/b15-5-visual-approved-20261125`, commit `729ec23b`.

## Intervention

B13 disabled CPU frustum culling on all GPU-generated terrain entities because their CPU-side mesh placeholders contain only zero vertices. This meant that about 824 terrain meshes inside the streaming residency ring were all eligible for drawing, including those behind the camera. B15.6 isolates the render-efficiency optimization without changing procedural terrain, water/rocks, physics, LOD scheduling or editing.

When the opt-in `SANDBOX_B15_6_CONSERVATIVE_CULLING=1` is set:

- Each 16m terrain block gets a static local `Aabb::from_min_max(Vec3::splat(-4.0), Vec3::splat(20.0))`, a **conservative** bound for the GPU-generated Surface Nets negative halo and mixed-LOD transition vertices across LOD0/1/2.
- `NoAutoAabb` prevents Bevy from replacing this explicit bound with the all-zero CPU placeholder AABB when mesh assets change during edits or LOD replacement.
- `NoFrustumCulling` is omitted from those terrain entities only. Existing B15.5/B13 behavior remains the fallback whenever the B15.6 opt-in is absent.
- The GPU extraction, atomic SDF edit cohort, block residency/130m horizon, rocks and water are unchanged.
- The approved B15.5 `SANDBOX_B15_5_FIXED_SLABS=1` stays on **in both E2E arms**, isolating the frustum-culling policy.

**Caveat:** If future GPU shaders begin placing geometry beyond the current [-4m,20m] per-axis local conservative bounds, the bound must be updated. A renderer's CPU `ViewVisibility` selection is a proxy for draw eligibility, not a direct GPU draw-call counter or definitive rendered-pixel proof.

## Essential E2E: single matched A/B

The Windows self-hosted GitHub Actions runner built Rust release once and executed exactly two matched GPU-headless Vulkan 1920×1080 runs with B11 far shell enabled, 18m/s survey path, equal B14 and B15.4 instrumentation, B15.2 atomic edits, fixed 32MiB Bevy slabs, and all six scripted SDF edits at seconds 25–40. Each run recorded three screenshots at t12/35/46 seconds. No PresentMon, external DXGI recording or manual local activity was needed.

| Measurement | B15.5 uncullled fixed slabs | B15.6 conservative culling |
|---|---:|---:|
| Avg. `ViewVisibility` selected terrain meshes, t20–44s | **823.5** | **205.6** |
| Reduction in selected terrain meshes | — | **75.0%** |
| Avg. logically published terrain blocks | 823.5 | 823.7 |
| B14 wall-clock frame-gap p95, t20–44s | **19ms** | **19ms** |
| B14 largest gap, t20–44s | **58ms** | **54ms** |
| B14 trace frames | 2,792 | 2,796 |
| GPU allocator relocation events | 0 | 0 |
| Scripted SDF edits and edited mesh publications | 6 / 22 | 6 / 22 |
| Longest edited mesh GPU-ready latency | 38.932ms | 38.144ms |
| Logical required-horizon missing frames, t20–44s | 0 | 0 |
| LOD topology-invalid frames (runtime audit) | 0 | 0 |
| Runtime/Vulkan errors | 0 | 0 |
| 1920×1080 screenshots | 3 | 3 |

**Image inspection:** The three matched screenshot pairs at t12/35/46 seconds were visually inspected at combined overview resolution; terrain, rock distribution and water placement remained equivalent without obvious holes or lost bands. The small frame differences are consistent with timing/pose jitter and do not establish sub-frame flicker absence. A sampled 512×288 absolute RGB pixel difference was less than 0.7/255 per channel per screenshot, but this is descriptive only; no image-equivalence pass/fail threshold was set.

## Result, qualifications and checkpoint decision

1. **E2E functionality PASS.** No regression detected in headless Vulkan terrain, LOD seam audit, streaming horizon, atomic editing, GPU allocator stability, rocks/water screenshots or the automated route.
2. **Render eligibility improvement PASS.** A 75.0% reduction in `ViewVisibility`-selected terrain objects is useful headroom for future scene complexity. Do not equate it with an identical reduction in hardware draw calls or total GPU time.
3. **Frame-budget objective HOLD.** B14 wall-clock frame-gap p95 remained **19ms**, not below the strict 16.7ms full-frame target. p95 is derived from timestamp intervals and Windows frame pacing; external displayed-pixel present timing was not collected.
4. **Promotion:** checkpoint this as a **verified experimental culling candidate**. Keep B15.5 as the last **user-visually-approved** interactive reference and leave `main` unmodified. B15.6 opt-in should not be silently turned on in production without a future interactive visual validation.
5. **No additional campaign:** do not repeat tests or demand new desktop recordings to close this discrete B15.6 experiment. Further frame-time optimization requires a different, evidence-directed investigation of render/GPU frame pacing; avoid incremental changes to frustum bounds without a concrete visual defect.

**E2E evidence:** GitHub Actions artifact `b15-6-conservative-frustum-e2e-evidence`, artifact ID `15030710921`. Build artifact `b15-6-windows-runtime`, artifact ID `15030442289`.
