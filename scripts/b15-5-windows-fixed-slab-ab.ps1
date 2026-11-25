# B15.5: one essential matched A/B GPU-headless route, not a broad benchmark suite.
# Fixed-size slab flag is the ONLY code-path difference. Both arms run at
# 1080p with identical B14/B15.4 instrumentation and six scripted SDF edits.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$reportDir = Join-Path $root 'b15-5-evidence'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '1'
$env:SANDBOX_B15_1_STABLE_SLABS = '1'
$env:SANDBOX_B15_1_ROUTE = 'survey'
$env:SANDBOX_B15_2_EDIT_ATOMIC = '1'
$env:SANDBOX_B15_2_FAR_FIELD = '1'
$env:SANDBOX_B15_4_CORRELATE = '1'
$env:SANDBOX_B15_5_CAPTURE_TIMES = '12,35,46'
$results = @()
foreach ($arm in @(
    @{ name='b15_4_growing_slab_control'; fixed='0' },
    @{ name='b15_5_fixed_32mib_candidate'; fixed='1' }
)) {
    $env:SANDBOX_B15_5_FIXED_SLABS = $arm.fixed
    $base = Join-Path $root 'b14-evidence'
    if (Test-Path -LiteralPath $base) {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
    Write-Host "B15_5_ARM_START name=$($arm.name) fixed=$($arm.fixed)"
    & (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
    $dest = Join-Path $reportDir $arm.name
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Move-Item -LiteralPath $base -Destination $dest
    $log = (Get-Content -LiteralPath (Join-Path $dest 'stderr.log') -Raw) -replace '\x1b\[[0-9;]*m',''
    $frames = @(Import-Csv -LiteralPath (Join-Path $dest 'trace\b14-frames.csv'))
    $costs = @(Import-Csv -LiteralPath (Join-Path $dest 'trace\b15-4-costs.csv'))
    if ($frames.Count -lt 1800 -or $costs.Count -ne $frames.Count) {
        throw "B15_5_TRACE_CADENCE_FAILURE arm=$($arm.name) b14=$($frames.Count) cost=$($costs.Count)"
    }
    if ($arm.fixed -eq '1' -and $log -notmatch 'B15.5 fixed GPU mesh slabs enabled') {
        throw 'B15_5_FIXED_SLAB_SETTING_NOT_APPLIED'
    }
    if ($arm.fixed -eq '0' -and $log -match 'B15.5 fixed GPU mesh slabs enabled') {
        throw 'B15_5_CONTROL_HAS_FIXED_SLAB_SETTING'
    }
    $reallocs = 0
    $relocationEvents = 0
    foreach ($line in ($log -split '[\r\n]+')) {
        if ($line -match 'B15\.1 GPU relocated live meshes prioritized') {
            $relocationEvents += 1
            if ($line -match 'relocations=(\d+)') {
                $reallocs += [int]$Matches[1]
            }
        }
    }
    $errors = ([regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked')).Count
    $edits = ([regex]::Matches($log,'B15\.1 scripted edit requested')).Count
    $published = ([regex]::Matches($log,'B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication')).Count
    $latencies = @()
    foreach ($m in [regex]::Matches($log,
        '(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')) {
        $latencies += [double]::Parse($m.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
    }
    $missing = 0
    $frameDelta = @()
    $prev = $null
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $row = $frames[$i]
        $t = [double]::Parse($row.game_t_s,[Globalization.CultureInfo]::InvariantCulture)
        $timestamp = [long]$row.unix_ms
        if ($t -ge 20.0 -and $t -lt 44.0) {
            if ([int]$row.missing -gt 0) { $missing++ }
            if ($prev -ne $null) {
                $gap = $timestamp - [long]$prev
                if ($gap -ge 0 -and $gap -lt 2000) { $frameDelta += $gap }
            }
        }
        $prev = $timestamp
    }
    $ordered = @($frameDelta | Sort-Object)
    $p95 = if ($ordered.Count -gt 0) {
        $ordered[[int][Math]::Ceiling(($ordered.Count-1)*0.95)]
    } else { $null }
    $maxPub = if ($latencies.Count -gt 0) {
        ($latencies | Measure-Object -Maximum).Maximum
    } else { 0.0 }
    $result = [pscustomobject]@{
        arm = $arm.name
        fixed_slabs = $arm.fixed
        b14_frames = $frames.Count
        cost_frames = $costs.Count
        relocations = $reallocs
        relocation_events = $relocationEvents
        scripted_edits = $edits
        edited_mesh_publications = $published
        max_edited_publication_ms = [Math]::Round([double]$maxPub,3)
        missing_logical_between20_44 = $missing
        frame_gap_p95_ms_between20_44 = $p95
        frame_gap_max_ms_between20_44 = if ($ordered.Count -gt 0) { $ordered[-1] } else { $null }
        runtime_errors = $errors
    }
    $result | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $dest 'B15_5_ARM_SUMMARY.json') -Encoding UTF8
    $results += $result
    $result | Format-List | Out-String | Write-Host
    if ($errors -gt 0 -or $missing -gt 0 -or
        $edits -ne 6 -or $published -lt 22 -or $maxPub -gt 100.0) {
        throw "B15_5_MVP_REGRESSION arm=$($arm.name) errors=$errors missing=$missing edits=$edits pub=$published latency_ms=$maxPub"
    }
}
$control = $results[0]
$candidate = $results[1]
$status = 'B15_5_FIXED_SLABS_HEADLESS_PASS_VISUAL_PRESENT_PENDING'
$failures = @()
if ($control.relocations -lt 100) {
    $failures += 'control_did_not_reproduce_mass_relocations'
}
if ($candidate.relocations -ge $control.relocations / 10) {
    $failures += 'candidate_relocations_not_reduced_by_90_percent'
}
if ($failures.Count -gt 0) { $status = 'B15_5_FIXED_SLABS_HOLD' }
$summary = [ordered]@{
    status = $status
    arms = @($results)
    failures = @($failures)
    note = 'Headless Vulkan confirms relocation/coverage/edits only. PresentMon and visual 60FPS certification require interactive desktop; do not promote automatically.'
}
$summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $reportDir 'B15_5_SLAB_COMPARISON.json') -Encoding UTF8
Write-Host "B15_5_MATRIX_STATUS=$status"
if ($failures.Count -gt 0) { throw ($failures -join '; ') }
