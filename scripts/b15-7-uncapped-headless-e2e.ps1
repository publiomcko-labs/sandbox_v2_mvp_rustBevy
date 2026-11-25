# B15.7: one focused headless Vulkan execution with schedule sleep disabled.
# Reuse the exact B15.6 binary from successful run 45629673662.
# Compare externally with the already-recorded B15.6 16-ms-scheduler baseline.
# This is NOT a physical display present-time benchmark.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$env:SANDBOX_B3_BENCH_UNCAPPED = '1'
$env:SANDBOX_B15_5_FIXED_SLABS = '1'
$env:SANDBOX_B15_1_STABLE_SLABS = '1'
$env:SANDBOX_B15_6_CONSERVATIVE_CULLING = '1'
$env:SANDBOX_B15_2_EDIT_ATOMIC = '1'
$env:SANDBOX_B15_2_FAR_FIELD = '1'
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '1'
$env:SANDBOX_B15_1_ROUTE = 'survey'
$env:SANDBOX_B15_4_CORRELATE = '1'
$env:SANDBOX_B15_5_CAPTURE_TIMES = '12,35,46'
Write-Host 'B15_7_E2E_START cadence=headless_uncapped identical_b15_6_binary=1'
& (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
$dir = Join-Path $root 'b14-evidence'
$out = Join-Path $root 'b15-7-evidence'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
Move-Item -LiteralPath $dir -Destination $out
$log = (Get-Content -LiteralPath (Join-Path $out 'stderr.log') -Raw) -replace '\x1b\[[0-9;]*m',''
$frames = @(Import-Csv -LiteralPath (Join-Path $out 'trace\b14-frames.csv'))
$costs = @(Import-Csv -LiteralPath (Join-Path $out 'trace\b15-4-costs.csv'))
if ($frames.Count -lt 2500 -or $frames.Count -ne $costs.Count) {
    throw "B15_7_FRAME_TRACE_INCOMPLETE frames=$($frames.Count) costs=$($costs.Count)"
}
foreach ($marker in @('B15.5 fixed GPU mesh slabs enabled','B15.6 conservative GPU terrain frustum culling enabled')) {
    if ($log -notmatch [regex]::Escape($marker)) {
        throw "B15_7_CONFIG_NOT_ACTIVE marker=$marker"
    }
}
$edits = ([regex]::Matches($log,'B15\.1 scripted edit requested')).Count
$published = ([regex]::Matches($log,'B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication')).Count
$relocations = ([regex]::Matches($log,'B15\.1 GPU relocated live meshes prioritized')).Count
$errors = ([regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked')).Count
$latestHorizon = @($log -split '[\r\n]+' | Where-Object { $_ -match 'B3 horizon coverage' } | Select-Object -Last 1)
$badLod = 0
if ($latestHorizon.Count -gt 0 -and $latestHorizon[0] -match 'lod_bad_frames=(\d+)') {
    $badLod = [int]$Matches[1]
}
$ci = [Globalization.CultureInfo]::InvariantCulture
$gaps = @()
$streamUs = @()
$auditUs = @()
$missing = 0
$view = @()
for ($i=1; $i -lt $frames.Count; $i++) {
    $t = [double]::Parse($frames[$i].game_t_s,$ci)
    if ($t -lt 20.0 -or $t -ge 44.0) { continue }
    $delta = [long]$frames[$i].unix_ms - [long]$frames[$i-1].unix_ms
    if ($delta -ge 0 -and $delta -lt 2000) { $gaps += $delta }
    $streamUs += [long]$costs[$i].stream_cpu_us
    $auditUs += [long]$costs[$i].b14_observation_us
    if ([int]$frames[$i].missing -gt 0) { $missing++ }
    $view += [int]$frames[$i].view_selected
}
function Percentile($items, [double]$q) {
    $sorted = @($items | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    return [double]$sorted[[int][Math]::Ceiling(($sorted.Count-1)*$q)]
}
$maxEdit = 0.0
foreach ($m in [regex]::Matches($log,'(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')) {
    $lat = [double]::Parse($m.Groups[1].Value,$ci)
    if ($lat -gt $maxEdit) { $maxEdit = $lat }
}
$summary = [ordered]@{
    status = 'B15_7_UNCAPPED_HEADLESS_E2E_PASS'
    tested_binary = 'b15-6-windows-runtime from GitHub Actions run 45629673662'
    only_change = 'SANDBOX_B3_BENCH_UNCAPPED=1 replaces ScheduleRunner 16ms sleep with Duration::ZERO'
    no_gameplay_code_changes = $true
    frames = $frames.Count
    samples_t20_to44 = $gaps.Count
    b14_frame_gap_p50_ms = Percentile $gaps .5
    b14_frame_gap_p95_ms = Percentile $gaps .95
    b14_frame_gap_p99_ms = Percentile $gaps .99
    b14_frame_gap_max_ms = Percentile $gaps 1.0
    stream_cpu_p95_us = Percentile $streamUs .95
    audit_cpu_p95_us = Percentile $auditUs .95
    mean_frustum_selected_meshes = if ($view.Count -gt 0) { [Math]::Round([double](($view | Measure-Object -Average).Average),1) } else { $null }
    scripted_edits = $edits
    published_edited_meshes = $published
    max_edited_publication_ms = [Math]::Round($maxEdit,3)
    mesh_relocation_events = $relocations
    missing_required_frames = $missing
    bad_lod_frames = $badLod
    runtime_errors = $errors
    caveat = 'Uncapped headless main-world B14 wall-clock gap is NOT independent presented-pixel frame latency, nor a direct measure of GPU occupancy.'
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'B15_7_UNCAPPED_SUMMARY.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 6 | Write-Host
if ($edits -ne 6 -or $published -lt 22 -or $maxEdit -gt 100.0 -or $relocations -ne 0 -or
    $missing -gt 0 -or $badLod -gt 0 -or $errors -gt 0) {
    throw "B15_7_MVP_REGRESSION edits=$edits published=$published latency=$maxEdit missing=$missing lod=$badLod reloc=$relocations errors=$errors"
}
Write-Host 'B15_7_UNCAPPED_E2E_FUNCTIONAL_PASS'
