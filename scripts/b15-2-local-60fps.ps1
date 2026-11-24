# B15.2 interactive regional desktop capture of Vulkan client area.
# Requires an interactive Windows desktop and FFmpeg+ffprobe. Never use Session 0.
param(
    [string]$AppDir = 'C:\Dev\sandbox-b15-2-local\app',
    [string]$OutputRoot = 'C:\Dev\sandbox-b15-2-local\captures',
    [ValidateSet('Live','Auto')][string]$Mode = 'Live',
    [ValidateRange(15,300)][int]$DurationSeconds = 120,
    [ValidateRange(24,60)][int]$Fps = 60,
    [ValidateSet('0','1')][string]$FarShell = '1',
    [ValidateSet('0','1')][string]$AtomicEdits = '1'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$exe = Join-Path $AppDir 'sandbox-game.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing $exe" }
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'assets\shaders'))) {
    throw 'Missing shader assets in runtime folder'
}
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction Stop
$ffprobe = Get-Command ffprobe.exe -ErrorAction Stop
if (-not ([System.Management.Automation.PSTypeName]'B15_2DesktopRect').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct B15_2_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct B15_2_POINT { public int X, Y; }
public static class B15_2DesktopRect {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out B15_2_RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref B15_2_POINT point);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
}
try { [void][B15_2DesktopRect]::SetProcessDPIAware() } catch {}
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
$session = Join-Path $OutputRoot "b15-2-$Mode-shell$FarShell-atomic$AtomicEdits-$stamp"
$trace = Join-Path $session 'trace'
New-Item -ItemType Directory -Force -Path $session,$trace | Out-Null
$video = Join-Path $session 'game-window-60fps.mp4'
$preflight = Join-Path $session 'preflight-motion.mp4'
$env:SANDBOX_STAGE = 'B11'
$env:SANDBOX_B3_MIXED_LOD = '1'
$env:SANDBOX_B11_FAR_FIELD = '1'
$env:SANDBOX_B15_2_FAR_FIELD = $FarShell
$env:SANDBOX_B15_2_EDIT_ATOMIC = $AtomicEdits
$env:SANDBOX_B15_1_STABLE_SLABS = '1'
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '0'
$env:SANDBOX_B9_CREATIVE = '1'
$env:SANDBOX_B14_TRACE_DIR = $trace
$env:SANDBOX_B4_SAVE_PATH = Join-Path $session 'world-b4.edits'
$env:SANDBOX_B5_SAVE_PATH = Join-Path $session 'world-b5-rocks.txt'
$env:SANDBOX_B2_HEADLESS = '0'
$env:SANDBOX_B3_HEADLESS = '0'
$env:WGPU_BACKEND = 'vulkan'
$env:RUST_LOG = 'info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
Remove-Item Env:SANDBOX_B2_CAPTURE_PATH -ErrorAction SilentlyContinue
Remove-Item Env:SANDBOX_B15_RASTER_DIR -ErrorAction SilentlyContinue
if ($Mode -eq 'Auto') {
    $env:SANDBOX_B15_1_ROUTE = 'survey'
    Remove-Item Env:SANDBOX_B3_ROUTE -ErrorAction SilentlyContinue
} else {
    Remove-Item Env:SANDBOX_B15_1_ROUTE -ErrorAction SilentlyContinue
    Remove-Item Env:SANDBOX_B3_ROUTE -ErrorAction SilentlyContinue
}
$game = $null
$capture = $null
try {
    $gameLaunch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $game = Start-Process -FilePath $exe -WorkingDirectory $AppDir -PassThru `
        -RedirectStandardOutput (Join-Path $session 'game.stdout.log') `
        -RedirectStandardError (Join-Path $session 'game.stderr.log')
    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $game.Refresh()
        if ($game.HasExited) { throw "Game exited early ($($game.ExitCode))" }
        $handle = $game.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) { break }
    }
    if ($handle -eq [IntPtr]::Zero) {
        throw 'Game window handle unavailable: interactive Windows desktop is required'
    }
    $rect = New-Object B15_2_RECT
    $point = New-Object B15_2_POINT
    if (-not [B15_2DesktopRect]::GetClientRect($handle, [ref]$rect) -or
        -not [B15_2DesktopRect]::ClientToScreen($handle, [ref]$point)) {
        throw 'Failed to get Vulkan window client rectangle'
    }
    $x = [int]$point.X
    $y = [int]$point.Y
    $w = [int]([math]::Floor(($rect.Right - $rect.Left) / 2.0) * 2)
    $h = [int]([math]::Floor(($rect.Bottom - $rect.Top) / 2.0) * 2)
    if ($w -lt 640 -or $h -lt 360 -or $w -gt 4096 -or $h -gt 2160) {
        throw "Unexpected window size: ${w}x${h}. Use a regular 1920x1080 window."
    }
    Write-Host "B15_2_WINDOW_REGION x=$x y=$y size=${w}x${h}"
    if ($Mode -eq 'Auto') {
        # The survey route holds the camera still for its first 12 game seconds.
        # Wait until the scripted motion has begun before testing video dynamics.
        Write-Host 'B15.2 AUTO: waiting for survey warmup to end before motion preflight.'
        Start-Sleep -Seconds 12
    }
    Write-Host 'PREFLIGHT: MOVE THE CAMERA OR WALK DURING THE NEXT 8 SECONDS.'
    $preArgs = '-y -hide_banner -loglevel error -f gdigrab -framerate 15 -draw_mouse 0 -offset_x {0} -offset_y {1} -video_size {2}x{3} -i desktop -t 8 -c:v libx264 -preset ultrafast -crf 26 -pix_fmt yuv420p "{4}"' -f $x,$y,$w,$h,$preflight
    $probeLog = Join-Path $session 'preflight-ffmpeg.log'
    $p = Start-Process -FilePath $ffmpeg.Source -ArgumentList $preArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardError $probeLog
    Wait-Process -Id $p.Id -Timeout 40 -ErrorAction Stop
    $p.Refresh()
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $preflight)) {
        throw "Preflight regional Vulkan capture failed; inspect $probeLog"
    }
    $first = Join-Path $session 'preflight-first.gray'
    $last = Join-Path $session 'preflight-last.gray'
    & $ffmpeg.Source -nostdin -v error -ss 1 -i "$preflight" -frames:v 1 `
        -vf 'scale=64:36,format=gray' -f rawvideo -y "$first"
    if ($LASTEXITCODE -ne 0) { throw 'Preflight first frame extraction failed' }
    & $ffmpeg.Source -nostdin -v error -ss 6 -i "$preflight" -frames:v 1 `
        -vf 'scale=64:36,format=gray' -f rawvideo -y "$last"
    if ($LASTEXITCODE -ne 0) { throw 'Preflight last frame extraction failed' }
    $a = [System.IO.File]::ReadAllBytes($first)
    $b = [System.IO.File]::ReadAllBytes($last)
    if ($a.Length -ne 2304 -or $b.Length -ne 2304) {
        throw "Preflight gray frame size invalid: $($a.Length), $($b.Length)"
    }
    $delta = 0.0
    for ($i = 0; $i -lt 2304; $i++) {
        $delta += [math]::Abs([int]$a[$i] - [int]$b[$i])
    }
    $delta /= 2304.0
    if ($delta -lt 2.0) {
        throw "B15_2_CAPTURE_FROZEN: visual motion test failed (delta=$([math]::Round($delta,2))). Move in preflight; no long capture attempted."
    }
    Remove-Item -LiteralPath $first,$last -Force
    Write-Host "B15_2_PREFLIGHT_DYNAMIC_PASS mean_pixel_delta=$([math]::Round($delta,2))"
    Write-Host "B15.2 recording only the game region at $Fps FPS for $DurationSeconds seconds"
    $recordingLaunch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $args = '-y -hide_banner -loglevel warning -f gdigrab -framerate {0} -draw_mouse 0 -offset_x {1} -offset_y {2} -video_size {3}x{4} -i desktop -t {5} -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p -movflags +faststart "{6}"' -f $Fps,$x,$y,$w,$h,$DurationSeconds,$video
    $capture = Start-Process -FilePath $ffmpeg.Source -ArgumentList $args -PassThru -WindowStyle Hidden `
        -RedirectStandardError (Join-Path $session 'ffmpeg.stderr.log') `
        -RedirectStandardOutput (Join-Path $session 'ffmpeg.stdout.log')
    Write-Host "Keep the game in the foreground; do not move, resize or cover the window."
    Wait-Process -Id $capture.Id -Timeout ($DurationSeconds + 60) -ErrorAction Stop
    $capture.Refresh()
    if ($capture.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $video)) {
        throw 'B15.2 FFmpeg recording failed'
    }
    $streamJson = & $ffprobe.Source -v error -count_frames -select_streams v:0 `
        -show_entries stream=nb_read_frames,duration,width,height -of json "$video"
    if ($LASTEXITCODE -ne 0) { throw 'B15.2 ffprobe failed' }
    $stream = @(($streamJson -join "`n" | ConvertFrom-Json).streams)[0]
    $encodedFps = 0.0
    if ([double]$stream.duration -gt 0) {
        $encodedFps = [math]::Round(([double]$stream.nb_read_frames / [double]$stream.duration),2)
    }
    $qualifies = $encodedFps -ge 50
    $route = 'interactive WASD mouse / edit SDF'
    if ($Mode -eq 'Auto') { $route = 'scripted 18m/s turns and revisits' }
    $meta = [ordered]@{
        source = 'B15.2 experimental edit-cohort and B11 shell isolation'
        mode = $Mode
        far_shell = $FarShell
        atomic_edits = $AtomicEdits
        expected_requested_fps = $Fps
        video_encoded_fps = $encodedFps
        video_fps_qualified = $qualifies
        dynamic_preflight_delta = [math]::Round($delta,3)
        window_crop = [ordered]@{x=$x;y=$y;width=$w;height=$h}
        game_launch_unix_ms = $gameLaunch
        ffmpeg_launch_unix_ms = $recordingLaunch
        synchronization_uncertainty_ms = 1000
        camera_route = $route
        recording = 'game-window-60fps.mp4'
        trace = 'trace/b14-frames.csv'
        caveat = 'Encoded FPS does not prove distinct presented frames: visually inspect the recorded movement and SDF changes.'
    }
    $metadataJson = $meta | ConvertTo-Json -Depth 7
    $metadataJson | Set-Content -LiteralPath (Join-Path $session 'b15-2-recording.json') -Encoding UTF8
    # Keep the B15 temporal-video correlator usable without duplicating it.
    $metadataJson | Set-Content -LiteralPath (Join-Path $session 'b15-recording.json') -Encoding UTF8
    Write-Host "B15_2_CAPTURE_FPS=$encodedFps qualified=$qualifies"
    # Flush B14 CSV and game logs before archiving the entire session.
    if ($game -and -not $game.HasExited) {
        Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    $archive = "$session.zip"
    Compress-Archive -Path (Join-Path $session '*') -DestinationPath $archive -Force
    Write-Host "B15_2_READY_FOR_REVIEW: $archive"
} finally {
    if ($capture) {
        try { if (-not $capture.HasExited) { Stop-Process -Id $capture.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    if ($game) {
        try { if (-not $game.HasExited) { Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
}
