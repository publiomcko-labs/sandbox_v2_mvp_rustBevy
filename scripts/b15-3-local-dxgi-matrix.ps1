# B15.3: matched 120s/120s DXGI+NVENC interactive desktop capture.
# Each automated arm uses the same Vulkan executable, 18m/s route, six
# scripted SDF edits, B14 trace and independent persisted world state.
param(
    [string]$AppDir = 'C:\Dev\sandbox-b15-2-local\app',
    [string]$OutputRoot = 'C:\Dev\sandbox-b15-2-local\captures',
    [ValidateRange(15,300)][int]$DurationSeconds = 120,
    [ValidateRange(24,60)][int]$Fps = 60,
    [ValidateRange(0,16)][int]$DxgiOutputIdx = 0,
    [switch]$ContractTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function ConvertTo-B15_3PlainLog {
    param([string]$Text)
    # Rust tracing inserts ANSI SGR markers around both keys and equal signs.
    # Regex key=value cannot match until they are stripped.
    return ($Text -replace '\x1b\[[0-9;]*m', '')
}
if ($ContractTest) {
    $esc = [char]27
    $fixture = "B4 revised GPU mesh ready for publication latency_ms${esc}[0m=${esc}[0m42.5264" +
        "`nB3 horizon coverage lod_bad_frames${esc}[0m=${esc}[0m0 b15_2_cancelled_lod_jobs${esc}[0m=${esc}[0m24 b15_2_post_edit_repair_blocks${esc}[0m=${esc}[0m20"
    $plain = ConvertTo-B15_3PlainLog -Text $fixture
    $lat = [regex]::Matches($plain,
        'B4 revised GPU mesh ready for publication[^\r\n]*latency_ms=([0-9.]+)')
    $repair = [regex]::Match($plain,'b15_2_post_edit_repair_blocks=(\d+)')
    $canceled = [regex]::Match($plain,'b15_2_cancelled_lod_jobs=(\d+)')
    if ($lat.Count -ne 1 -or $lat[0].Groups[1].Value -ne '42.5264' -or
        -not $repair.Success -or $repair.Groups[1].Value -ne '20' -or
        -not $canceled.Success -or $canceled.Groups[1].Value -ne '24') {
        throw 'B15_3_ANSI_LOG_PARSER_CONTRACT_FAILED'
    }
    Write-Host 'B15_3_ANSI_LOG_PARSER_CONTRACT_PASS latency=42.5264 post_edit_repairs=20 cancelled=24'
    return
}
$runner = Join-Path $PSScriptRoot 'b15-2-local-60fps.ps1'
if (-not (Test-Path -LiteralPath $runner)) { throw "Missing $runner" }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$started = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
$results = @()
$arms = @(
    @{ Name = 'atomic_shell_on'; Far = '1' },
    @{ Name = 'atomic_shell_off'; Far = '0' }
)
$inv = [Globalization.CultureInfo]::InvariantCulture
foreach ($arm in $arms) {
    $name = $arm.Name
    $far = $arm.Far
    Write-Host "B15_3_ARM_BEGIN name=$name duration=$DurationSeconds fps=$Fps"
    # New capture session and new B4/B5 save files each arm.
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$runner" `
        -AppDir $AppDir -OutputRoot $OutputRoot -Mode Auto `
        -DurationSeconds $DurationSeconds -Fps $Fps `
        -FarShell $far -AtomicEdits 1 -Encoder Nvenc `
        -CaptureBackend Dxgi -DxgiOutputIdx $DxgiOutputIdx
    if ($LASTEXITCODE -ne 0) {
        throw "B15_3_ARM_FAILED name=$name exit=$LASTEXITCODE. Inspect latest session logs under $OutputRoot"
    }
    $prefix = "b15-2-Auto-shell$far-atomic1-"
    $matches = @(Get-ChildItem -LiteralPath $OutputRoot -Directory |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($matches.Count -eq 0) {
        throw "B15_3_NO_CAPTURE_SESSION arm=$name"
    }
    $session = $matches[0].FullName
    $metaPath = Join-Path $session 'b15-2-recording.json'
    $gameLog = Join-Path $session 'game.stderr.log'
    $framesPath = Join-Path $session 'trace\b14-frames.csv'
    $videoPath = Join-Path $session 'game-window-60fps.mp4'
    if (-not (Test-Path $metaPath) -or -not (Test-Path $gameLog) -or
        -not (Test-Path $framesPath) -or -not (Test-Path $videoPath)) {
        throw "B15_3_INCOMPLETE_EVIDENCE arm=$name session=$session"
    }
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if ($meta.capture_backend -ne 'Dxgi' -or $meta.video_encoder -ne 'Nvenc' -or
        "$($meta.far_shell)" -ne $far -or $meta.mode -ne 'Auto' -or
        "$($meta.atomic_edits)" -ne '1') {
        throw "B15_3_METADATA_MISMATCH arm=$name session=$session"
    }
    $log = ConvertTo-B15_3PlainLog -Text (Get-Content -LiteralPath $gameLog -Raw)
    $rows = @(Import-Csv -LiteralPath $framesPath)
    $missingAfter20 = @($rows | Where-Object {
        [double]::Parse($_.game_t_s,$inv) -ge 20.0 -and [int]$_.missing -gt 0
    }).Count
    $edits = [regex]::Matches($log,'B15\.1 scripted edit requested').Count
    $cohorts = [regex]::Matches($log,'B15\.2 edit and seam cohort queued atomically').Count
    $shellUpdates = [regex]::Matches($log,'B11 far field coverage built').Count
    $errorCount = [regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked').Count
    $latencyMatches = [regex]::Matches($log,
        '(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')
    $maxEditMs = 0.0
    $editsAbove100ms = 0
    foreach ($m in $latencyMatches) {
        $v = [double]::Parse($m.Groups[1].Value,$inv)
        if ($v -gt $maxEditMs) { $maxEditMs = $v }
        if ($v -gt 100.0) { $editsAbove100ms += 1 }
    }
    $traceIntervals = @()
    for ($i=1; $i -lt $rows.Count; $i++) {
        $dt = [double]$rows[$i].unix_ms - [double]$rows[$i-1].unix_ms
        if ($dt -gt 0) { $traceIntervals += $dt }
    }
    $p95 = 0.0
    if ($traceIntervals.Count -gt 0) {
        $sorted = @($traceIntervals | Sort-Object)
        $at = [int][Math]::Ceiling(0.95 * $sorted.Count) - 1
        $p95 = [Math]::Round($sorted[$at],2)
    }
    $lodBad = 0
    $postEditSeamRepairBlocks = 0
    $cancelledLodJobs = 0
    $staleSeamEvents = [regex]::Matches($log,'B15\.1 stale LOD seam metadata queued').Count
    $relocations = 0
    foreach ($m in [regex]::Matches($log,
        'B15\.1 GPU relocated live meshes prioritized[^\r\n]*relocations=(\d+)')) {
        $relocations += [int]$m.Groups[1].Value
    }
    $lastHorizon = @($log -split '[\r\n]+' |
        Where-Object { $_ -match 'B3 horizon coverage' } | Select-Object -Last 1)
    if ($lastHorizon.Count -gt 0) {
        if ($lastHorizon[0] -match 'lod_bad_frames=(\d+)') { $lodBad = [int]$Matches[1] }
        if ($lastHorizon[0] -match 'b15_2_cancelled_lod_jobs=(\d+)') {
            $cancelledLodJobs = [int]$Matches[1]
        }
        if ($lastHorizon[0] -match 'b15_2_post_edit_repair_blocks=(\d+)') {
            $postEditSeamRepairBlocks = [int]$Matches[1]
        }
    }
    $reason = @()
    if ($lastHorizon.Count -eq 0) { $reason += 'missing_final_horizon_audit' }
    if ($latencyMatches.Count -eq 0 -and $edits -gt 0) {
        $reason += 'missing_edited_mesh_publications'
    }
    if (-not $meta.video_fps_qualified) { $reason += 'capture_below_50fps' }
    if ($p95 -gt 16.7) { $reason += 'game_frame_interval_p95_above_16_7ms' }
    if ($lodBad -gt 0) { $reason += 'lod_bad_frames' }
    if ($edits -ne 6) { $reason += 'scripted_edits_not_six' }
    if ($cohorts -lt 6) { $reason += 'atomic_cohorts_not_six' }
    if ($missingAfter20 -ne 0) { $reason += 'logical_coverage_missing' }
    if ($errorCount -ne 0) { $reason += 'runtime_error' }
    if ($editsAbove100ms -gt 0) { $reason += 'edit_publication_slow' }
    if ($far -eq '0' -and $shellUpdates -ne 0) { $reason += 'shell_off_not_respected' }
    if ($far -eq '1' -and $shellUpdates -eq 0) { $reason += 'shell_on_not_respected' }
    $result = [pscustomobject]@{
        arm = $name
        session = $session
        archive = "$session.zip"
        capture_backend = $meta.capture_backend
        encoder = $meta.video_encoder
        encoded_fps = $meta.video_encoded_fps
        preflight_pixel_delta = $meta.dynamic_preflight_delta
        b14_frame_rows = $rows.Count
        b14_frame_interval_p95_ms = $p95
        scripted_edits = $edits
        atomic_transactions = $cohorts
        revised_mesh_publications = $latencyMatches.Count
        max_edit_publication_ms = [Math]::Round($maxEditMs,2)
        edit_publications_above_100ms = $editsAbove100ms
        missing_logical_after_20s = $missingAfter20
        lod_bad_frames = $lodBad
        post_edit_seam_repair_blocks = $postEditSeamRepairBlocks
        cancelled_lod_jobs = $cancelledLodJobs
        stale_seam_reconciliation_events = $staleSeamEvents
        gpu_relocations = $relocations
        far_shell_updates = $shellUpdates
        runtime_errors = $errorCount
        status = if ($reason.Count -eq 0) { 'TELEMETRY_PASS_PIXEL_PENDING' } else { 'HOLD' }
        findings = @($reason)
    }
    $results += $result
    $result | Format-List | Out-String | Write-Host
}
$status = if (@($results | Where-Object { $_.status -eq 'HOLD' }).Count -eq 0) {
    'B15_3_DXGI_MATRIX_TELEMETRY_PASS_PIXEL_PENDING'
} else {
    'B15_3_DXGI_MATRIX_HOLD'
}
$summary = [ordered]@{
    status = $status
    created_utc = [DateTimeOffset]::UtcNow.ToString('o')
    duration_seconds_per_arm = $DurationSeconds
    fps_requested = $Fps
    arms = @($results)
    caveats = @(
        'Actual encoded FPS does not prove distinct on-screen presented frames',
        'B14 frame intervals are game timestamps, not an external presentation oracle',
        'The B11 far shell off arm intentionally has less far visual coverage',
        'Windows DXGI capture may be affected by GPU contention, display index and foreground windows'
    )
}
$summaryPath = Join-Path $OutputRoot "b15-3-dxgi-matrix-$started.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host "B15_3_DXGI_MATRIX_SUMMARY=$summaryPath"
Write-Host $status
