# B11 Vulkan visual smoke; run through powershell.exe -ExecutionPolicy Bypass -File.
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force b11-evidence | Out-Null
$env:SANDBOX_STAGE='B11'
$env:SANDBOX_B3_HEADLESS='1'
$env:SANDBOX_B3_ROUTE='straight'
$env:SANDBOX_B3_MIXED_LOD='1'
$env:SANDBOX_B3_RENDER_1080P='1'
$env:SANDBOX_B10_CAPTURE_TIMES='25,57'
$env:SANDBOX_B4_SAVE_PATH=(Join-Path (Get-Location).Path 'b11-evidence/b11-edits.txt')
$env:SANDBOX_B5_SAVE_PATH=(Join-Path (Get-Location).Path 'b11-evidence/b11-rocks.txt')
$env:SANDBOX_B2_CAPTURE_PATH=(Join-Path (Get-Location).Path 'b11-evidence/b11.png')
$env:WGPU_BACKEND='vulkan'
$env:RUST_LOG='info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$app=Join-Path (Get-Location).Path 'b11-runtime'
$p=Start-Process -FilePath (Join-Path $app 'sandbox-game.exe') -WorkingDirectory $app -PassThru -RedirectStandardError 'b11-evidence/stderr.log' -RedirectStandardOutput 'b11-evidence/stdout.log'
if(-not $p.WaitForExit(85000)){Stop-Process -Id $p.Id -Force;throw 'B11 screenshot deadline exceeded'}
$l=Get-Content 'b11-evidence/stderr.log' -Raw
if ($l -notmatch 'B11 far field coverage built'){throw 'Far coverage was not created'}
if ($l -notmatch 'sequence_index=1.*B2 visual CI: screenshot captured at'){throw 'B11 final screenshot not confirmed'}
if (@(Get-ChildItem 'b11-evidence/b11-??.png').Count -ne 2){throw 'B11 expected 2 images'}
if ($l -match '(?i)\bERROR\b|Validation Error|panicked'){throw 'B11 GPU error'}
Write-Host 'B11_FAR_FIELD_VULKAN_CAPTURE_PASS'
