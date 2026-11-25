# B15.4 — PresentMon 15s short validation and corrected ETW/B14 alignment

**Date:** 2026-11-25. **Result:** `B15_4_SHORT_PRESENTMON_VALID_FULL_FRAME_HOLD`. No `main` or engine-performance change is warranted yet.

Source: user-submitted `b15-2-Live-shell1-atomic1-20261125-125628.zip`, captured interactively using DXGI desktop duplication, FFmpeg 7.1.1 NVENC, 1920×1080, `SANDBOX_B15_4_CORRELATE=1`, and administrator-permitted PresentMon ETW.

## Confirmed

- PresentMon CSV: **1,717** events, including **870** in the 15-second video window. No ETW-access error, and game output remains correct in the inspected video sample.
- B14 frame CSV / synchronized B15.4 CPU-cost CSV: **1,723 / 1,723** rows. 0 logical missing blocks during video.
- DXGI 15-second video: **57.67 encoded FPS**, requested 60; dynamic preflight has real pixel variation. Encoded frame count does not establish distinct presented frames.
- PresentMon `PresentMode`: `Composed: Flip`, sampled physical display cadence near 60Hz.

| External PresentMon event timing (in-video) | p95 | maximum |
|---|---:|---:|
| `MsBetweenPresents` — application present API cadence | **17.04 ms** | **199.08 ms** |
| `MsBetweenDisplayChange` — displayed-image change interval | **16.75 ms** | **183.45 ms** |
| `MsGPUTime` — GPU frame-time metric | **16.31 ms** | **79.77 ms** |
| `MsGPUBusy` — GPU actively occupied | **9.16 ms** | **58.70 ms** |
| `MsCPUBusy` — CPU busy between frame starts | **16.66 ms** | **198.79 ms** |

The worst PresentMon gap happened near game t=14.84s. The B14 trace also records a **238ms** wall-clock interval near game t=15.07s. The B14 streaming CPU work was **~1.17ms** during its delayed frame; therefore its own measured CPU stage alone does not account for that large gap. The ETW spike included both `MsCPUBusy` ~198.79ms and `MsGPUBusy` ~58.70ms. This is a focused signal to correlate against allocator and render-thread activity, not a proof of one root cause.

## Critical parser correction

The actual Windows PresentMon v2 CSV writes some dates with an unpadded hour (`2026-11-25 6:56:29.764096900`). Python `datetime.fromisoformat` rejected this input, silently making ETW look absent. Even after padding the hour, applying the Windows timezone metadata (`-03:00`) to the raw PresentMon date would leave a **3-hour offset** versus B14's UTC-millisecond trace.

The corrected `scripts/b15-4-correlate.py`:

1. Pads one-digit hours and truncates nanosecond fractions safely.
2. Computes the best **integer-hour correction** by matching the beginning and end of PresentMon events against the original B14 timeline, rejecting >15s endpoint errors.
3. Records applied hour correction and remaining endpoint error.
4. Filters the actual video window only after successful alignment, preventing false `CORRELATED_B14_ONLY_PRESENT_UNMEASURED` results.

For this short capture, the required correction was **+3 hours** after the stored Windows timezone offset, with first/last boundary residuals **+348ms/-58ms**. This is an empirical calibration, not a claim that all PresentMon builds share that behavior.

## Next targeted gate

The next run should use the **updated correlator** alongside the already validated DXGI/PresentMon capture scripts. Because the scripted six edits occur at game t25–40s and video starts around game t20s, a paired **60 seconds per arm** run is sufficient to cover every edit and the critical frame/allocator events, reducing redundant collection relative to another 120s×2 campaign. Both arms must use identical instrumentation, FFmpeg/DXGI/NVENC and an elevated interactive desktop.

After the pair, compare PresentMon CPU present intervals, display intervals, GPU active/busy times and the B15.4 CPU cost trace near allocator mass relocations and the six scripted edits. Treat the 16.7ms budget as **HOLD** while observed spikes remain. Do not interpret a PresentMon trace as direct proof of absence of small geometry cracks.
