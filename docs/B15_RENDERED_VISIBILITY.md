# B15 — Rendered visibility: temporal raster / GPU publication triage

**Scope:** diagnostic only. The original B13 functional checkpoint and `main` are unchanged. B14 logical visibility alone cannot demonstrate that pixels were rendered.

## Evidence channels and limits

1. B14 unchanged: `b14-frames.csv` + `b14-mesh-events.csv`; after `Last`, records MainWorld logical publication, `ViewVisibility`, LOD swaps and counts. **Not a GPU fence or raster result**.
2. B15 headless sampled raster: optional `SANDBOX_B15_RASTER_DIR` enables PNG snapshots from Bevy's real render camera using asynchronous `Screenshot::image` (or primary window). `b15-raster.csv` records request game time/UTC, camera position, PNG completion time and byte size. It uses one in-flight screenshot to avoid uncontrolled GPU readback concurrency; captures are **not uniformly timed 60fps**. The request timestamp precedes the rendered readback by at least a rendering cycle.
3. B15 60 FPS desktop video: `scripts/b15-local-60fps.ps1` records an interactive Vulkan window via FFmpeg at 60fps alongside the B14 frame CSV. Desktop capture must run in **interactive Windows session**, never a Session 0 runner. Video timing uses a conservative **±1 s** launch-to-first-frame uncertainty; frame-exact causal claims require a later tighter synchronization implementation.
4. Optional `scripts/b15-correlate-video.py` decodes every video frame, flags *isolated reversible* pixel anomalies using a low-res temporal difference and correlates approximately with logical coverage/swap events. It deliberately does not interpret a scored transient as verified terrain flicker. Long-lived gaps and thin cracks may go undetected.

## CI test

- `B15 raster evidence Windows Vulkan diagnostic` on the isolated B15 branch.
- Uses the same 72s B14 Session 0 headless Vulkan trace and screenshot checks at 12, 40 and 72 seconds.
- Separately requests actual framebuffer PNG captures at 4 Hz over 48–56 s, with one image in flight.
- Checks at least eight completed PNGs, positive byte lengths, monotonic request times, matching B14 time interval and preserves both evidence directories.
- CI **PASS** means capture plumbing works, **not** that every displayed frame is correct.

## Local interactive collection

1. From the completed B15 workflow, download `b15-windows-release` and extract the contents into `C:\Dev\sandbox-b15-visual\app` so that `sandbox-game.exe` and `assets\shaders` exist.
2. Obtain `scripts/b15-local-60fps.ps1` and run in a normal PowerShell desktop session, with FFmpeg installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Dev\sandbox-b15-visual\b15-local-60fps.ps1" -AppDir "C:\Dev\sandbox-b15-visual\app" -OutputRoot "C:\Dev\sandbox-b15-visual\captures" -Mode Live -DurationSeconds 120 -Fps 60
```

`Live` supports mouse turns, movement, edits and return paths; `Auto` selects the straight 18m/s route. Keep the window visible and desktop unobstructed. The script produces a self-contained ZIP with video, B14 CSV, game/FFmpeg logs and a UTC anchor.

3. Optionally run after extracting the session ZIP:

```powershell
python "C:\Dev\sandbox-b15-visual\b15-correlate-video.py" "C:\Dev\sandbox-b15-visual\captures\b15-Live-SESSION"
```

Review the detected intervals and adjacent video frames manually. Send the ZIP; do not send only the JSON.

## Decision policy

- If visually observed cuts align with `missing>0`, investigate late block generation or eviction.
- If cuts occur while required logical blocks remain present, investigate GPU generated vertex/index validity, mesh extraction/draw submission, depth and geometry topology, LOD swap ordering, and far-shell interference. Which is the cause is **not resolved by absence of logical gaps**.
- Validate every narrow fix against **B13** with matched test conditions and instrumentation, followed by a free-flight 60 FPS visual run.
- No LOD/rendering optimization or main promotion until a specific visual defect is reproduced and a correction demonstrates no regression.

**Acceptance:** B15 tooling complete after compilation and actual Vulkan capture validation. **Flicker defect remains OPEN until on-screen evidence and a correction demonstrate closure**.
