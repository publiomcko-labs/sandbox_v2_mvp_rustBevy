# B15.2: A/B/C all use the same Vulkan code, scripted edits and B14 audit.
# Only the edit-cohort fix and the B11 visual shell switch vary.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$out = Join-Path $root 'b15-2-evidence'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '1'
$env:SANDBOX_B15_1_STABLE_SLABS = '1'
$env:SANDBOX_B15_1_ROUTE = 'survey'
$results = @()
$failures = @()
$arms = @(
    @{ Name='b15_1_edit_control'; Atomic='0'; Far='1' },
    @{ Name='b15_2_atomic_shell_on'; Atomic='1'; Far='1' },
    @{ Name='b15_2_atomic_shell_off'; Atomic='1'; Far='0' }
)
foreach ($arm in $arms) {
    $name = $arm.Name
    $env:SANDBOX_B15_2_EDIT_ATOMIC = $arm.Atomic
    $env:SANDBOX_B15_2_FAR_FIELD = $arm.Far
    $base = Join-Path $root 'b14-evidence'
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    Write-Host "B15_2_RUN_START name=$name atomic=$($arm.Atomic) shell=$($arm.Far)"
    $exceptionText = ''
    try {
        & (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
    } catch {
        $exceptionText = $_.Exception.Message
        Write-Warning "B15.2 arm $name has a B14 prerequisite failure: $exceptionText"
    }
    $dest = Join-Path $out $name
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    if (-not (Test-Path -LiteralPath $base)) {
        $failures += "$name missing B14 raw evidence"
        continue
    }
    Move-Item -LiteralPath $base -Destination $dest
    $logPath = Join-Path $dest 'stderr.log'
    $framesPath = Join-Path $dest 'trace\b14-frames.csv'
    $eventsPath = Join-Path $dest 'trace\b14-mesh-events.csv'
    if (-not (Test-Path $logPath) -or -not (Test-Path $framesPath) -or -not (Test-Path $eventsPath)) {
        $failures += "$name missing logs or telemetry"
        continue
    }
    $log = (Get-Content -LiteralPath $logPath -Raw) -replace '\x1b\[[0-9;]*m',''
    $frames = @(Import-Csv -LiteralPath $framesPath)
    $events = @(Import-Csv -LiteralPath $eventsPath)
    $c = [Globalization.CultureInfo]::InvariantCulture
    $missing = @($frames | Where-Object {
        [double]::Parse($_.game_t_s, $c) -ge 20.0 -and [int]$_.missing -gt 0
    }).Count
    $images = @(Get-ChildItem -LiteralPath $dest -Filter 'b14-??.png' -File)
    $edits = [regex]::Matches($log, 'B15\.1 scripted edit requested').Count
    $cohorts = [regex]::Matches($log, 'B15\.2 edit and seam cohort queued atomically').Count
    $seamRepairs = [regex]::Matches($log, 'B15\.1 stale LOD seam metadata queued for coherent regeneration').Count
    $shellRevisions = [regex]::Matches($log, 'B11 far field coverage built').Count
    $errors = [regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked').Count
    $published = [regex]::Matches($log,'B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication').Count
    $latMatches = [regex]::Matches($log, '(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')
    $maxLatency = 0.0
    $slowEdits = 0
    foreach ($match in $latMatches) {
        $lat = [double]::Parse($match.Groups[1].Value, $c)
        if ($lat -gt $maxLatency) { $maxLatency = $lat }
        if ($lat -gt 100.0) { $slowEdits += 1 }
    }
    $relocationMatches = [regex]::Matches($log,'B15\.1 GPU relocated live meshes prioritized[^\r\n]*relocations=(\d+)')
    $relocations = 0
    foreach ($match in $relocationMatches) { $relocations += [int]$match.Groups[1].Value }
    $lastHorizon = @($log -split '[\r\n]+' | Where-Object { $_ -match 'B3 horizon coverage' } | Select-Object -Last 1)
    $lodBad = 0
    $afterEditRepairs = 0
    $cohortBlocks = 0
    $cancelledLod = 0
    if ($lastHorizon.Count -gt 0) {
        if ($lastHorizon[0] -match 'lod_bad_frames=(\d+)') { $lodBad = [int]$Matches[1] }
        if ($lastHorizon[0] -match 'b15_2_post_edit_repair_blocks=(\d+)') { $afterEditRepairs = [int]$Matches[1] }
        if ($lastHorizon[0] -match 'b15_2_edit_cohort_blocks=(\d+)') { $cohortBlocks = [int]$Matches[1] }
        if ($lastHorizon[0] -match 'b15_2_cancelled_lod_jobs=(\d+)') { $cancelledLod = [int]$Matches[1] }
    }
    $result = [pscustomobject]@{
        arm = $name
        atomic_edit = $arm.Atomic
        far_shell = $arm.Far
        edited = $edits
        edited_mesh_publications = $published
        atomic_edit_cohorts = $cohorts
        atomic_cohort_blocks = $cohortBlocks
        cancelled_lod_jobs = $cancelledLod
        stale_seam_reconciliation_events = $seamRepairs
        post_edit_seam_repair_blocks = $afterEditRepairs
        far_shell_updates = $shellRevisions
        gpu_relocations = $relocations
        max_edit_publication_ms = [math]::Round($maxLatency, 3)
        edits_above_100ms = $slowEdits
        bad_lod_frames = $lodBad
        missing_logical_after20 = $missing
        frame_rows = $frames.Count
        mesh_event_rows = $events.Count
        vulkan_or_runtime_errors = $errors
        screenshots = $images.Count
        prerequisite_error = $exceptionText
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dest 'B15_2_ARM.json') -Encoding UTF8
    $results += $result
    $result | Format-List | Out-String | Write-Host
    if ($exceptionText -ne '') { $failures += "$name B14 prerequisite: $exceptionText" }
    if ($frames.Count -lt 1000 -or $images.Count -ne 3 -or $edits -ne 6) {
        $failures += "$name incomplete trace/screenshot/six-edit evidence"
    }
    if (@($images | Where-Object { $_.Length -lt 3000 }).Count -gt 0) {
        $failures += "$name empty captured image"
    }
    if ($missing -gt 0 -or $lodBad -gt 0 -or $errors -gt 0) {
        $failures += "$name coverage, LOD or runtime regression"
    }
    if ($slowEdits -gt 0) { $failures += "$name edit publication >100ms" }
    if ($arm.Atomic -eq '1' -and $cohorts -lt 6) {
        $failures += "$name edit cohort transactions not demonstrated"
    }
    if ($arm.Far -eq '0' -and $shellRevisions -ne 0) {
        $failures += "$name far shell remained active"
    }
    if ($arm.Far -eq '1' -and $shellRevisions -lt 1) {
        $failures += "$name far shell unexpectedly inactive"
    }
}
$summary = [ordered]@{
    status = if ($failures.Count -eq 0) { 'B15_2_WINDOWS_VULKAN_MATRIX_PASS_VISUAL_PENDING' } else { 'B15_2_WINDOWS_VULKAN_MATRIX_HOLD' }
    arms = @($results)
    failures = @($failures)
    caveats = @(
        'GPU-ready and MainWorld are not presented pixels',
        'Sparse headless screenshots do not rule out one-frame flicker',
        'Edit timing starts after synchronous journal save',
        'Shell on/off compares rendered coverage, not scene equivalence'
    )
}
$summary | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $out 'B15_2_MATRIX_SUMMARY.json') -Encoding UTF8
if ($failures.Count -gt 0) { throw ($failures -join '; ') }
Write-Host 'B15_2_WINDOWS_VULKAN_MATRIX_PASS_VISUAL_PENDING'
