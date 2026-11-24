# B15 interactive Windows capture. Requires FFmpeg and an interactive desktop
# session (NOT a GitHub Actions Windows service in Session 0).
param(
    [string]$AppDir = 'C:\Dev\sandbox-b15-visual\app',
    [string]$OutputRoot = 'C:\Dev\sandbox-b15-visual\captures',
    [ValidateSet('Auto','Live')][string]$Mode = 'Live',
    [ValidateRange(15,300)][int]$DurationSeconds = 120,
    [ValidateRange(24,60)][int]$Fps = 60
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$exe = Join-Path $AppDir 'sandbox-game.exe'
$shaders = Join-Path $AppDir 'assets\shaders'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing executable: $exe" }
if (-not (Test-Path -LiteralPath $shaders -PathType Container)) { throw "Missing shaders: $shaders" }
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (-not $ffmpeg) { throw 'FFmpeg missing. Install with: winget install --id Gyan.FFmpeg -e' }
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
$session = Join-Path $OutputRoot "b15-$Mode-$stamp"
$trace = Join-Path $session 'trace'
New-Item -ItemType Directory -Force -Path $session,$trace | Out-Null
$video = Join-Path $session 'desktop-60fps.mp4'
$env:SANDBOX_STAGE = 'B11'
$env:SANDBOX_B3_MIXED_LOD = '1'
$env:SANDBOX_B11_FAR_FIELD = '1'
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
if ($Mode -eq 'Auto') { $env:SANDBOX_B3_ROUTE = 'straight' }
else { Remove-Item Env:SANDBOX_B3_ROUTE -ErrorAction SilentlyContinue }
$game = $null
$capture = $null
$launched = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
try {
    $game = Start-Process -FilePath $exe -WorkingDirectory $AppDir -PassThru -RedirectStandardOutput (Join-Path $session 'game.stdout.log') -RedirectStandardError (Join-Path $session 'game.stderr.log')
    Start-Sleep -Seconds 2
    if ($game.HasExited) { throw "Game exited early ($($game.ExitCode))" }
    # B15.1: never record the 6000x1440 multi-monitor desktop (9.6 FPS in B15).
    # FFmpeg gdigrab supports capturing exactly one window by title.
    $game.Refresh()
    $windowTitle = (Get-Process -Id $game.Id).MainWindowTitle
    if ([string]::IsNullOrWhiteSpace($windowTitle)) {
        throw 'Unable to locate an interactive game window; do not capture desktop.'
    }
    if ($windowTitle.Contains('"')) { throw 'Window title contains unsupported quotes.' }
    $recordingLaunch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $args = '-y -hide_banner -loglevel warning -f gdigrab -framerate {0} -draw_mouse 0 -i "title={1}" -t {2} -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p -movflags +faststart "{3}"' -f $Fps,$windowTitle,$DurationSeconds,$video
    $capture = Start-Process -FilePath $ffmpeg.Source -ArgumentList $args -PassThru -RedirectStandardError (Join-Path $session 'ffmpeg.stderr.log') -RedirectStandardOutput (Join-Path $session 'ffmpeg.stdout.log')
    Write-Host "B15.1: recording game window at $Fps FPS for $DurationSeconds seconds"
    Write-Host "B15: session $session"
    Write-Host 'Keep the game foreground and do not move or resize the window.'
    Wait-Process -Id $capture.Id -Timeout ($DurationSeconds + 60) -ErrorAction Stop
    $capture.Refresh()
    if ($capture.ExitCode -ne 0) { throw "FFmpeg exited with code $($capture.ExitCode)" }
    if (-not (Test-Path -LiteralPath $video -PathType Leaf) -or (Get-Item -LiteralPath $video).Length -lt 100000) {
        throw "Video missing or too small: $video"
    }
    $probe = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if (-not $probe) { throw 'ffprobe missing: FFmpeg installation incomplete' }
    $probeOutput = & $probe.Source -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames,duration,width,height -of json "$video"
    if ($LASTEXITCODE -ne 0) { throw 'FFprobe failed to inspect captured video' }
    $stream = @((($probeOutput -join "`n") | ConvertFrom-Json).streams)[0]
    $actualFps = if ([double]$stream.duration -gt 0) {
        [math]::Round(([double]$stream.nb_read_frames / [double]$stream.duration), 2)
    } else { 0.0 }
    $qualified = $actualFps -ge 50.0
    if (-not $qualified) {
        Write-Warning "B15.1 capture FPS insufficient for one-frame flicker claims: $actualFps"
    }
    $routeDescription = if ($Mode -eq 'Auto') { 'straight / 18mps' } else { 'interactive free flight' }
    $metadata = [ordered]@{
        mode = $Mode
        recording_window_title = $windowTitle
        encoded_frames = [int]$stream.nb_read_frames
        encoded_width = [int]$stream.width
        encoded_height = [int]$stream.height
        actual_recorded_fps = $actualFps
        capture_qualified_50fps = $qualified
        stage = 'B11'
        camera_route = $routeDescription
        fps_requested = $Fps
        requested_seconds = $DurationSeconds
        game_launch_unix_ms = $launched
        ffmpeg_launch_unix_ms = $recordingLaunch
        synchronization_uncertainty_ms = 1000
        recording = 'desktop-60fps.mp4'
        trace = 'trace/b14-frames.csv'
        note = 'B14 timestamps are at main-world Last; FFmpeg records the game window. Match with +/- 1s uncertainty. Pixel anomalies are candidates only.'
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $session 'b15-recording.json') -Encoding UTF8
    $archive = "$session.zip"
    Compress-Archive -Path (Join-Path $session '*') -DestinationPath $archive -Force
    Write-Host "B15_1_CAPTURE actual_fps=$actualFps resolution=$($stream.width)x$($stream.height) qualified=$qualified"
    Write-Host "B15_READY_FOR_CAUSAL_REVIEW: $archive"
} finally {
    if ($capture) {
        try { if (-not $capture.HasExited) { Stop-Process -Id $capture.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    if ($game) {
        try { if (-not $game.HasExited) { Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
}
