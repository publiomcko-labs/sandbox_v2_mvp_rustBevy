# B8: validate corrected SDF triangle collision, dynamic buoyancy, 130m
# moving continuity, mixed LOD seam ownership and nine actual Vulkan frames.
# Does NOT claim a headless sequence proves an absence of subframe flicker.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Get-Location).Path
$runtime=Join-Path $root 'b8-runtime'
$report=Join-Path $root 'b8-functional-report'
New-Item -ItemType Directory -Force $report | Out-Null
$exe=Join-Path $runtime 'sandbox-game.exe'
if(-not(Test-Path $exe)){throw "B8 Release not found: $exe"}
$env:SANDBOX_STAGE='B8'
$env:SANDBOX_B3_HEADLESS='1'
$env:SANDBOX_B3_ROUTE='straight'
$env:SANDBOX_B3_MIXED_LOD='1'
$env:SANDBOX_B3_RENDER_1080P='1'
$env:SANDBOX_B3_BENCH_UNCAPPED='1'
$env:SANDBOX_B8_CAPTURE_SEQUENCE='1'
$env:SANDBOX_B8_WATER_PROBE='1'
$env:SANDBOX_B4_TEST_BRUSH='1'
$env:SANDBOX_B4_SAVE_PATH=Join-Path $report 'b8-edits.txt'
$env:SANDBOX_B5_SAVE_PATH=Join-Path $report 'b8-rocks.txt'
$env:SANDBOX_B2_CAPTURE_PATH=Join-Path $report 'lod.png'
$env:WGPU_BACKEND='vulkan'
$env:RUST_BACKTRACE='1'
$env:RUST_LOG='info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$stderr=Join-Path $report 'runtime.stderr.log'
$stdout=Join-Path $report 'runtime.stdout.log'
Write-Host "B8 Vulkan functional visual/physics audit on $env:RUNNER_NAME"
$p=Start-Process -FilePath $exe -WorkingDirectory $runtime -PassThru -RedirectStandardError $stderr -RedirectStandardOutput $stdout
$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    while(-not $p.HasExited -and $watch.Elapsed.TotalSeconds -lt 95){
        Start-Sleep -Milliseconds 300
        $p.Refresh()
    }
    if(-not $p.HasExited){
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        throw 'B8 runtime exceeded 95 seconds'
    }
}finally{
    if(-not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}
}
$p.Refresh()
$log=if(Test-Path $stderr){(Get-Content -LiteralPath $stderr -Raw)-replace '\x1b\[[0-9;]*m',''}else{''}
$ci=[Globalization.CultureInfo]::InvariantCulture
$coverage=@()
$tierErrors=0
$seamErrors=0
$atomicErrors=0
$mixedPairs=0
$surfaceTiles=0
$waterQualified=$false
$probeCount=0
$runtimeErrors=@()
foreach($line in ($log -split "[\r\n]+")){
    if($line -match 'B3 horizon coverage'){
        $pFields=@{}
        foreach($key in @('x','missing','required','visible','tier_errors','seam_ownership_errors','atomic_publication_errors','visible_mixed_pairs')){
            if($line -match ("\b"+$key+"=(-?[0-9.]+)")){$pFields[$key]=$Matches[1]}
        }
        if($pFields.Count -eq 8){
            $coverage+=,$pFields
            $tierErrors=[Math]::Max($tierErrors,[int]$pFields.tier_errors)
            $seamErrors=[Math]::Max($seamErrors,[int]$pFields.seam_ownership_errors)
            $atomicErrors=[Math]::Max($atomicErrors,[int]$pFields.atomic_publication_errors)
            $mixedPairs=[Math]::Max($mixedPairs,[int]$pFields.visible_mixed_pairs)
        }
    }
    if($line -match 'B8 CPU SDF collider tile publication' -and $line -match 'surface_tiles=(\d+)'){
        $surfaceTiles=[Math]::Max($surfaceTiles,[int]$Matches[1])
    }
    if($line -match 'B8 Avian water buoyancy dynamic probe'){
        $probeCount++
        if($line -match '\bqualified=true'){$waterQualified=$true}
    }
    if($line -match '(?i)\bERROR\b|Validation Error|panicked'){
        $runtimeErrors+=,$line
    }
}
$frames=@(Get-ChildItem $report -Filter 'lod-??.png' -File -ErrorAction SilentlyContinue |
    Sort-Object Name)
$validFrames=@($frames | Where-Object {$_.Length -ge 2000})
$moving=@($coverage|Where-Object {
    ([double]::Parse($_.x,$ci)-[double]::Parse($coverage[0].x,$ci)) -gt 0.25
})
$movingMissing=@($moving|Where-Object {[int]$_.missing -gt 0}).Count
$metrics=[ordered]@{
    stage='B8';runner=$env:RUNNER_NAME;exit_code=$p.ExitCode;
    elapsed_s=$watch.Elapsed.TotalSeconds;
    visual_frame_count=$validFrames.Count;
    visual_capture_times_s=@(12,16,20,24,28,32,36,40,44);
    visual_flicker_assessment='HOLD_MANUAL_TEMPORAL_REVIEW';
    moving_coverage_samples=$moving.Count;
    moving_missing_samples=$movingMissing;
    max_visible_mixed_pairs=$mixedPairs;
    lod_tier_violations=$tierErrors;
    lod_seam_ownership_violations=$seamErrors;
    atomic_publication_errors=$atomicErrors;
    sdf_surface_collider_tiles=$surfaceTiles;
    water_dynamic_probe_observed=($probeCount -gt 0);
    water_dynamic_probe_qualified=$waterQualified;
    runtime_error_count=$runtimeErrors.Count;
}
$metrics|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $report 'B8_FUNCTIONAL_REPORT.json') -Encoding UTF8
$metrics|Format-List|Out-String|Write-Host
if($runtimeErrors.Count){Write-Host ($runtimeErrors|Select-Object -First 5|Out-String)}
if($p.ExitCode -ne 0){throw "B8 runtime exit $($p.ExitCode)"}
if($runtimeErrors.Count){throw "B8 GPU/runtime errors: $($runtimeErrors.Count)"}
if($validFrames.Count -ne 9){throw "B8 expected 9 sequential screenshots; got $($validFrames.Count)"}
if($coverage.Count -lt 10 -or $moving.Count -lt 3){throw 'B8 insufficient moving LOD evidence'}
if($movingMissing -gt 0){throw "B8 horizon missing on $movingMissing samples"}
if($tierErrors -gt 0 -or $seamErrors -gt 0 -or $atomicErrors -gt 0){
    throw "B8 visible LOD seam or publication violation: tiers=$tierErrors seams=$seamErrors atomic=$atomicErrors"
}
if($mixedPairs -lt 1){throw 'B8 never exercised an actual mixed LOD visible pair'}
if($surfaceTiles -lt 10){throw "B8 insufficient SDF collider tiles: $surfaceTiles"}
if(-not $waterQualified){throw 'B8 Avian water probe did not demonstrate float-up and dense-down'}
Write-Host 'B8_FUNCTIONAL_VISUAL_EVIDENCE_PASS_WITH_MANUAL_TEMPORAL_HOLD'
