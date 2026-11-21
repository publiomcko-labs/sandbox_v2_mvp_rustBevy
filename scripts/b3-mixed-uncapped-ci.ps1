# Instrument the existing mixed-LOD Release without scheduler cadence.
# This measures Bevy headless GPU workload, NOT physical display presentation.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Get-Location).Path
$runtime=Join-Path $root 'b3-runtime'
$report=Join-Path $root 'b3-uncapped-report'
New-Item -ItemType Directory -Force $report | Out-Null
$exe=Join-Path $runtime 'sandbox-game.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Missing immutable B3 Release $exe" }
$env:SANDBOX_STAGE='B3'
$env:SANDBOX_B3_HEADLESS='1'
$env:SANDBOX_B3_ROUTE='straight'
$env:SANDBOX_B3_RENDER_1080P='1'
$env:SANDBOX_B3_MIXED_LOD='1'
$env:SANDBOX_B3_BENCH_UNCAPPED='1'
$env:SANDBOX_B3_CAPTURE_AFTER_SECONDS='45'
$env:WGPU_BACKEND='vulkan'
$env:SANDBOX_B2_CAPTURE_PATH=Join-Path $report 'mixed-uncapped.png'
$env:RUST_LOG='info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$env:RUST_BACKTRACE='1'
$stdout=Join-Path $report 'stdout.log'
$stderr=Join-Path $report 'stderr.log'
Write-Host "B3 uncapped mixed-LOD GPU runner=$env:RUNNER_NAME"
$p=Start-Process -FilePath $exe -WorkingDirectory $runtime -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    if (-not $p.WaitForExit(80000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw '45s GPU route timed out' }
    $p.Refresh()
    if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) { throw "B3 exited $($p.ExitCode)" }
    if (-not (Test-Path $env:SANDBOX_B2_CAPTURE_PATH) -or (Get-Item $env:SANDBOX_B2_CAPTURE_PATH).Length -lt 2000) { throw 'Missing 1080p GPU screenshot' }
    $log=(Get-Content -LiteralPath $stderr -Raw) -replace '\x1b\[[0-9;]*m',''
    if ($log -match '(?m)\bERROR\b|Validation Error|panicked') { throw 'Render/runtime error' }
    if ($log -notmatch 'NVIDIA GeForce GTX 1050 Ti') { throw 'Dedicated NVIDIA GPU not confirmed' }
    $culture=[System.Globalization.CultureInfo]::InvariantCulture
    $samples=New-Object System.Collections.Generic.List[object]
    $coverage=New-Object System.Collections.Generic.List[object]
    foreach($line in ($log -split '[\r\n]+')) {
        if ($line -notmatch '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)') { continue }
        $timestamp=[DateTimeOffset]::Parse($Matches[1],$culture)
        if ($line -match 'bevy_diagnostic: frame_time\s+:\s+([0-9.]+)ms') {
            $value=[double]::Parse($Matches[1],$culture)
            $samples.Add([pscustomobject]@{Time=$timestamp; FrameMs=$value})
        }
        if ($line -match 'B3 horizon coverage') {
            if ($line -notmatch '\bx=(-?[0-9.]+)') { throw 'B3 missing position field' }
            $x=[double]::Parse($Matches[1],$culture)
            if ($line -notmatch '\bmissing=(\d+)') { throw 'B3 missing coverage field' }
            $missing=[int]$Matches[1]
            $levels=@()
            foreach($name in @('lod0','lod1','lod2','seam_blocks','transition_commits')) {
                if ($line -notmatch ("\b"+$name+"=(\d+)")) { throw "B3 missing $name" }
                $levels+=([int]$Matches[1])
            }
            $coverage.Add([pscustomobject]@{Time=$timestamp; X=$x; Missing=$missing; LOD0=$levels[0]; LOD1=$levels[1]; LOD2=$levels[2]; Seams=$levels[3]; Commits=$levels[4]})
        }
    }
    if ($coverage.Count -lt 20 -or $samples.Count -lt 20) { throw "Insufficient telemetry, coverage=$($coverage.Count) frame=$($samples.Count)" }
    $initialX=$coverage[0].X
    $firstMotion=@($coverage | Where-Object { [Math]::Abs($_.X-$initialX) -gt 0.25 } | Select-Object -First 1)
    if ($firstMotion.Count -eq 0) { throw 'No real motion detected' }
    $start=$firstMotion[0].Time
    $moving=@($coverage | Where-Object {$_.Time -ge $start})
    $movingFrames=@($samples | Where-Object {$_.Time -ge $start})
    if ($moving.Count -lt 20 -or $movingFrames.Count -lt 20) { throw 'Insufficient moving samples' }
    $miss=@($moving | Where-Object { $_.Missing -gt 0 }).Count
    $three=@($moving | Where-Object { $_.LOD0 -gt 0 -and $_.LOD1 -gt 0 -and $_.LOD2 -gt 0 -and $_.Seams -gt 0 }).Count
    $frames=@($movingFrames | ForEach-Object { $_.FrameMs } | Sort-Object)
    $n=$frames.Count
    $min=$frames[0]
    $max=$frames[$n-1]
    $mean=($frames | Measure-Object -Average).Average
    $p95=$frames[[Math]::Ceiling($n*0.95)-1]
    $p99=$frames[[Math]::Ceiling($n*0.99)-1]
    $over=@($frames | Where-Object { $_ -gt 16.7 }).Count
    $distance=$coverage[$coverage.Count-1].X-$initialX
    $maxCommits=($coverage | Measure-Object -Property Commits -Maximum).Maximum
    $movingFrames | Export-Csv -Path (Join-Path $report 'moving-frames.csv') -NoTypeInformation -Encoding UTF8
    $coverage | Export-Csv -Path (Join-Path $report 'coverage.csv') -NoTypeInformation -Encoding UTF8
    @(
      "runner=$env:RUNNER_NAME"
      "gpu=NVIDIA GeForce GTX 1050 Ti"
      "mode=1080p uncapped Vulkan mixed-LOD headless"
      "moving_frames=$n"
      "frame_ms_mean=$mean"
      "frame_ms_p95=$p95"
      "frame_ms_p99=$p99"
      "frame_ms_max=$max"
      "moving_frames_over_16_7_ms=$over"
      "missing_130m=$miss"
      "mixed_lod_samples=$three"
      "transition_commits=$maxCommits"
      "distance_m=$distance"
      "interactive_present_qualified=false"
    ) | Set-Content -Path (Join-Path $report 'summary.txt')
    Get-Content (Join-Path $report 'summary.txt') | ForEach-Object { Write-Host $_ }
    if ($distance -lt 500 -or $miss -gt 0 -or $three -lt 3 -or $maxCommits -lt 1) { throw 'B3 LOD or coverage gate failure' }
    if ($max -gt 16.7) { throw "B3 uncapped compute workload exceeds strict budget: $max ms" }
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
