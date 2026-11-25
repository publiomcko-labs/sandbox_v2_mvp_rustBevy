# B15.7 — isolate artificial headless frame pacing; keep the game unchanged

**Date:** 2026-11-25
**Status:** `B15_7_UNCAPPED_HEADLESS_E2E_PASS` / **60 FPS full-frame strict budget: NOT QUALIFIED**
**Evidence:** https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45681928735
**Artifact:** `b15-7-uncapped-headless-e2e-evidence`, ID `15055420944`.
**Exact binary:** the B15.6 Windows Release binary from passing run `45629673662`; **no engine or gameplay source code was changed in this step.**

## Why the headless p95 previously plateaued at 19ms

In `crates/game/src/main.rs`, headless applications use `ScheduleRunnerPlugin::run_loop(Duration::from_millis(16))` by default instead of a real Winit desktop event loop and physical swapchain. The synthetic 16ms scheduler wait imposes a frame pacing floor on the headless benchmark. This wait is **not a measurement of actual Vulkan present latency**.

The **pre-existing** environment flag `SANDBOX_B3_BENCH_UNCAPPED=1` makes the same binary use `Duration::ZERO`, without changing any terrain, GPU buffers, shader, editing logic, physics or culling. This is a diagnostic route, not an alternate gameplay policy.

Only **one** additional 46-second GPU-headless Vulkan 1080p execution was needed. It reused the exact B15.6 binary with both `SANDBOX_B15_5_FIXED_SLABS=1` and `SANDBOX_B15_6_CONSERVATIVE_CULLING=1`, the same survey movement, B11 far shell, B15.2 atomic edit cohorts, six scripted edits at game seconds 25/28/31/34/37/40, B14+B15.4 CPU audit and three screenshots at t12/35/46s.

| Measurement, t20–44s | B15.6 with 16ms headless loop | B15.7 same binary with zero scheduler sleep |
|---|---:|---:|
| MainWorld B14 gap p50 | **16 ms** | **7 ms** |
| MainWorld B14 gap p95 | **19 ms** | **19 ms** |
| MainWorld B14 gap p99 | **22 ms** | **27 ms** |
| Largest MainWorld B14 gap | **54 ms** | **51 ms** |
| Streaming CPU p95 | ~1.728 ms | **1.708 ms** |
| B14 visibility audit CPU p95 | ~0.321 ms | **0.418 ms** |
| Approx. B14 frame count in whole 46s | 2,796 | **6,223** |
| Frustum-selected terrain meshes, mean | 205.6 | 205.7 |
| Six scripted edits / 22 ready publications | 6 / 22 | **6 / 22** |
| Highest edit GPU-ready publication latency | 38.144 ms | **42.991 ms** |
| Allocator relocation events / missing required frames / LOD invalid | 0 / 0 / 0 | **0 / 0 / 0** |
| Runtime errors | 0 | 0 |

From the raw `b14-frames.csv` in the **uncapped** t20–44s window: **2,749** interval samples; **217 (7.9%)** were >=17ms, **47 (1.7%)** were >=25ms, and only **7 (0.25%)** exceeded 33ms.

The worst 51ms gap occurred at game t35.039s. That frame recorded only **0.166ms** of streaming CPU and **0.446ms** of B14 audit CPU, so neither recorded stage alone accounts for the stall. Some other outliers coincide with LOD mesh swaps, but several do not. The available MainWorld trace cannot assign the remaining gap to a specific GPU operation, OS scheduler or renderer stage.

## Engineering decision — avoid speculative optimization

1. **The 16ms headless sleep materially constrained median throughput**. The drop from 16ms to 7ms is a diagnostic result, **not** a speedup of the production game; the binary and shader code are identical.
2. **The 19ms p95 cannot be explained solely by the sleep.** It persists uncapped while the recorded streaming and audit CPU stages remain relatively inexpensive. A different renderer/OS/GPU stage may contribute, but current data is insufficient to attribute it.
3. **Do not optimize B3 streaming, B15.5 fixed slabs, or B15.6 terrain culling solely to lower the headless B14 p95**; the 7ms median already confirms meaningful CPU-loop headroom. Any further performance intervention should be based on a reproducible interactive user-visible defect or an accurate independent present-time measurement, not on repeated full headless matrix runs.
4. **Preserve the last user-visually-approved reference** `checkpoint/b15-5-visual-approved-20261125`. B15.6 culling remains an E2E-verified, opt-in experiment with strong render-eligibility savings and no observed E2E regression; it was **not independently approved visually in an interactive local test**.
5. The original MVP requirements remain in force: 130m coverage, 18m/s movement, seamless mixed LOD, edits <=100ms publication metric, rocks/water physics, target 60FPS / 16.7ms full presented frame. The strict presented-frame requirement is **not yet independently qualified**. The headless MainWorld wall-clock metric is not a substitute.
6. **Close B15.7 now. No more repeated ETW/video/benchmark campaigns are required for this discrete question.** The next meaningful game step is an independently justified performance intervention or end-user interactive validation of B15.6, rather than instrumenting the same timing problem again.

Note: the B15.7 test workflow changes diagnostic scripts and GitHub Actions configuration only, not `crates/**`, `assets/shaders/**` or `main`.
