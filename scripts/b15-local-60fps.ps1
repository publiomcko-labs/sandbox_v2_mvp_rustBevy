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
    $recordingLaunch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $args = '-y -hide_banner -loglevel warning -f gdigrab -framerate {0} -draw_mouse 0 -i desktop -t {1} -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p -movflags +faststart "{2}"' -f $Fps,$DurationSeconds,$video
    $capture = Start-Process -FilePath $ffmpeg.Source -ArgumentList $args -PassThru -RedirectStandardError (Join-Path $session 'ffmpeg.stderr.log') -RedirectStandardOutput (Join-Path $session 'ffmpeg.stdout.log')
    Write-Host "B15: recording desktop at $Fps FPS for $DurationSeconds seconds"
    Write-Host "B15: session $session"
    Write-Host 'Keep the game foreground and do not move or resize the window.'
    Wait-Process -Id $capture.Id -Timeout ($DurationSeconds + 60) -ErrorAction Stop
    $capture.Refresh()
    if ($capture.ExitCode -ne 0) { throw "FFmpeg exited with code $($capture.ExitCode)" }
    if (-not (Test-Path -LiteralPath $video -PathType Leaf) -or (Get-Item -LiteralPath $video).Length -lt 100000) {
        throw "Video missing or too small: $video"
    }
    $metadata = [ordered]@{
        mode = $Mode
        stage = 'B11'
        camera_route = if ($Mode -eq 'Auto') { 'straight / 18mps' } else { 'interactive free flight' }
        fps_requested = $Fps
        requested_seconds = $DurationSeconds
        game_launch_unix_ms = $launched
        ffmpeg_launch_unix_ms = $recordingLaunch
        synchronization_uncertainty_ms = 1000
        recording = 'desktop-60fps.mp4'
        trace = 'trace/b14-frames.csv'
        note = 'B14 timestamps are at main-world Last; FFmpeg records the desktop compositor. Match with +/- 1s uncertainty. Pixel anomalies are candidates only.'
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $session 'b15-recording.json') -Encoding UTF8
    $archive = "$session.zip"
    Compress-Archive -Path (Join-Path $session '*') -DestinationPath $archive -Force
    Write-Host "B15_READY_FOR_CAUSAL_REVIEW: $archive"
} finally {
    if ($capture) {
        try { if (-not $capture.HasExited) { Stop-Process -Id $capture.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    if ($game) {
        try { if (-not $game.HasExited) { Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
}
