# B6/B7 end-to-end baseline: B4 edited SDF + B5 physics + B3 mixed LOD.
# Records the actual state of the acceptance gates; does NOT optimize or hide failures.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$runtime = Join-Path $root 'b6-runtime'
$report = Join-Path $root 'b6-b7-report'
New-Item -ItemType Directory -Force $report | Out-Null
$exe = Join-Path $runtime 'sandbox-game.exe'
if (-not (Test-Path $exe)) { throw "Missing MVP Release $exe" }
$env:SANDBOX_STAGE = 'B6'
$env:SANDBOX_B3_HEADLESS = '1'
$env:SANDBOX_B3_ROUTE = 'straight'
$env:SANDBOX_B3_MIXED_LOD = '1'
$env:SANDBOX_B3_RENDER_1080P = '1'
$env:SANDBOX_B3_BENCH_UNCAPPED = '1'
$env:SANDBOX_B3_CAPTURE_AFTER_SECONDS = '45'
$env:SANDBOX_B4_TEST_BRUSH = '1'
$env:SANDBOX_B4_SAVE_PATH = Join-Path $report 'world-b4.edits'
$env:SANDBOX_B5_SAVE_PATH = Join-Path $report 'world-b5-rocks.txt'
$env:SANDBOX_B2_CAPTURE_PATH = Join-Path $report 'first-pass.png'
$env:WGPU_BACKEND = 'vulkan'
$env:RUST_BACKTRACE = '1'
$env:RUST_LOG = 'info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$stdout = Join-Path $report 'first.stdout.log'
$stderr = Join-Path $report 'first.stderr.log'
Write-Host "B6 full MVP run on $env:RUNNER_NAME; Vulkan 1080p 18m/s, physics, LOD, edit and save"
$peakWorkingSet = [long]0
$peakPrivate = [long]0
$gpuMemoryBefore = ''
$gpuMemoryAfter = ''
$nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidia) { $gpuMemoryBefore = (@(& $nvidia.Source --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) -join ',').Trim() }
$p = Start-Process -FilePath $exe -WorkingDirectory $runtime -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt 105) {
        Start-Sleep -Milliseconds 350
        $p.Refresh()
        if (-not $p.HasExited) {
            $peakWorkingSet = [Math]::Max($peakWorkingSet, [long]$p.WorkingSet64)
            $peakPrivate = [Math]::Max($peakPrivate, [long]$p.PrivateMemorySize64)
        }
    }
    if (-not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        throw "B6 scenario exceeded 105-second deadline"
    }
    $p.Refresh()
    if ($null -ne $p.ExitCode -and [int]$p.ExitCode -ne 0) { throw "B6 exited with code $($p.ExitCode)" }
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
if ($nvidia) { $gpuMemoryAfter = (@(& $nvidia.Source --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) -join ',').Trim() }
if (-not (Test-Path $env:SANDBOX_B2_CAPTURE_PATH)) { throw 'B6 1080p screenshot missing' }
if ((Get-Item $env:SANDBOX_B2_CAPTURE_PATH).Length -lt 2000) { throw 'B6 screenshot invalid' }
$log = (Get-Content -LiteralPath $stderr -Raw) -replace '\x1b\[[0-9;]*m', ''
if ($log -match '(?m)\bERROR\b|Validation Error|panicked') { throw 'B6 GPU/runtime error; inspect uploaded log' }
if ($log -notmatch 'Screenshot saved to') { throw 'B6 screenshot not confirmed' }
$ci = [Globalization.CultureInfo]::InvariantCulture
$frames = New-Object 'System.Collections.Generic.List[Double]'
$fps = New-Object 'System.Collections.Generic.List[Double]'
$coverage = New-Object 'System.Collections.Generic.List[object]'
$latencies = New-Object 'System.Collections.Generic.List[Double]'
$rockCounts = New-Object 'System.Collections.Generic.List[Int32]'
foreach ($line in ($log -split "[\r\n]+")) {
    if ($line -match '\bframe_time\s+:\s+([0-9.]+)ms') {
        $frames.Add([double]::Parse($Matches[1],$ci))
    }
    if ($line -match '\bfps\s+:\s+([0-9.]+)') {
        $fps.Add([double]::Parse($Matches[1],$ci))
    }
    if ($line -match 'B3 horizon coverage') {
        $record = @{}
        foreach ($field in @('required','visible','missing','lod0','lod1','lod2','seam_blocks','transition_commits','x','cpu_max_us')) {
            if ($line -match ("\b"+$field+"=(-?[0-9.]+)")) { $record[$field] = $Matches[1] }
        }
        if ($record.Count -eq 10) { $coverage.Add($record) }
    }
    if ($line -match 'B4 revised GPU mesh ready for publication' -and $line -match '\blatency_ms=([0-9.]+)') {
        $latencies.Add([double]::Parse($Matches[1],$ci))
    }
    if ($line -match 'B5 130m deterministic rock visual streaming' -and $line -match '\bresident_rocks=(\d+)') {
        $rockCounts.Add([int]$Matches[1])
    }
}
if ($frames.Count -lt 20 -or $coverage.Count -lt 20) { throw "B6 incomplete telemetry: frames=$($frames.Count) coverage=$($coverage.Count)" }
$moving = @($coverage | Where-Object { [Math]::Abs(([double]::Parse($_.x,$ci))-([double]::Parse($coverage[0].x,$ci))) -gt 0.25 })
$movingMissing = @($moving | Where-Object { [int]$_.missing -gt 0 }).Count
$mixedSamples = @($moving | Where-Object { [int]$_.lod0 -gt 0 -and [int]$_.lod1 -gt 0 -and [int]$_.lod2 -gt 0 -and [int]$_.seam_blocks -gt 0 }).Count
$distance = [double]::Parse($coverage[$coverage.Count - 1].x,$ci)-[double]::Parse($coverage[0].x,$ci)
$sorted = @($frames | Sort-Object)
$frameP95 = $sorted[[Math]::Ceiling($sorted.Count * 0.95)-1]
$frameP99 = $sorted[[Math]::Ceiling($sorted.Count * 0.99)-1]
$maxFrame = $sorted[$sorted.Count-1]
$frameMean = ($frames | Measure-Object -Average).Average
$fpsAvg = if ($fps.Count) { ($fps | Measure-Object -Average).Average } else { 0.0 }
$editsPersisted = (Test-Path $env:SANDBOX_B4_SAVE_PATH) -and ((Get-Content -LiteralPath $env:SANDBOX_B4_SAVE_PATH).Count -gt 1)
$rocksPersisted = (Test-Path $env:SANDBOX_B5_SAVE_PATH) -and ((Get-Content -LiteralPath $env:SANDBOX_B5_SAVE_PATH).Count -gt 1)
$editedGPU = $latencies.Count -gt 0
$maxEditLatency = if ($editedGPU) { ($latencies | Measure-Object -Maximum).Maximum } else { $null }
$maxRocks = if ($rockCounts.Count) { ($rockCounts | Measure-Object -Maximum).Maximum } else { 0 }
$benchmark = [ordered]@{
    runner = $env:RUNNER_NAME
    stage = 'B6'
    mode = 'Vulkan headless 1080p, uncapped, 18m/s, mixed LOD + B4 + B5'
    distance_m = $distance
    frame_samples = $frames.Count
    frame_ms_mean = $frameMean
    frame_ms_p95 = $frameP95
    frame_ms_p99 = $frameP99
    frame_ms_max = $maxFrame
    fps_average = $fpsAvg
    coverage_samples = $coverage.Count
    moving_coverage_samples = $moving.Count
    missing_samples = $movingMissing
    mixed_lod_samples = $mixedSamples
    edit_persisted = [bool]$editsPersisted
    edited_gpu_publication = [bool]$editedGPU
    edit_compute_latency_ms_max = $maxEditLatency
    rock_save_persisted = [bool]$rocksPersisted
    rocks_resident_max = $maxRocks
    peak_working_set_bytes = $peakWorkingSet
    peak_private_bytes = $peakPrivate
    gpu_vram_used_before_mib = $gpuMemoryBefore
    gpu_vram_used_after_mib = $gpuMemoryAfter
    present_frame_time_measured = $false
}
$benchmark | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $report 'benchmark.json') -Encoding UTF8
$coverage | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $report 'coverage.json') -Encoding UTF8
$benchmark | Format-List | Out-String | Write-Host
# Save/reopen proof is separate; no fresh auto edit on reopen.
if ($editsPersisted -and $rocksPersisted) {
    $env:SANDBOX_B4_TEST_BRUSH = '0'
    $env:SANDBOX_B3_ROUTE = ''
    $env:SANDBOX_B3_CAPTURE_AFTER_SECONDS = '12'
    $env:SANDBOX_B2_CAPTURE_PATH = Join-Path $report 'reopen.png'
    $p2 = Start-Process -FilePath $exe -WorkingDirectory $runtime -PassThru -RedirectStandardOutput (Join-Path $report 'reopen.stdout.log') -RedirectStandardError (Join-Path $report 'reopen.stderr.log')
    try {
        if (-not $p2.WaitForExit(55000)) {
            Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue
            throw 'B6 reopen timed out'
        }
        $p2.Refresh()
        if ($null -ne $p2.ExitCode -and $p2.ExitCode -ne 0) { throw "B6 reopen exited with $($p2.ExitCode)" }
    } finally {
        if (-not $p2.HasExited) { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue }
    }
    $reopenLog = (Get-Content -LiteralPath (Join-Path $report 'reopen.stderr.log') -Raw) -replace '\x1b\[[0-9;]*m',''
    $reopened = ($reopenLog -match 'B4 journal loaded' -and $reopenLog -match 'edits=([1-9]\d*)')
    $rocksReopened = ($reopenLog -match 'B5 persistent rocks loaded' -and $reopenLog -match 'restored=([1-9]\d*)')
    $benchmark.reopened_edit = [bool]$reopened
    $benchmark.reopened_rocks = [bool]$rocksReopened
    $benchmark | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $report 'benchmark.json') -Encoding UTF8
    Write-Host "B6 reopen edit=$reopened rocks=$rocksReopened"
} else {
    $benchmark.reopened_edit = $false
    $benchmark.reopened_rocks = $false
    $benchmark | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $report 'benchmark.json') -Encoding UTF8
}
if ($distance -lt 500) { throw 'B6 18m/s route failed to traverse 500m' }
if ($movingMissing -gt 0) { throw 'B6 required horizon gaps' }
