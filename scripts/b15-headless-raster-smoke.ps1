# B15: sampled real raster readback + B14 logical telemetry. Headless Session 0.
# Does not claim flicker-free display from sparse screenshots.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$evidence = Join-Path $root 'b15-evidence'
$raster = Join-Path $evidence 'raster'
New-Item -ItemType Directory -Force -Path $raster | Out-Null
$env:SANDBOX_B15_RASTER_DIR = $raster
$env:SANDBOX_B15_START_S = '48'
$env:SANDBOX_B15_END_S = '56'
$env:SANDBOX_B15_INTERVAL_S = '0.25'
& (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
$manifest = Join-Path $raster 'b15-raster.csv'
if (-not (Test-Path -LiteralPath $manifest)) { throw 'B15 raster manifest not generated' }
$records = @(Import-Csv -LiteralPath $manifest)
if ($records.Count -lt 8) { throw "B15 insufficient completed raster samples: $($records.Count)" }
$tracePath = Join-Path $root 'b14-evidence\trace\b14-frames.csv'
$frames = @(Import-Csv -LiteralPath $tracePath)
if ($frames.Count -lt 250) { throw 'B15 missing per-frame logical evidence' }
$first = [double]::Parse($frames[0].game_t_s, [Globalization.CultureInfo]::InvariantCulture)
$last = [double]::Parse($frames[-1].game_t_s, [Globalization.CultureInfo]::InvariantCulture)
$failures = @()
$timestamps = @()
foreach ($entry in $records) {
    $file = Join-Path $raster $entry.file
    if (-not (Test-Path -LiteralPath $file)) {
        $failures += "Missing raster file $($entry.file)"
        continue
    }
    $size = (Get-Item -LiteralPath $file).Length
    if ($size -lt 3000 -or $size -ne [long]$entry.bytes) {
        $failures += "Invalid raster size $($entry.file)"
    }
    $stamp = [double]::Parse($entry.request_game_t_s, [Globalization.CultureInfo]::InvariantCulture)
    if ($stamp -lt $first -or $stamp -gt $last) {
        $failures += "Raster request outside trace $($entry.file)"
    }
    $timestamps += $stamp
}
for ($i = 1; $i -lt $timestamps.Count; $i++) {
    if ($timestamps[$i] -le $timestamps[$i-1]) {
        $failures += 'Non-monotonic B15 raster request times'
    }
}
$start = 48.0
$end = 56.0
if (@($timestamps | Where-Object { $_ -lt ($start - 1) -or $_ -gt ($end + 1) }).Count -gt 0) {
    $failures += 'B15 raster samples outside expected window'
}
$summary = [ordered]@{
    status = if ($failures.Count -eq 0) { 'B15_FRAMEBUFFER_SAMPLING_PASS_VISUAL_CAUSALITY_NOT_QUALIFIED' } else { 'B15_FRAMEBUFFER_SAMPLING_FAIL' }
    test = 'Windows Session 0 headless Vulkan, B11 mixed LOD, 18m/s straight route'
    source = 'B13 functional checkpoint; B14 logical audit; B15 actual GPU framebuffer PNG readback'
    raster_completed = $records.Count
    raster_first_t_s = if ($timestamps.Count) { $timestamps[0] } else { $null }
    raster_last_t_s = if ($timestamps.Count) { $timestamps[-1] } else { $null }
    logical_frame_rows = $frames.Count
    missing_logical_after_20_s = @($frames | Where-Object { [double]::Parse($_.game_t_s, [Globalization.CultureInfo]::InvariantCulture) -ge 20 -and [int]$_.missing -gt 0 }).Count
    warnings = @('Sparse 4 Hz raster samples cannot prove visual continuity at 60 FPS', 'Request time precedes GPU capture/readback by at least one render cycle', 'Logical coverage does not prove triangle/raster correctness')
    failures = $failures
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $evidence 'B15_SUMMARY.json') -Encoding UTF8
$summary | Format-List | Out-String | Write-Host
if ($failures.Count -gt 0) { throw ($failures -join '; ') }
Write-Host 'B15_FRAMEBUFFER_SAMPLING_PASS_VISUAL_REVIEW_PENDING'
