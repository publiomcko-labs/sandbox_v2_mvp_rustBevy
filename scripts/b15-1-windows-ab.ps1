# B15.1: matched headless Windows/Vulkan A/B with identical B14 telemetry.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$out = Join-Path $root 'b15-1-evidence'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '1'
$results = @()
foreach ($arm in @('control','stable_slabs','survey')) {
    if ($arm -eq 'stable_slabs' -or $arm -eq 'survey') {
        $env:SANDBOX_B15_1_STABLE_SLABS = '1'
    } else {
        $env:SANDBOX_B15_1_STABLE_SLABS = '0'
    }
    if ($arm -eq 'survey') { $env:SANDBOX_B15_1_ROUTE = 'survey' }
    else { Remove-Item Env:SANDBOX_B15_1_ROUTE -ErrorAction SilentlyContinue }
    $baseline = Join-Path $root 'b14-evidence'
    if (Test-Path -LiteralPath $baseline) { Remove-Item -LiteralPath $baseline -Recurse -Force }
    Write-Host "B15_1_AB_START $arm"
    # Collect both arms even if the known pre-existing seam topology
    # detector fires: evidence must be retained and the final gate will fail.
    $knownSeamViolation = $false
    try {
        & (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
    } catch {
        $errLogPath = Join-Path $baseline 'stderr.log'
        if (-not (Test-Path -LiteralPath $errLogPath)) { throw }
        $errLog = (Get-Content -LiteralPath $errLogPath -Raw) -replace '\x1b\[[0-9;]*m',''
        $runtimeErrors = @($errLog -split '[\r\n]+' | Where-Object {
            $_ -match '(?i)\bERROR\b|Validation Error|panicked'
        })
        $unknownErrors = @($runtimeErrors | Where-Object {
            $_ -notmatch 'B8 published mixed LOD seam topology violation'
        })
        if ($runtimeErrors.Count -eq 0 -or $unknownErrors.Count -gt 0) { throw }
        $knownSeamViolation = $true
        Write-Warning "B15.1 captured known LOD seam topology violation in $arm; continue for A/B evidence"
    }
    if (-not (Test-Path -LiteralPath $baseline -PathType Container)) {
        throw "Missing B14 evidence for $arm"
    }
    $dest = Join-Path $out $arm
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $baseline -Destination $dest
    $log = (Get-Content -LiteralPath (Join-Path $dest 'stderr.log') -Raw) -replace '\x1b\[[0-9;]*m',''
    $scripted = [regex]::Matches($log, 'B15\.1 scripted edit requested').Count
    $published = [regex]::Matches($log, 'B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication').Count
    $repairGroups = [regex]::Matches($log, 'B15\.1 GPU relocated live meshes prioritized[^\r\n]*relocations=(\d+)')
    $relocations = 0
    foreach ($match in $repairGroups) { $relocations += [int]$match.Groups[1].Value }
    $seamErrors = [regex]::Matches($log, 'B8 published mixed LOD seam topology violation').Count
    $latencyMatches = [regex]::Matches($log, '(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')
    $latencies = @($latencyMatches | ForEach-Object {
        [double]::Parse($_.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    })
    $maxLatency = 0.0
    $slowEdits = 0
    foreach ($l in $latencies) {
        if ($l -gt $maxLatency) { $maxLatency = $l }
        if ($l -gt 100.0) { $slowEdits += 1 }
    }
    $frames = @(Import-Csv -LiteralPath (Join-Path $dest 'trace\b14-frames.csv'))
    $after20 = @($frames | Where-Object {
        [double]::Parse($_.game_t_s, [Globalization.CultureInfo]::InvariantCulture) -ge 20 -and [int]$_.missing -gt 0
    }).Count
    $finalLog = @($log -split '[\r\n]+' | Where-Object { $_ -match 'B3 horizon coverage' } | Select-Object -Last 1)
    $lastHorizon = $null
    if ($finalLog.Count -gt 0) { $lastHorizon = $finalLog[0] }
    $lodBadFrames = 0
    if ($lastHorizon -match 'lod_bad_frames=(\d+)') { $lodBadFrames = [int]$Matches[1] }
    $result = [ordered]@{
        arm = $arm
        scripted_edits = $scripted
        edited_block_publications = $published
        slow_edits_over100ms = $slowEdits
        max_edit_publication_ms = [math]::Round($maxLatency, 2)
        relocated_gpu_meshes = $relocations
        seam_runtime_errors = $seamErrors
        lod_bad_frames = $lodBadFrames
        known_lod_seam_exception = $knownSeamViolation
        logical_frames = $frames.Count
        missing_logical_after20 = $after20
        final_horizon_log = $lastHorizon
    }
    $results += [pscustomobject]$result
    $result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dest 'B15_1_ARM.json') -Encoding UTF8
    $result | Format-List | Out-String | Write-Host
    if ($scripted -ne 6) { throw "B15.1 expected six scripted edits in $arm, found $scripted" }
    if ($published -lt 6) { throw "B15.1 edited mesh publication incomplete for ${arm}: $published" }
    if ($frames.Count -lt 1000) { throw "B15.1 per-frame audit missing in $arm" }
}
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'B15_1_AB_SUMMARY.json') -Encoding UTF8
if (@($results | Where-Object { $_.seam_runtime_errors -gt 0 -or $_.lod_bad_frames -gt 0 }).Count -gt 0) {
    throw 'B15_1_LOD_SEAM_HOLD: artifacts complete, seam topology violation remains'
}
if (@($results | Where-Object { $_.slow_edits_over100ms -gt 0 }).Count -gt 0) {
    throw 'B15_1_EDIT_LATENCY_HOLD: at least one publication exceeded 100 ms'
}
Write-Host 'B15_1_WINDOWS_VULKAN_AB_SURVEY_PASS_VISUAL_REVIEW_PENDING'
