# B15.3 interactive Vulkan capture: DXGI desktop duplication (preferred)
# versus legacy GDI. Requires interactive Windows desktop, FFmpeg+ffprobe.
# DXGI outputs D3D11 hardware frames directly to NVENC; never use Session 0.
param(
    [string]$AppDir = 'C:\Dev\sandbox-b15-2-local\app',
    [string]$OutputRoot = 'C:\Dev\sandbox-b15-2-local\captures',
    [ValidateSet('Live','Auto')][string]$Mode = 'Live',
    [ValidateRange(15,300)][int]$DurationSeconds = 120,
    [ValidateRange(24,60)][int]$Fps = 60,
    [ValidateSet('0','1')][string]$FarShell = '1',
    [ValidateSet('0','1')][string]$AtomicEdits = '1',
    [ValidateSet('Nvenc','Cpu')][string]$Encoder = 'Nvenc',
    [ValidateSet('Dxgi','Gdi')][string]$CaptureBackend = 'Dxgi',
    [ValidateRange(0,16)][int]$DxgiOutputIdx = 0,
    [string]$PresentMonPath = '',
    [switch]$ContractTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Get-B15_4PresentMonFailure {
    param([string]$ErrorText,[int]$ExitCode)
    if ($ErrorText -match '(?i)access denied|requires (either )?administrative privileges|Performance Log Users') {
        return 'B15_4_PRESENTMON_ACCESS_DENIED: ETW collector requires an elevated PowerShell session (Run as administrator), or membership in Performance Log Users with a fresh logon. No full recording started.'
    }
    $tail = ($ErrorText -split "[\r\n]+" | Where-Object { $_.Trim() } |
        Select-Object -Last 5) -join ' | '
    return "B15_4_PRESENTMON_START_FAILED exit=$ExitCode details=$tail"
}
function Get-B15_3InputArgs {
    param(
        [string]$Backend, [int]$Rate, [int]$X, [int]$Y,
        [int]$Width, [int]$Height, [int]$OutputIdx
    )
    $size = "${Width}x${Height}"
    if ($Backend -eq 'Dxgi') {
        # GPU-only D3D11 frames: no hwdownload or GDI screen copy.
        $src = "ddagrab=output_idx=${OutputIdx}:framerate=${Rate}:draw_mouse=0:video_size=${size}:offset_x=${X}:offset_y=${Y}"
        return @('-f','lavfi','-i',$src)
    }
    return @('-f','gdigrab','-framerate',"$Rate",'-draw_mouse','0',
        '-offset_x',"$X",'-offset_y',"$Y",'-video_size',$size,'-i','desktop')
}
function Get-B15_3EncodeArgs {
    param([string]$Backend,[string]$Encoder,[int]$Quality)
    if ($Backend -eq 'Dxgi' -and $Encoder -ne 'Nvenc') {
        throw 'B15_3_DXGI_REQUIRES_NVENC: D3D11 frames must stay on the GPU. For CPU fallback choose -CaptureBackend Gdi -Encoder Cpu.'
    }
    if ($Encoder -eq 'Nvenc') {
        # DXGI hardware frames are submitted directly to NVENC without
        # forcing a software -pix_fmt (which would break D3D11 zero-copy).
        $encoderArgs = @('-c:v','h264_nvenc','-preset','p1',
            '-rc','vbr','-cq',"$Quality",'-b:v','0')
        if ($Backend -eq 'Gdi') { $encoderArgs += @('-pix_fmt','yuv420p') }
        return $encoderArgs
    }
    return @('-c:v','libx264','-preset','ultrafast',
        '-crf',"$Quality",'-pix_fmt','yuv420p')
}
if (-not ([System.Management.Automation.PSTypeName]'B15_2DesktopRect').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct B15_2_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct B15_2_POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)]
public struct B15_2_MONITORINFO {
    public int cbSize;
    public B15_2_RECT rcMonitor, rcWork;
    public uint dwFlags;
}
public static class B15_2DesktopRect {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out B15_2_RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref B15_2_POINT point);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out B15_2_RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hmonitor, ref B15_2_MONITORINFO info);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
}
if ($ContractTest) {
    $dx = @(Get-B15_3InputArgs -Backend Dxgi -Rate 60 -X 294 -Y 317 -Width 1920 -Height 1080 -OutputIdx 0)
    $ge = @(Get-B15_3InputArgs -Backend Gdi -Rate 60 -X 294 -Y 317 -Width 1920 -Height 1080 -OutputIdx 0)
    $ne = @(Get-B15_3EncodeArgs -Backend Dxgi -Encoder Nvenc -Quality 22)
    $ce = @(Get-B15_3EncodeArgs -Backend Gdi -Encoder Cpu -Quality 20)
    if ((($dx -join ' ') -notmatch 'ddagrab=output_idx=0:framerate=60:draw_mouse=0:video_size=1920x1080:offset_x=294:offset_y=317') -or
        $dx -contains 'gdigrab' -or $dx -contains 'desktop' -or
        $ge -notcontains 'gdigrab' -or $ge -notcontains 'desktop' -or
        $ne -notcontains 'h264_nvenc' -or $ne -contains '-pix_fmt' -or
        $ce -notcontains 'libx264') {
        throw 'B15_3_CAPTURE_ARGS_CONTRACT_FAILED'
    }
    $rejected = $false
    try {
        [void]@(Get-B15_3EncodeArgs -Backend Dxgi -Encoder Cpu -Quality 20)
    } catch { $rejected = $_.Exception.Message -like '*B15_3_DXGI_REQUIRES_NVENC*' }
    if (-not $rejected) { throw 'B15_3_DXGI_CPU_GUARD_FAILED' }
    $pmAccess = Get-B15_4PresentMonFailure -ErrorText 'error: failed to start trace session: access denied.' -ExitCode 1
    if ($pmAccess -notlike 'B15_4_PRESENTMON_ACCESS_DENIED:*') {
        throw 'B15_4_PRESENTMON_ACCESS_DENIED_CONTRACT_FAILED'
    }
    $pmOther = Get-B15_4PresentMonFailure -ErrorText 'unknown option --x' -ExitCode 2
    if ($pmOther -notlike 'B15_4_PRESENTMON_START_FAILED*') {
        throw 'B15_4_PRESENTMON_OTHER_FAILURE_CONTRACT_FAILED'
    }
    Write-Host 'B15_4_PRESENTMON_ACCESS_PREFLIGHT_CONTRACT_PASS'
    # Exercise actual P/Invoke struct marshalling: PowerShell 5.1 selects the
    # wrong Marshal.SizeOf overload when handed a RuntimeType.
    $monitorProbe = New-Object B15_2_MONITORINFO
    $monitorProbe.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($monitorProbe)
    if ($monitorProbe.cbSize -ne 40) {
        throw "B15_3_MONITORINFO_ABI_FAILED size=$($monitorProbe.cbSize) expected=40"
    }
    Write-Host "B15_3_MONITORINFO_MARSHAL_PASS size=$($monitorProbe.cbSize)"
    Write-Host 'B15_3_CAPTURE_ARGS_CONTRACT_PASS dxgi_nvenc gdi_cpu no_hwdownload'
    return
}
if ($CaptureBackend -eq 'Dxgi' -and $Encoder -ne 'Nvenc') {
    throw 'B15_3_DXGI_REQUIRES_NVENC: use -CaptureBackend Gdi with -Encoder Cpu as fallback'
}
$exe = Join-Path $AppDir 'sandbox-game.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing $exe" }
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'assets\shaders'))) {
    throw 'Missing shader assets in runtime folder'
}
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction Stop
$ffprobe = Get-Command ffprobe.exe -ErrorAction Stop
$ffmpegVersion = @(& $ffmpeg.Source -version | Select-Object -First 1)[0]
if ($CaptureBackend -eq 'Dxgi') {
    $filterList = @(& $ffmpeg.Source -hide_banner -filters)
    if ($LASTEXITCODE -ne 0 -or
        -not @($filterList | Where-Object { $_ -like '*ddagrab*' }).Count) {
        throw "B15_3_DXGI_FILTER_MISSING: $($ffmpeg.Source) has no ddagrab. Use FFmpeg 7.1.1 full_build."
    }
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
# Auto is the fixed 18m/s route with six alternating add/subtract SDF edits.
$env:SANDBOX_B15_1_SCRIPTED_EDITS = if ($Mode -eq 'Auto') { '1' } else { '0' }
$env:SANDBOX_B9_CREATIVE = '1'
$env:SANDBOX_B14_TRACE_DIR = $trace
# B15.4 synchronized per-frame cost columns, equal in both B11 A/B arms.
$env:SANDBOX_B15_4_CORRELATE = '1'
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
$presentMon = $null
$presentMonCsv = Join-Path $session 'presentmon.csv'
$presentMonStarted = $false
try {
    $gameLaunch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $game = Start-Process -FilePath $exe -WorkingDirectory $AppDir -PassThru `
        -RedirectStandardOutput (Join-Path $session 'game.stdout.log') `
        -RedirectStandardError (Join-Path $session 'game.stderr.log')
    # Do not trust the first non-zero MainWindowHandle: Winit/Bevy can
    # create the native HWND before assigning the final drawable size.
    # In B15.2's first local run, that race yielded a 0x0 client rect.
    $handle = [IntPtr]::Zero
    $x = 0; $y = 0; $w = 0; $h = 0
    $regionSource = ''
    $lastProbe = 'no HWND yet'
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Milliseconds 250
        $game.Refresh()
        if ($game.HasExited) { throw "Game exited early ($($game.ExitCode))" }
        $handle = $game.MainWindowHandle
        if ($handle -eq [IntPtr]::Zero) {
            $lastProbe = 'no HWND yet'
            continue
        }
        if ([B15_2DesktopRect]::IsIconic($handle)) {
            $lastProbe = 'window minimized'
            continue
        }
        if (-not [B15_2DesktopRect]::IsWindowVisible($handle)) {
            $lastProbe = 'window exists but is not visible'
            continue
        }
        $rect = New-Object B15_2_RECT
        $point = New-Object B15_2_POINT
        $clientValid = [B15_2DesktopRect]::GetClientRect($handle, [ref]$rect) -and
            [B15_2DesktopRect]::ClientToScreen($handle, [ref]$point)
        if ($clientValid) {
            $w = [int]([math]::Floor(($rect.Right - $rect.Left) / 2.0) * 2)
            $h = [int]([math]::Floor(($rect.Bottom - $rect.Top) / 2.0) * 2)
            $x = [int]$point.X
            $y = [int]$point.Y
            if ($w -ge 640 -and $h -ge 360 -and $w -le 4096 -and $h -le 2160) {
                $regionSource = 'client'
                break
            }
            $lastProbe = "client=${w}x${h} hwnd=$handle"
        } else {
            $lastProbe = "GetClientRect/ClientToScreen failed hwnd=$handle"
        }
        # After 2s prefer a valid outer window rect over a persistently 0x0
        # client; FFmpeg preflight still checks that real pixels change.
        if ($attempt -ge 8) {
            $outer = New-Object B15_2_RECT
            if ([B15_2DesktopRect]::GetWindowRect($handle, [ref]$outer)) {
                $outerW = [int]([math]::Floor(($outer.Right - $outer.Left) / 2.0) * 2)
                $outerH = [int]([math]::Floor(($outer.Bottom - $outer.Top) / 2.0) * 2)
                if ($outerW -ge 640 -and $outerH -ge 360 -and
                    $outerW -le 4096 -and $outerH -le 2160) {
                    $x = [int]$outer.Left
                    $y = [int]$outer.Top
                    $w = $outerW
                    $h = $outerH
                    $regionSource = 'outer-window-fallback'
                    Write-Warning 'B15.2: client rect not ready; using window bounds (including borders).'
                    break
                }
                $lastProbe += " outer=${outerW}x${outerH}"
            }
        }
    }
    if ($regionSource -eq '') {
        throw "B15_2_WINDOW_NOT_READY: no valid game region after 30s; last=$lastProbe. Restore the game window and inspect the latest game.stderr.log under $session"
    }
    Write-Host "B15_2_WINDOW_REGION x=$x y=$y size=${w}x${h} source=$regionSource"
    $captureX = $x
    $captureY = $y
    $monitor = $null
    if ($CaptureBackend -eq 'Dxgi') {
        # DXGI offset_x/offset_y are local to the chosen monitor, unlike
        # GDI's virtual-desktop coordinates.
        $monitorHandle = [B15_2DesktopRect]::MonitorFromWindow($handle, 2)
        if ($monitorHandle -eq [IntPtr]::Zero) {
            throw 'B15_3_DXGI_MONITOR_NOT_FOUND'
        }
        $monitor = New-Object B15_2_MONITORINFO
        $monitor.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($monitor)
        if (-not [B15_2DesktopRect]::GetMonitorInfo($monitorHandle, [ref]$monitor)) {
            throw 'B15_3_DXGI_MONITOR_BOUNDS_FAILED'
        }
        $captureX = [int]($x - $monitor.rcMonitor.Left)
        $captureY = [int]($y - $monitor.rcMonitor.Top)
        $displayW = [int]($monitor.rcMonitor.Right - $monitor.rcMonitor.Left)
        $displayH = [int]($monitor.rcMonitor.Bottom - $monitor.rcMonitor.Top)
        if ($captureX -lt 0 -or $captureY -lt 0 -or
            ($captureX + $w) -gt $displayW -or
            ($captureY + $h) -gt $displayH) {
            throw "B15_3_DXGI_WINDOW_SPANS_MONITORS: capture=${w}x${h} relative=${captureX},${captureY} monitor=${displayW}x${displayH}. Keep the game entirely on one monitor."
        }
        Write-Host "B15_3_DXGI_MONITOR output_idx=$DxgiOutputIdx relative=${captureX},${captureY} display=${displayW}x${displayH}"
        if ($DxgiOutputIdx -ne 0) {
            Write-Warning 'DXGI output index must correspond to this physical display; verify video pixels in preflight.'
        }
    }
    # Own the ETW collector process strictly within this game session.
    # PresentMon's --date_time provides absolute timing for B14 correlation.
    # Service Session 0 runners must NOT attempt this desktop ETW capture.
    if (-not [string]::IsNullOrWhiteSpace($PresentMonPath)) {
        if (-not (Test-Path -LiteralPath $PresentMonPath -PathType Leaf)) {
            throw "B15_4_PRESENTMON_NOT_FOUND: $PresentMonPath"
        }
        $pmDuration = $DurationSeconds + 90
        $pmArgs = '--process_id {0} --output_file "{1}" --date_time --timed {2} --terminate_on_proc_exit --no_console_stats --session_name B154_{0}' -f $game.Id, $presentMonCsv, $pmDuration
        $presentMon = Start-Process -FilePath $PresentMonPath -ArgumentList $pmArgs -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $session 'presentmon.stdout.log') `
            -RedirectStandardError (Join-Path $session 'presentmon.stderr.log')
        $presentMonStarted = $true
        Write-Host "B15_4_PRESENTMON_STARTED pid=$($presentMon.Id) game_pid=$($game.Id)"
        # Protect long 120s A/B runs: the current machine's PresentMon
        # previously exited with "access denied" and no CSV. Fail before
        # the 8s video preflight (and before Auto's full benchmark).
        Start-Sleep -Seconds 3
        $presentMon.Refresh()
        if ($presentMon.HasExited) {
            $pmErrorPath = Join-Path $session 'presentmon.stderr.log'
            $pmError = if (Test-Path -LiteralPath $pmErrorPath) {
                [System.IO.File]::ReadAllText($pmErrorPath)
            } else { '' }
            $pmMessage = Get-B15_4PresentMonFailure -ErrorText $pmError -ExitCode $presentMon.ExitCode
            throw "$pmMessage Log=$pmErrorPath"
        }
        Write-Host 'B15_4_PRESENTMON_STARTUP_PASS collector_alive_after_3s'
    }
    if ($Mode -eq 'Auto') {
        # The survey route holds the camera still for its first 12 game seconds.
        # Wait until the scripted motion has begun before testing video dynamics.
        Write-Host 'B15.2 AUTO: waiting for survey warmup to end before motion preflight.'
        Start-Sleep -Seconds 12
    }
    Write-Host "B15_3_CAPTURE_SELECTED backend=$CaptureBackend encoder=$Encoder ffmpeg=$ffmpegVersion"
    Write-Host 'PREFLIGHT: MOVE THE CAMERA OR WALK DURING THE NEXT 8 SECONDS.'
    # Match the direct interactive FFmpeg command proven to work on the
    # user's Windows desktop. Start-Process/-WindowStyle Hidden was returning
    # a failed preflight with an empty stderr file. Preserve *both* streams
    # and the native exit code to distinguish launch from encoding failures.
    $probeLog = Join-Path $session 'preflight-ffmpeg.log'
    $oldErrorPreference = $ErrorActionPreference
    $preflightExitCode = -999
    try {
        # Windows PowerShell 5.1 wraps native stderr records as errors;
        # do not let informational FFmpeg output become a terminating error.
        $ErrorActionPreference = 'Continue'
        $preflightArgs = @('-y','-hide_banner','-loglevel','info')
        $preflightArgs += @(Get-B15_3InputArgs -Backend $CaptureBackend -Rate 15 -X $captureX -Y $captureY -Width $w -Height $h -OutputIdx $DxgiOutputIdx)
        $preflightArgs += @('-t','8')
        $preflightArgs += @(Get-B15_3EncodeArgs -Backend $CaptureBackend -Encoder $Encoder -Quality 26)
        $preflightArgs += @('-movflags','+faststart',"$preflight")
        & $ffmpeg.Source @preflightArgs 2>&1 |
            Out-File -LiteralPath $probeLog -Encoding UTF8
        $preflightExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorPreference
    }
    $preflightExists = Test-Path -LiteralPath $preflight -PathType Leaf
    $preflightSize = 0L
    if ($preflightExists) {
        $preflightSize = (Get-Item -LiteralPath $preflight).Length
    }
    Write-Host "B15_2_PREFLIGHT_FFMPEG exit=$preflightExitCode bytes=$preflightSize log=$probeLog"
    if ($preflightExitCode -ne 0 -or $preflightSize -lt 10000) {
        $logTail = if (Test-Path -LiteralPath $probeLog) {
            (Get-Content -LiteralPath $probeLog -Tail 12) -join ' | '
        } else { 'no FFmpeg log' }
        throw "B15_2_PREFLIGHT_ENCODING_FAILED encoder=$Encoder exit=$preflightExitCode bytes=$preflightSize; $logTail. If NVENC fails, retry with -Encoder Cpu."
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
    $recordingLog = Join-Path $session 'ffmpeg.stderr.log'
    Write-Host 'Keep the game in the foreground; do not move, resize or cover the window.'
    $recordingExitCode = -999
    $oldErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $recordingArgs = @('-y','-hide_banner','-loglevel','info')
        $recordingArgs += @(Get-B15_3InputArgs -Backend $CaptureBackend -Rate $Fps -X $captureX -Y $captureY -Width $w -Height $h -OutputIdx $DxgiOutputIdx)
        $recordingArgs += @('-t',"$DurationSeconds")
        $recordingQuality = if ($Encoder -eq 'Nvenc') { 22 } else { 20 }
        $recordingArgs += @(Get-B15_3EncodeArgs -Backend $CaptureBackend -Encoder $Encoder -Quality $recordingQuality)
        $recordingArgs += @('-movflags','+faststart',"$video")
        & $ffmpeg.Source @recordingArgs 2>&1 |
            Out-File -LiteralPath $recordingLog -Encoding UTF8
        $recordingExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorPreference
    }
    $recordingExists = Test-Path -LiteralPath $video -PathType Leaf
    $recordingSize = 0L
    if ($recordingExists) {
        $recordingSize = (Get-Item -LiteralPath $video).Length
    }
    Write-Host "B15_2_RECORDING_FFMPEG backend=$CaptureBackend encoder=$Encoder exit=$recordingExitCode bytes=$recordingSize"
    if ($recordingExitCode -ne 0 -or $recordingSize -lt 100000) {
        $logTail = if (Test-Path -LiteralPath $recordingLog) {
            (Get-Content -LiteralPath $recordingLog -Tail 12) -join ' | '
        } else { 'no FFmpeg log' }
        throw "B15_2_RECORDING_FAILED encoder=$Encoder exit=$recordingExitCode bytes=$recordingSize; $logTail"
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
        video_encoder = $Encoder
        capture_backend = $CaptureBackend
        dxgi_output_idx = $DxgiOutputIdx
        ffmpeg_version = $ffmpegVersion
        local_utc_offset_minutes = [int]([TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalMinutes)
        capture_source_offset = [ordered]@{ x=$captureX; y=$captureY }
        scripted_edits_requested = if ($Mode -eq 'Auto') { 6 } else { 0 }
        b15_4_correlate = $true
        presentmon_requested = (-not [string]::IsNullOrWhiteSpace($PresentMonPath))
        presentmon_csv = if ($presentMonStarted) { 'presentmon.csv' } else { $null }
        far_shell = $FarShell
        atomic_edits = $AtomicEdits
        expected_requested_fps = $Fps
        expected_recording_duration_seconds = $DurationSeconds
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
    if ($presentMon) {
        try {
            if (-not $presentMon.WaitForExit(8000)) {
                Stop-Process -Id $presentMon.Id -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Warning "B15_4_PRESENTMON_SHUTDOWN_WARNING: $($_.Exception.Message)" }
        $pmBytes = if (Test-Path -LiteralPath $presentMonCsv) {
            (Get-Item -LiteralPath $presentMonCsv).Length
        } else { 0 }
        Write-Host "B15_4_PRESENTMON_CSV_BYTES=$pmBytes"
        if ($pmBytes -lt 1000) {
            Write-Warning "B15_4_PRESENTMON_UNQUALIFIED: missing or empty external present data; inspect presentmon logs"
        }
    }
    if ($Mode -eq 'Auto') {
        $gameLog = Join-Path $session 'game.stderr.log'
        $scriptedCount = 0
        if (Test-Path -LiteralPath $gameLog) {
            $scriptedCount = ([regex]::Matches(
                (Get-Content -LiteralPath $gameLog -Raw),
                'B15\.1 scripted edit requested'
            )).Count
        }
        Write-Host "B15_3_AUTOMATED_EDIT_COUNT=$scriptedCount expected=6"
        if ($scriptedCount -ne 6) {
            Write-Warning "B15_3_AUTOMATED_EDITS_INCOMPLETE: count=$scriptedCount. Evidence is retained; do not qualify the six-edit gate."
        }
    }
    $archive = "$session.zip"
    Compress-Archive -Path (Join-Path $session '*') -DestinationPath $archive -Force
    Write-Host "B15_2_READY_FOR_REVIEW: $archive"
} finally {
    if ($presentMon) {
        try { if (-not $presentMon.HasExited) { Stop-Process -Id $presentMon.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    if ($game) {
        try { if (-not $game.HasExited) { Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
}
