# B15.3 — DXGI-to-NVENC capture and paired local B11 isolation

**Status (2026-11-25):** Implementation and Windows PowerShell static/argument validation complete; **real interactive DXGI pixel capture not yet qualified**. No GPU terrain code or reference checkpoint was changed. The original B15.2 three-arm CI result remains the non-pixel reference.

## Why

Two live 1920x1080/15s captures using FFmpeg `gdigrab` produced only **29.43 FPS (libx264)** and **29.47 FPS (NVENC)**, despite a 60 FPS request. The game B14 frame timeline suggested approximately 60 FPS average in the second run but p95 frame interval exceeded 16.7ms. Thus the GDI grab stage, or the desktop compositor/transfer path, is the candidate bottleneck; GDI capture alone cannot validate one-frame geometry flicker.

FFmpeg 8.1.2's `h264_nvenc` required NVENC API 13.1 but the user's installed NVIDIA driver exposed 13.0. Their **FFmpeg 7.1.1 full_build** passed the NVENC startup test and successfully encoded the second local GDI capture. **Do not assume that the FFmpeg 8.1.2 build is usable for NVENC on this PC.**

## Intervention

- `scripts/b15-2-local-60fps.ps1`: `-CaptureBackend Dxgi` (default) uses the FFmpeg 7.1 `ddagrab` lavfi source and Direct3D11 hardware frames fed **directly into `h264_nvenc`**. No `gdigrab`, CPU download or forced software `-pix_fmt` occurs on this path.
- `-CaptureBackend Gdi` retains the working previous path as a diagnostic control with `-Encoder Nvenc` or `-Encoder Cpu`. DXGI+CPU is intentionally rejected, avoiding an unintended GPU-to-CPU transfer.
- Desktop client-area discovery waits for a nonzero Bevy window rectangle and uses `MonitorFromWindow/GetMonitorInfo` to translate absolute Windows desktop coordinates into DXGI per-monitor offsets. The selected DXGI output is `-DxgiOutputIdx 0` by default; multiple monitors may require explicit correction and full physical window containment.
- Eight-second low-rate preflight validates encoding exit code, file length, and changed pixels. It reports diagnostic FFmpeg logs. Final capture reports encoded frame count and real encoded FPS, records FFmpeg version/encoder/backend and B14 traces, and archives the session. The requested 60 FPS is **not** treated as observed 60 FPS.
- `-Mode Auto` enables the existing 18m/s survey path and six alternating SDF edits at game t=25,28,31,34,37,40 seconds, with one 12-second stationary warmup. `-Mode Live` leaves player control manual.
- `scripts/b15-3-local-dxgi-matrix.ps1`: invokes two independent 120-second Auto runs using identical game binary, capture method, encoder, 60-FPS request, B14 instrumentation and edited terrain. Only `SANDBOX_B15_2_FAR_FIELD` changes (1 then 0). Creates independent saves and per-arm ZIPs; emits `b15-3-dxgi-matrix-*.json` with completeness, edits, logical visibility after 20s, p95 game-frame budget, edit latency, seam repairs and B11 toggle. No blanket success if the strict p95 16.7ms goal fails.

**Limits:** DXGI Desktop Duplication records desktop-composited pixels, not an independent Vulkan present fence. On the user's PC, the first local 15s test must verify that `ddagrab` can open the correct monitor, that its frames are not frozen/black and that at least 50 encoded FPS are obtained. Passing encoded FPS alone does not prove full-frame <16.7ms or absence of one-frame flicker. Static CI is run in a Windows runner service and must not attempt an interactive screen capture from Session 0.

## Interactive Windows validation commands

Do not reinstall the game. Use existing `C:\Dev\sandbox-b15-2-local\app\sandbox-game.exe` from successful B15.2 Windows/Vulkan build.

```powershell
$root = "C:\Dev\sandbox-b15-2-local"
$repo = "publiomcko-labs/sandbox_v2_mvp_rustBevy"
$ref = "exp/b15-3-dxgi-capture-20261125"
foreach ($name in @("b15-2-local-60fps.ps1","b15-3-local-dxgi-matrix.ps1")) {
    $encoded = gh api "repos/$repo/contents/scripts/${name}?ref=$ref" --jq ".content"
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $name" }
    [IO.File]::WriteAllBytes(
        (Join-Path $root $name),
        [Convert]::FromBase64String((($encoded -join "") -replace "\s",""))
    )
}
$bin = "$root\tools\ffmpeg-7.1.1-full_build\bin"
if (-not (Test-Path "$bin\ffmpeg.exe")) { throw "FFmpeg 7.1.1 not found" }
$env:PATH = "$bin;$env:PATH"
& "$bin\ffmpeg.exe" -version | Select-Object -First 1
```

First prove a 15-second real DXGI video in the **interactive physical Windows desktop**, with camera motion during the preflight:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File "C:\Dev\sandbox-b15-2-local\b15-2-local-60fps.ps1" `
    -AppDir "C:\Dev\sandbox-b15-2-local\app" `
    -OutputRoot "C:\Dev\sandbox-b15-2-local\captures" `
    -Mode Live -DurationSeconds 15 -Fps 60 `
    -FarShell 1 -AtomicEdits 1 `
    -CaptureBackend Dxgi -Encoder Nvenc -DxgiOutputIdx 0
```

If there is real motion and encoded FPS >=50 (ideally >=60), run the **matched 120s×2** sequence without touching mouse or keyboard or obscuring the window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File "C:\Dev\sandbox-b15-2-local\b15-3-local-dxgi-matrix.ps1" `
    -AppDir "C:\Dev\sandbox-b15-2-local\app" `
    -OutputRoot "C:\Dev\sandbox-b15-2-local\captures" `
    -DurationSeconds 120 -Fps 60 -DxgiOutputIdx 0
```

Upload the two latest `b15-2-Auto-*.zip` and `b15-3-dxgi-matrix-*.json`. If DXGI fails, preserve its `preflight-ffmpeg.log`; retry a short `-CaptureBackend Gdi -Encoder Nvenc` control rather than claiming the engine regressed. Do not promote B15.3 to main, B13 or B15.2 checkpoint before local pixel qualification.
