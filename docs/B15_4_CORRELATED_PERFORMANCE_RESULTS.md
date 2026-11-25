# B15.4 — Correlated performance, B11 far coverage, LOD seams and PresentMon

**Status, 2026-11-25:** Windows/Vulkan instrumented three-arm regression **PASS**, with **full 60 FPS/pixel-present qualification still HOLD**. Branch `exp/b15-4-correlated-present-seams-20261125`. No changes to `main`, B13, B15.2 or previous B15.3 checkpoints.

## Purpose and retrospective evidence

The two user-provided 120-second B15.3 interactive DXGI+NVENC videos and B14 traces showed stable logical 130m horizon and six edits in both scenarios, but full wall-clock frame p95 **24ms B11-on / 26ms B11-off** against a 16.7ms budget. The largest in-video B14 frame intervals were **369ms at game t~33.93 (B11-on)** and **274ms at game t~30.46 (B11-off)**, *before* the immediately following scripted edits at t34.05 and t31.01 respectively.

Around edits #4/#5/#6 (t34/37/40), **B11-on** experienced 8 canceled LOD jobs each and repair bursts of **4/12/4 seam blocks**. In the same three edits **B11-off** had 0 canceled jobs and no repair bursts. B11 shell rebuild events occurred hundreds of milliseconds *after* their corresponding edit/reconciliation events; no immediate timing overlap proves causation. Relocations of **925 meshes (on)** and **906 meshes (off)** were logged some hundreds of milliseconds before the respective largest frame interval. Allocator/GPU pressure is a candidate independent of B11, but **neither the temporal lag nor the repair difference proves causal responsibility**. In both videos no large whole-frame visual blackouts were verified in the sampled/reduced-resolution scan, which cannot rule out local seams.

The source-level retrospective is the attached `B15_4_RETROSPECTIVE_CORRELATION_20261125.json` produced from the original user archives; `scripts/b15-4-correlate.py` reproduces B14/log correlation directly from their ZIPs. The old archives contain no independent PresentMon CSV.

## Experimental instrumentation

1. `crates/gpu_terrain/src/b2/b3.rs` records the completed per-frame `stream_b3` CPU duration, without modifying transition/publication decisions.
2. `crates/gpu_terrain/src/b2/b3/frame_audit.rs` adds opt-in, flush-every-frame `trace/b15-4-costs.csv` when `SANDBOX_B15_4_CORRELATE=1`: same timestamp as B14, CPU streaming and B14 audit costs, accumulated cancel/repair/edit counters, pending/target/commit counts, logical coverage. Original B14 CSV schema is unchanged. **The same frame-rate and instrumentation cost is applied to each A/B/C arm.**
3. `crates/game/src/visual_far.rs` annotates B11 shell build duration in microseconds and MainWorld shell-swap events with timestamps. No actual GPU present fence or pixel change is implied by those markers.
4. `crates/gpu_terrain/src/b2.rs` annotates RenderWorld relocation pre-processing CPU time on its existing relocation warning. It is **not** GPU execution/presentation latency.
5. The local B15.3 DXGI/NVENC script optionally owns a process-filtered **Intel PresentMon ETW collector** using `--process_id`, `--date_time`, unique session name, and process-exit cleanup. It records `presentmon.csv` in the same session and Windows UTC offset for timestamp matching. `scripts/b15-3-local-dxgi-matrix.ps1` runs both 120-second Auto routes with identical instrumentation and calls `scripts/b15-4-correlate.py` automatically.
6. The Python correlator strips Rust ANSI SGR, groups events near edits and worst frame gaps, and — *when actually available* — combines PresentMon `CPUStartDateTime`, `MsBetweenPresents`, `MsBetweenDisplayChange`, `MsGPUTime` and related columns. A missing/unparseable PresentMon stream is explicitly `CORRELATED_B14_ONLY_PRESENT_UNMEASURED`, **never** classified as presentation-qualified.

Official PresentMon CLI and CSV contract: https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md

## CI result — headless Windows Vulkan, not external monitor present

Windows run: https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45608678321 . Rust 1.100.0 release compiled, streaming/world unit tests passed, Windows PowerShell 5.1 parser/contracts passed, B15.2 headless matrix passed, and all three arms had exactly the same B14 and B15.4 frame counts with monotonic LOD/repair counters.

| Metric (headless CI) | B15.1 control / B11 on | B15.2 atomic / B11 on | B15.2 atomic / B11 off |
|---|---:|---:|---:|
| B14 frames and B15.4 cost rows | 4291 | 4300 | 4290 |
| Streaming CPU p95 | 1.534ms | 1.455ms | 1.524ms |
| Streaming CPU maximum | 6.714ms | 6.713ms | 20.851ms |
| B14 logical-audit CPU p95 | 0.376ms | 0.343ms | 0.341ms |
| B11 shell rebuild max CPU (observed events) | 2.868ms | 2.990ms | n/a (off) |
| Scripted edits and edited mesh publications | 6 / 22 | 6 / 22 | 6 / 22 |
| Maximum edited-mesh GPU-ready publication | 43.613ms | 62.876ms | 36.326ms |
| Canceled LOD jobs | n/a (control) | 6 | 0 |
| Additional post-edit repair blocks | n/a (control) | 6 | 0 |
| Logical holes after warmup / invalid LOD frames | 0 / 0 | 0 / 0 | 0 / 0 |

**Interpretation:** On this headless campaign the instrumented `stream_b3` and B11 shell CPU durations are generally much smaller than the >16.7ms local game-frame target, but headless timing must not be substituted for interactive monitor-present measurements. CPU costs and B14 observation costs are similar across all three arms; no demonstrated pixel-flicker fix or full-frame speedup was promoted.

## Next gate requiring user Windows interactive desktop

Use **new instrumented runtime**, not the old B15.2 release, alongside the new capture/matrix/correlator scripts. Keep FFmpeg **7.1.1** (NVENC API compatible with the user's installed NVIDIA driver) and an existing standalone console `PresentMon.exe` (the earlier A7 ETW collector path may be reusable if it still exists). First capture one 15-second live session to ensure PresentMon's CSV and synchronized `b15-4-costs.csv` appear, then run the fixed 120s×2 `-Mode Auto` comparison with `-PresentMonPath` on both arms. Save the paired ZIPs, matrix JSON and B15.4 correlation JSON.

Full qualification still requires measured present intervals, visible pixel validation across critical edit windows and the strict full-frame 16.7ms target. **No further algorithmic terrain changes are justified before external GPU/present evidence distinguishes allocator relocations, shell regeneration and LOD edit-cohort scheduling.**
