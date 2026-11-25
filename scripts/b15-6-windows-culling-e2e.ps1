# B15.6 essential end-to-end comparison: fixed B15.5 slabs in BOTH Vulkan arms.
# The sole difference is conservative AABB-based terrain frustum culling.
# No PresentMon, FFmpeg, desktop session or human input required.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$out = Join-Path $root 'b15-6-evidence'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$env:SANDBOX_B15_5_FIXED_SLABS = '1'
$env:SANDBOX_B15_1_STABLE_SLABS = '1'
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '1'
$env:SANDBOX_B15_1_ROUTE = 'survey'
$env:SANDBOX_B15_2_EDIT_ATOMIC = '1'
$env:SANDBOX_B15_2_FAR_FIELD = '1'
$env:SANDBOX_B15_4_CORRELATE = '1'
$env:SANDBOX_B15_5_CAPTURE_TIMES = '12,35,46'
$ci = [Globalization.CultureInfo]::InvariantCulture
$arms = @(
    @{ Name='b15_5_fixed_slab_unculled_reference'; Cull='0' },
    @{ Name='b15_6_fixed_slab_conservative_culling'; Cull='1' }
)
$results = @()
foreach ($arm in $arms) {
    $env:SANDBOX_B15_6_CONSERVATIVE_CULLING = $arm.Cull
    $base = Join-Path $root 'b14-evidence'
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    Write-Host "B15_6_E2E_ARM_START name=$($arm.Name) conservative_culling=$($arm.Cull)"
    & (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
    $dest = Join-Path $out $arm.Name
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $base -Destination $dest
    $log = (Get-Content -LiteralPath (Join-Path $dest 'stderr.log') -Raw) -replace '\x1b\[[0-9;]*m',''
    $frames = @(Import-Csv -LiteralPath (Join-Path $dest 'trace\b14-frames.csv'))
    $costs = @(Import-Csv -LiteralPath (Join-Path $dest 'trace\b15-4-costs.csv'))
    $screens = @(Get-ChildItem -LiteralPath $dest -Filter 'b14-??.png' -File)
    if ($frames.Count -lt 1800 -or $costs.Count -ne $frames.Count -or $screens.Count -ne 3) {
        throw "B15_6_E2E_INCOMPLETE arm=$($arm.Name) b14=$($frames.Count) cost=$($costs.Count) screenshots=$($screens.Count)"
    }
    $cullLog = $log -match 'B15\.6 conservative GPU terrain frustum culling enabled'
    if ($cullLog -ne ($arm.Cull -eq '1')) {
        throw "B15_6_MODE_MISMATCH arm=$($arm.Name) culling_logged=$cullLog"
    }
    if ($log -notmatch 'B15\.5 fixed GPU mesh slabs enabled') {
        throw "B15_6_MISSING_FIXED_SLABS arm=$($arm.Name)"
    }
    $relocations = ([regex]::Matches($log, 'B15\.1 GPU relocated live meshes prioritized')).Count
    $runtimeErrors = ([regex]::Matches($log, '(?i)\bERROR\b|Validation Error|panicked')).Count
    $edits = ([regex]::Matches($log, 'B15\.1 scripted edit requested')).Count
    $publications = ([regex]::Matches($log, 'B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication')).Count
    $latencies = @()
    foreach ($m in [regex]::Matches($log, '(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')) {
        $latencies += [double]::Parse($m.Groups[1].Value,$ci)
    }
    $frameGaps = @()
    $selected = @()
    $published = @()
    $missing = 0
    $invalidLod = 0
    $lastFrame = $null
    foreach ($frame in $frames) {
        $t = [double]::Parse($frame.game_t_s,$ci)
        if ($t -ge 20.0 -and $t -lt 44.0) {
            if ([int]$frame.missing -gt 0) { $missing += 1 }
            $selected += [int]$frame.view_selected
            $published += [int]$frame.logical_visible
            if ($lastFrame -ne $null) {
                $gap = [long]$frame.unix_ms - [long]$lastFrame
                if ($gap -ge 0 -and $gap -lt 2000) { $frameGaps += $gap }
            }
        }
        $lastFrame = $frame.unix_ms
    }
    $latestHorizon = @($log -split '[\r\n]+' | Where-Object { $_ -match 'B3 horizon coverage' } | Select-Object -Last 1)
    if ($latestHorizon.Count -gt 0 -and $latestHorizon[0] -match 'lod_bad_frames=(\d+)') {
        $invalidLod = [int]$Matches[1]
    }
    $ordered = @($frameGaps | Sort-Object)
    $p95 = if ($ordered.Count) { $ordered[[int][Math]::Ceiling(($ordered.Count-1)*0.95)] } else { $null }
    $maxGap = if ($ordered.Count) { $ordered[-1] } else { $null }
    $maxEdit = if ($latencies.Count) { [double](($latencies | Measure-Object -Maximum).Maximum) } else { 0.0 }
    $viewMean = if ($selected.Count) { [Math]::Round([double](($selected | Measure-Object -Average).Average),1) } else { 0.0 }
    $publishedMean = if ($published.Count) { [Math]::Round([double](($published | Measure-Object -Average).Average),1) } else { 0.0 }
    $result = [pscustomobject]@{
        arm = $arm.Name
        conservative_culling = $arm.Cull
        b14_frames = $frames.Count
        gpu_mesh_relocation_events = $relocations
        mean_view_selected_meshes_t20_44 = $viewMean
        mean_logically_published_meshes_t20_44 = $publishedMean
        frame_gap_p95_ms_t20_44 = $p95
        frame_gap_max_ms_t20_44 = $maxGap
        scripted_edits = $edits
        edited_gpu_mesh_publications = $publications
        max_edit_publication_ms = [Math]::Round($maxEdit,3)
        missing_logical_frames_t20_44 = $missing
        lod_bad_frames = $invalidLod
        screenshots = $screens.Count
        runtime_errors = $runtimeErrors
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dest 'B15_6_ARM.json') -Encoding UTF8
    $results += $result
    $result | Format-List | Out-String | Write-Host
    if ($relocations -gt 0 -or $runtimeErrors -gt 0 -or $missing -gt 0 -or $invalidLod -gt 0 -or
        $edits -ne 6 -or $publications -lt 22 -or $maxEdit -gt 100) {
        throw "B15_6_MVP_REGRESSION arm=$($arm.Name) reloc=$relocations errors=$runtimeErrors missing=$missing lod=$invalidLod edits=$edits publications=$publications max_edit=$maxEdit"
    }
}
$control = $results[0]
$candidate = $results[1]
$reduction = if ($control.mean_view_selected_meshes_t20_44 -gt 0) {
    [Math]::Round(100.0 * (1.0 - $candidate.mean_view_selected_meshes_t20_44 / $control.mean_view_selected_meshes_t20_44),1)
} else { 0.0 }
$status = 'B15_6_CONSERVATIVE_CULLING_HEADLESS_E2E_PASS_PRESENT_PENDING'
if ($reduction -lt 25.0) { $status = 'B15_6_CONSERVATIVE_CULLING_NO_MEANINGFUL_DRAW_REDUCTION' }
$summary = [ordered]@{
    status = $status
    view_selected_mesh_reduction_percent = $reduction
    arms = @($results)
    caveat = 'ViewVisibility is a CPU frustum candidate proxy, not a GPU draw-call counter. B14 elapsed wall-clock gaps are not independent display present intervals. Visual screen-space review of the 3 matched PNGs still required.'
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'B15_6_E2E_SUMMARY.json') -Encoding UTF8
Write-Host "B15_6_E2E_STATUS=$status view_selected_reduction_pct=$reduction"
if ($reduction -lt 25.0) { throw 'B15_6_CULLING_NO_MEANINGFUL_DRAW_REDUCTION' }
