$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Get-Location).Path
$report=Join-Path $root 'b13-evidence'
$runtime=Join-Path $root 'b13-runtime'
New-Item -ItemType Directory -Force -Path $report | Out-Null
$exe=Join-Path $runtime 'sandbox-game.exe'
if (-not (Test-Path -LiteralPath $exe)){throw 'B13 executable missing'}
$env:SANDBOX_STAGE='B11'
$env:SANDBOX_B3_HEADLESS='1'
$env:SANDBOX_B3_ROUTE='straight'
$env:SANDBOX_B3_MIXED_LOD='1'
$env:SANDBOX_B3_RENDER_1080P='1'
$env:SANDBOX_B10_CAPTURE_TIMES='12,32'
$env:SANDBOX_B4_SAVE_PATH=Join-Path $report 'world-b4.edits'
$env:SANDBOX_B5_SAVE_PATH=Join-Path $report 'world-b5-rocks.txt'
$env:SANDBOX_B2_CAPTURE_PATH=Join-Path $report 'b13.png'
$env:WGPU_BACKEND='vulkan'
$env:RUST_LOG='info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$stdout=Join-Path $report 'stdout.log'
$stderr=Join-Path $report 'stderr.log'
$p=Start-Process -FilePath $exe -WorkingDirectory $runtime -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $p.WaitForExit(90000)) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw 'B13 visual smoke exceeded 90 sec'
}
$log=(Get-Content $stderr -Raw) -replace '\x1b\[[0-9;]*m',''
$images=@(Get-ChildItem $report -Filter 'b13-??.png' -File)
$fields=[ordered]@{
    run='B13'
    images=$images.Count
    frustum_protection=($log -match 'B13 GPU mesh visibility: frustum culling disabled')
    physics_readiness_guard=($log -match 'B13 physics rock/collider residency guard')
    edited_sdf_colliders=($log -match 'B8 CPU SDF collider tile publication')
    rock_streaming=($log -match 'B5 130m deterministic rock visual streaming')
    far_field=($log -match 'B11 far field coverage built')
    second_capture=($log -match 'B2 visual CI: screenshot captured at[^\r\n]*sequence_index=1')
    errors=([regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked')).Count
}
$fields|ConvertTo-Json|Set-Content (Join-Path $report 'B13_SMOKE.json') -Encoding UTF8
$fields|Format-List|Out-String|Write-Host
if($images.Count -ne 2){throw "B13 expected 2 images, received $($images.Count)"}
if(($images|Where-Object{$_.Length -lt 3000}).Count -gt 0){throw 'B13 screenshot invalid'}
if(-not $fields.second_capture){throw 'B13 second capture not confirmed'}
if(-not $fields.frustum_protection){throw 'B13 GPU frustum protection not activated'}
if(-not $fields.physics_readiness_guard){throw 'B13 rock collision readiness diagnostics missing'}
if(-not $fields.edited_sdf_colliders){throw 'B13 SDF terrain collider tiles missing'}
if(-not $fields.rock_streaming){throw 'B13 rock streaming inactive'}
if(-not $fields.far_field){throw 'B13 far visual coverage inactive'}
if($fields.errors -gt 0){throw 'B13 runtime or Vulkan error'}
Write-Host 'B13_VISUAL_PHYSICS_GUARD_SMOKE_PASS_WITH_MANUAL_VISUAL_HOLD'
