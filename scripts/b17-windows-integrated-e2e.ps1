# B17: one matched Vulkan pair, B15.5 control vs B15.5 + B15.6 + B16.
# No new capture tools or ETW; existing opt-in features only.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Get-Location).Path
$out=Join-Path $root 'b17-evidence'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$env:SANDBOX_B15_5_FIXED_SLABS='1'
$env:SANDBOX_B15_1_STABLE_SLABS='1'
$env:SANDBOX_B3_BENCH_UNCAPPED='0'
$env:SANDBOX_B15_1_SCRIPTED_EDITS='1'
$env:SANDBOX_B15_1_ROUTE='survey'
$env:SANDBOX_B15_2_EDIT_ATOMIC='1'
$env:SANDBOX_B15_2_FAR_FIELD='1'
$env:SANDBOX_B15_4_CORRELATE='1'
$env:SANDBOX_B15_5_CAPTURE_TIMES='12,35,46'
$ci=[Globalization.CultureInfo]::InvariantCulture
$results=@()
foreach($arm in @(@{name='b15_5_control';async='0';cull='0'},@{name='b17_integrated';async='1';cull='1'})) {
    $env:SANDBOX_B16_ASYNC_FAR_SHELL=$arm.async
    $env:SANDBOX_B15_6_CONSERVATIVE_CULLING=$arm.cull
    $base=Join-Path $root 'b14-evidence'
    if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}
    Write-Host "B17_E2E_START arm=$($arm.name) async=$($arm.async) cull=$($arm.cull)"
    & (Join-Path $PSScriptRoot 'b14-headless-visibility-smoke.ps1')
    $dest=Join-Path $out $arm.name
    if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Recurse -Force}
    Move-Item -LiteralPath $base -Destination $dest
    $log=(Get-Content -LiteralPath (Join-Path $dest 'stderr.log') -Raw) -replace '\x1b\[[0-9;]*m',''
    $frames=@(Import-Csv -LiteralPath (Join-Path $dest 'trace\b14-frames.csv'))
    $costs=@(Import-Csv -LiteralPath (Join-Path $dest 'trace\b15-4-costs.csv'))
    $screens=@(Get-ChildItem -LiteralPath $dest -Filter 'b14-??.png' -File)
    if($frames.Count -lt 1750 -or $costs.Count -ne $frames.Count -or $screens.Count -ne 3){
        throw "B16_INCOMPLETE arm=$($arm.name) frames=$($frames.Count) costs=$($costs.Count) images=$($screens.Count)"
    }
    if($log -notmatch 'B15\.5 fixed GPU mesh slabs enabled'){throw "B16_B15_5_FLAG_MISSING arm=$($arm.name)"}
    $cullLog=$log -match 'B15\.6 conservative GPU terrain frustum culling enabled'
    if($cullLog -ne ($arm.cull -eq '1')){throw "B17_CULL_MODE_MISMATCH arm=$($arm.name)"}
    $asyncScheduled=([regex]::Matches($log,'B16 async far shell generation scheduled')).Count
    $asyncReady=([regex]::Matches($log,'B16 far shell async geometry produced')).Count
    if(($arm.async -eq '1' -and ($asyncScheduled -lt 1 -or $asyncReady -lt 1)) -or ($arm.async -eq '0' -and ($asyncScheduled -ne 0 -or $asyncReady -ne 0))){
        throw "B16_MODE_MISMATCH arm=$($arm.name) queued=$asyncScheduled ready=$asyncReady"
    }
    $shellUs=@()
    foreach($m in [regex]::Matches($log,'B11 far field coverage built[^\r\n]*build_us=(\d+)')){
        $shellUs += [long]$m.Groups[1].Value
    }
    $shellReady=([regex]::Matches($log,'B11 far field coverage built')).Count
    $workerUs=@()
    foreach($m in [regex]::Matches($log,'B16 far shell async geometry produced[^\r\n]*worker_compute_us=(\d+)')){
        $workerUs += [long]$m.Groups[1].Value
    }
    $perUpdate=@($shellUs | Select-Object -Skip 1)
    $ordered=@($perUpdate | Sort-Object)
    $shellP95=if($ordered.Count){[long]$ordered[[int][Math]::Ceiling(($ordered.Count-1)*0.95)]}else{$null}
    $maxPub=0.0
    $latencyCount=0
    foreach($m in [regex]::Matches($log,'(?:B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication)[^\r\n]*latency_ms=([0-9.]+)')){
        $latencyCount++
        $v=[double]::Parse($m.Groups[1].Value,$ci)
        if($v -gt $maxPub){$maxPub=$v}
    }
    $gaps=@()
    $missing=0
    $selected=@()
    $published=@()
    for($i=1;$i -lt $frames.Count;$i++){
        $t=[double]::Parse($frames[$i].game_t_s,$ci)
        if($t -lt 20 -or $t -ge 44){continue}
        $selected += [int]$frames[$i].view_selected
        $published += [int]$frames[$i].logical_visible
        $d=[long]$frames[$i].unix_ms - [long]$frames[$i-1].unix_ms
        if($d -ge 0 -and $d -lt 2000){$gaps += $d}
        if([int]$frames[$i].missing -gt 0){$missing++}
    }
    $sortedGaps=@($gaps|Sort-Object)
    $gapP95=if($sortedGaps.Count){[long]$sortedGaps[[int][Math]::Ceiling(($sortedGaps.Count-1)*0.95)]}else{$null}
    $gapMax=if($sortedGaps.Count){[long]$sortedGaps[-1]}else{$null}
    $lastHorizon=@($log -split '[\r\n]+'|Where-Object{$_ -match 'B3 horizon coverage'}|Select-Object -Last 1)
    if($lastHorizon.Count -eq 0 -or $lastHorizon[0] -notmatch 'lod_bad_frames=(\d+)'){throw 'B17_LOD_AUDIT_MISSING'}
    $badLod=[int]$Matches[1]
    $edits=([regex]::Matches($log,'B15\.1 scripted edit requested')).Count
    $pubs=([regex]::Matches($log,'B4 revised GPU mesh ready for publication|B15\.1 new edited GPU chunk ready for publication')).Count
    $errors=([regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked')).Count
    $relocations=([regex]::Matches($log,'B15\.1 GPU relocated live meshes prioritized')).Count
    if($selected.Count -eq 0 -or $gaps.Count -eq 0 -or $perUpdate.Count -lt 2 -or $latencyCount -ne $pubs){throw "B17_INCOMPLETE_METRICS arm=$($arm.name)"}
    $viewMean=[math]::Round([double](($selected|Measure-Object -Average).Average),1)
    $publishedMean=[math]::Round([double](($published|Measure-Object -Average).Average),1)
    if($publishedMean -le 0 -or $viewMean -le 0){throw 'B17_EMPTY_VISIBILITY'}
    $result=[pscustomobject]@{
        arm=$arm.name
        async_flag=$arm.async
        culling_flag=$arm.cull
        mean_view_selected_meshes_t20_44=$viewMean
        mean_logically_published_meshes_t20_44=$publishedMean
        frames=$frames.Count
        shell_builds_published=$shellReady
        shell_rebuilds_after_first=$perUpdate.Count
        shell_main_thread_rebuild_p95_us=$shellP95
        async_jobs_scheduled=$asyncScheduled
        async_jobs_ready=$asyncReady
        async_worker_compute_mean_us=if($workerUs.Count){[math]::Round([double](($workerUs|Measure-Object -Average).Average),1)}else{$null}
        b14_frame_gap_p95_ms_t20_44=$gapP95
        b14_frame_gap_max_ms_t20_44=$gapMax
        scripted_edits=$edits
        published_edited_meshes=$pubs
        max_edit_publication_ms=[math]::Round($maxPub,3)
        missing_required_frames=$missing
        bad_lod_frames=$badLod
        gpu_relocation_events=$relocations
        runtime_errors=$errors
        screenshots=$screens.Count
    }
    $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $dest 'B17_ARM.json') -Encoding UTF8
    $results += $result
    $result|Format-List|Out-String|Write-Host
    if($shellReady -lt 3 -or $edits -ne 6 -or $pubs -lt 22 -or $maxPub -gt 100 -or $missing -gt 0 -or $badLod -gt 0 -or $relocations -ne 0 -or $errors -ne 0){
        throw "B17_FUNCTIONAL_REGRESSION arm=$($arm.name) shell=$shellReady edits=$edits pubs=$pubs latency=$maxPub missing=$missing lod=$badLod reloc=$relocations errors=$errors"
    }
}
$control=$results[0]
$candidate=$results[1]
$reduction=if($control.shell_main_thread_rebuild_p95_us -gt 0){
    [math]::Round(100.0*(1.0-$candidate.shell_main_thread_rebuild_p95_us/$control.shell_main_thread_rebuild_p95_us),1)
}else{0}
$cullReduction=[math]::Round(100.0*(1.0-$candidate.mean_view_selected_meshes_t20_44/$control.mean_view_selected_meshes_t20_44),1)
$status='B17_INTEGRATED_VULKAN_E2E_PASS_VISUAL_PENDING'
if($reduction -lt 40 -or $cullReduction -lt 25){$status='B17_INTEGRATED_GAIN_NOT_PROVEN'}
$summary=[ordered]@{
    status=$status
    shell_main_thread_rebuild_p95_reduction_pct=$reduction
    view_selected_mesh_reduction_pct=$cullReduction
    arms=@($results)
    caveat='Matched 1920x1080 GPU-headless 18m/s survey, six edits, fixed slabs in both arms. ViewVisibility is a proxy, B14 intervals are not physical display present timing. Interactive visual acceptance pending.'
}
$summary|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $out 'B17_E2E_SUMMARY.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 6|Write-Host
if($status -ne 'B17_INTEGRATED_VULKAN_E2E_PASS_VISUAL_PENDING'){throw $status}
Write-Host $status
