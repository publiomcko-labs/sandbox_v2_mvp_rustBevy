# B15.4 — Interactive 120s DXGI/PRESENTMON A/B: ETW access failure and performance HOLD

**Date:** 2026-11-25. **Status:** `B15_4_LOCAL_ETW_ACCESS_DENIED_FULL_FRAME_HOLD`.

## Submitted evidence

- `b15-2-Auto-shell1-atomic1-20261125-123338.zip` — B11 on.
- `b15-2-Auto-shell0-atomic1-20261125-123640.zip` — B11 off.
- `b15-3-dxgi-matrix-20261125-123337.json`.
- `b15-4-correlation-20261125-123337.json`.

All original ZIPs contain `presentmon.stderr.log` (UTF-16LE) with the same definitive text:

```
error: failed to start trace session: access denied.
PresentMon requires either administrative privileges or to be run by a user in the
"Performance Log Users" user group.
```

No `presentmon.csv` is present in either ZIP. Thus **external present/display/GPU frame metrics were not measured**. The original capture script did not check whether PresentMon exited immediately and continued both 120-second video runs, returning only `presentmon_bytes=0` in the report.

## Re-audit of the raw traces

| Metric | B11 on | B11 off |
|---|---:|---:|
| DXGI/NVENC encoded FPS | 57.82 | 58.13 |
| B14 rows == B15.4 cost rows | 9,998 | 9,973 |
| In-video B14 wall-clock gap p95 | 24ms | 25ms |
| All B14 frame gap p95 | 24ms | 26ms |
| Worst in-video B14 gap | 306ms at game t34.6333 | 254ms at game t35.7487 |
| B15.4 streaming CPU p95 during video | **1.573ms** | **1.570ms** |
| B14 visibility-audit CPU p95 during video | 0.332ms | 0.322ms |
| Streaming CPU during worst gap | 0.945ms | 1.064ms |
| B14 audit CPU during worst gap | 0.261ms | 0.248ms |
| Nearest prior GPU allocator relocation batch | 910 meshes, 290ms earlier | 907 meshes, 241ms earlier |
| CPU prepare time at that relocation event | 3.695ms | 4.075ms |
| Scripted edits and edited mesh publication events | 6 / 22 | 6 / 22 |
| Max edited publication latency | 44.78ms | 39.27ms |
| Post-edit seam repair blocks | 6 | 16 |
| Canceled LOD work | 6 | 16 |
| B11 shell rebuilds | 43 | 0 |
| Missing logical horizon after warmup | 0 | 0 |
| PresentMon CSV | absent | absent |

**Interpretation:** Neither B15.4 streaming CPU nor B14 audit cost alone accounts for the >250ms wall-clock frame gaps; both worst gaps are temporally preceded by a batch allocator relocation on both B11 arms. The relative delay does not establish causal dependence. Retries with B11-off now show *more* seam repairs/cancelled jobs than B11-on, contradicting the idea that B11 alone is the root cause. No guarantee exists that every encoded DXGI frame is a distinct Vulkan presented frame. Sampling video still frames reveals no obvious broad terrain outages, but local sub-frame fissures cannot be excluded.

## Corrective action implemented

`scripts/b15-2-local-60fps.ps1` now checks three seconds after launching its *owned* process-scoped PresentMon ETW collector, before video preflight / 120s measurement. If the process has already exited, it reads the UTF-16 error stream using .NET automatic BOM decoding and throws a classified `B15_4_PRESENTMON_ACCESS_DENIED` message, preserving `presentmon.stderr.log`. The `-ContractTest` Windows gate includes both access-denied and unknown-error fixtures.

Run the user's **interactive PowerShell as Administrator** and verify the collector can remain running, then repeat one 15-second Live capture. Membership in **Performance Log Users**, with a fresh Windows logon after membership changes, is an alternative; it is not automatically granted by changing the script. A full 120s A/B should only be repeated after `presentmon.csv` has produced actual timestamp/present interval rows.

**Next gate:** PresentMon `CPUStartDateTime`, `MsBetweenPresents`, `MsBetweenDisplayChange` and `MsGPUTime` must be synchronized with B14. No algorithmic terrain changes or promotion to `main` before present-level evidence qualifies them.
