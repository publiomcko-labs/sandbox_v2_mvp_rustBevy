# B15.5 — fixed Bevy GPU mesh slabs (essential Vulkan A/B)

**Date:** 2026-11-25  
**Experimental branch:** `exp/b15-5-fixed-mesh-slabs-20261125`  
**Result:** `B15_5_FIXED_SLABS_HEADLESS_PASS_VISUAL_PRESENT_PENDING`  
**Windows CI run:** https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45624581944

## Mechanism and intervention

Bevy 0.20.1's `SlabAllocator` grows its shared general mesh slabs by allocating a new GPU buffer, copying the old bytes to the new one, and marking resident mesh allocation keys displaced. The engine's B15.1 `prepare_b2` compares each resident GPU vertex/index buffer ID and range with the current `MeshAllocator` allocation. When a slab grows, hundreds of resident mesh buffer IDs change simultaneously. To avoid stale or uninitialized geometry being drawn, the engine currently re-extracts **all relocated live meshes in the same render frame** instead of applying the five-new-mesh streaming quota. Prior on-machine DXGI captures and Windows headless CI consistently recorded approximately 6,000 aggregate relocations over the route, with single events affecting over 900 meshes.

**One isolated policy change:** `SANDBOX_B15_5_FIXED_SLABS=1` makes Bevy `MeshAllocatorSettings.slab_allocator_settings.min_slab_size = max_slab_size = 32 MiB`, leaving `extra_buffer_usages = STORAGE` and other GPU generation/seam/LOD gameplay behavior unchanged. Once a general slab fills, Bevy makes a separate general slab instead of increasing the existing GPU buffer. The original B15.1 growing slab policy is retained whenever the B15.5 opt-in flag is unset or `0`, including the original 16MiB initial size and 2.0 growth factor when `SANDBOX_B15_1_STABLE_SLABS=1`.

This deliberately trades **additional independent buffers / reserved GPU memory and possible draw-binding overhead** against eliminating slab growth and the consequent full-resident re-extraction. GPU VRAM and full interactive present-time have not yet been independently qualified.

## Minimal matched Windows Vulkan test

One Rust 1.100.0 release build followed by **two** otherwise identical GPU-headless 1920×1080 arms: `SANDBOX_B15_5_FIXED_SLABS=0` vs `1`. Each ran the same 18m/s survey route, six scripted SDF edits at game seconds 25/28/31/34/37/40, B11 distant visuals on, transactional edit-cohort publication on, synchronized B14+B15.4 per-frame instrumentation, and three screenshots at t12/35/46 seconds. No additional long 120-second tests or external capture campaigns were run. Both arms used fresh world journals.

| Measured result | B15.4 growing slabs control | B15.5 fixed 32MiB candidate |
|---|---:|---:|
| Total relocated live meshes | **5,990** (9 growth events) | **0** (0 events) |
| B14 wall-clock frame-gap max, t20–44s | **313 ms** | **53 ms** |
| B14 wall-clock frame-gap p95, t20–44s | 19 ms | 19 ms |
| B14 frame rows / B15.4 cost rows | 2,718 / 2,718 | 2,793 / 2,793 |
| Scripted edits / published edited meshes | 6 / 22 | 6 / 22 |
| Max edited GPU-ready publication latency | 44.945 ms | **35.698 ms** |
| Logical horizon missing blocks, t20–44s | 0 | 0 |
| Runtime/Vulkan errors | 0 | 0 |
| B14 screenshots | 3 | 3 |

**Interpretation:** the hypothesized allocator-growth mass-relocation mechanism has been eliminated on this deterministic benchmark. The largest observed B14 frame gap was 260ms smaller (**83.1%** reduction); editing and logical coverage were preserved. This is **one matched headless A/B**, not proof that every real-world stall will vanish, and the 19ms B14 gap p95 still exceeds the strict 16.7ms complete-frame budget. The prior 60FPS goal remains **not yet qualified on a physical interactive display**.

A quick visual inspection of the three matched 1080p PNGs from each arm showed the same terrain, rock and water silhouettes, without an obvious static screenshot regression. Three screenshots are not evidence against single-frame cracks or GPU render/presentation issues.

## Decision and minimal remaining gate

- Preserve the experiment under the B15.5 checkpoint branch, without altering stable B13/B15.2/B15.4 or promoting to `main`.
- **No more broad instrumentation or capture campaigns needed** to demonstrate allocator-growth elimination.
- Next action is one **short interactive visual smoke** on the downloaded B15.5 Windows runtime with `SANDBOX_B15_5_FIXED_SLABS=1` and B11/LOD/SDF editing enabled. Manually move and edit terrain, observing any flicker or missing rocks/water; no FFmpeg or PresentMon recording needed.
- If that smoke is clean, decide whether to adopt fixed slabs as the new experimental default and move to the next performance issue (p95 >16.7ms). Document the additional VRAM/buffer-binding overhead as a scalability risk for later profiling, rather than adding another exhaustive test now.
