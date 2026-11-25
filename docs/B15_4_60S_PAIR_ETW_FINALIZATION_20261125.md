# B15.4 — 60-second local DXGI matched pair and PresentMon finalization correction

**Date:** 2026-11-25. **Status:** `B15_4_B14_PAIR_HOLD_PRESENTMON_CSV_MISSING`.

## Evidence

User-submitted `b15-2-Auto-shell1-atomic1-20261125-131115.zip`, `b15-2-Auto-shell0-atomic1-20261125-131313.zip`, `b15-3-dxgi-matrix-20261125-131114.json` and `b15-4-correlation-20261125-131114.json`.

| 60-second recording | B11 on | B11 off |
|---|---:|---:|
| Encoded DXGI/NVENC FPS | 58.18 | 58.20 |
| B14 frame rows and B15.4 cost rows | 5,877 | 5,877 |
| B14 in-video wall-clock frame gap p95 | 22ms | 23ms |
| Largest B14 gap during video | **361ms** at game t29.39s | **678ms** at game t30.37s |
| B15.4 streaming CPU in worst-gap frame | 0.937ms | 0.898ms |
| B14 visibility audit CPU in worst-gap frame | 0.257ms | 0.248ms |
| B15.4 streaming CPU p95 during video | ~1.643ms | ~1.645ms |
| Scripted SDF edits and atomic transactions | 6 / 6 | 6 / 6 |
| Edited-mesh ready publications | 22 | 22 |
| Max edited-mesh ready latency | 46.55ms | 43.21ms |
| Post-edit seam-repair blocks | 1 | 16 |
| Cancelled LOD jobs | 1 | 4 |
| GPU relocations (sum logged) | 6,022 | 5,977 |
| Logical terrain holes after warmup / invalid LOD | 0 / 0 | 0 / 0 |
| PresentMon CSV in ZIP | **missing** | **missing** |

Both `presentmon.stderr.log` and `presentmon.stdout.log` contain only a UTF-16LE BOM, **no access-denied message**. Unlike the earlier non-elevated 120-second attempt, ETW permission failure is **not established** in this pair.

The independent PresentMon 15-second Live validation **did produce 1,717 timestamped rows** under an elevated desktop session. These long videos each began around game t23s and ended around t83s, before the full game's reported t~100s at termination.

## Likely capture lifecycle defect

The old capture script launched PresentMon with:
```text
--timed (DurationSeconds + 90) --terminate_on_proc_exit
```
but after force-stopping the Vulkan game it waited only **8 seconds**, then force-stopped PresentMon, even if its ETW processing/output stream had not finalized. For a 60-second Auto recording the timer was 150 seconds while the game process ran approximately 100 seconds in total. The two empty-stream/no-CSV results are consistent with forcibly interrupting the collector or incomplete session finalization. This is a **plausible mechanism, not independently proven to be the sole cause**.

## Intervention

The updated `scripts/b15-2-local-60fps.ps1`:

1. Builds the process-scoped collector command with both `--terminate_on_proc_exit` and **`--terminate_after_timed`**, ensuring a natural completion path even if the game-exit condition fails to finalize promptly.
2. Sets the timed ETW limit to `record_seconds+40` in Auto (60s Auto → 100s ETW) and `record_seconds+20` in Live (15s Live → 35s ETW); both include the startup/warmup and FFmpeg preflight overhead. Timed exit should occur after the video is captured.
3. Computes a bounded grace period from the collector's remaining deadline, rather than killing it after 8s; reports timer, remaining time, CSV bytes and timeout status.
4. Verifies that the emitted CSV is nonempty and includes the actual timestamp and `MsBetweenPresents` metrics.
5. Saves the full ZIP **before failing** if no valid collector file was obtained, thereby aborting the paired matrix before running the second 60s arm.

PowerShell 5.1 syntax, the new timer/CLI flags contract, DXGI containment regression, access-denied diagnostic, and the paired matrix contract passed in [GitHub Actions run 45622657234](https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45622657234). This is a **Windows contract test**, not an independent verification of PresentMon CSV creation in a physical interactive session. The timestamp normalization correlator's separate Python CI had already passed in [run 45619319144](https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45619319144).

## Next minimal local gate

Run **one** 60-second Auto shell-on capture, not the entire A/B pair, with the updated capture script, existing instrumented runtime, FFmpeg 7.1.1 and elevated PresentMon. Validate `B15_4_PRESENTMON_FINALIZED_PASS`, `presentmon.csv` with nonzero rows, and corresponding B14 and B15.4 frame traces. Only after this succeeds, use the usual paired command to confirm reproducibility with B11 off; if a first arm fails, preserve the ZIP and stop. Do not claim 60FPS/pixel correctness while present data is unmeasured.
