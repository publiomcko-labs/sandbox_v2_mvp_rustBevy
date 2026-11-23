param(
    [string]$Runtime = "b10-runtime",
    [string]$Report = "b10-ab-report"
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Get-Location).Path
$runtimeDir=Join-Path $root $Runtime
$reportDir=Join-Path $root $Report
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$exe=Join-Path $runtimeDir 'sandbox-game.exe'
if (-not (Test-Path $exe)){throw "B10 executable not found $exe"}
$scenarios=@(
    [pscustomobject]@{name='mixed-water';mixed='1';hide='0'},
    [pscustomobject]@{name='uniform-water';mixed='0';hide='0'},
    [pscustomobject]@{name='mixed-dry';mixed='1';hide='1'},
    [pscustomobject]@{name='uniform-dry';mixed='0';hide='1'}
)
$results=@()
foreach ($arm in $scenarios){
    $armDir=Join-Path $reportDir $arm.name
    New-Item -ItemType Directory -Force $armDir | Out-Null
    $env:SANDBOX_STAGE='B8'
    $env:SANDBOX_B3_HEADLESS='1'
    $env:SANDBOX_B3_ROUTE='straight'
    $env:SANDBOX_B3_MIXED_LOD=$arm.mixed
    $env:SANDBOX_B10_HIDE_OCEAN=$arm.hide
    $env:SANDBOX_B10_CAPTURE_TIMES='25,57'
    $env:SANDBOX_B3_RENDER_1080P='1'
    $env:SANDBOX_B3_BENCH_UNCAPPED='1'
    $env:SANDBOX_B4_TEST_BRUSH='0'
    $env:SANDBOX_B4_SAVE_PATH=Join-Path $armDir 'world-b4.edits'
    $env:SANDBOX_B5_SAVE_PATH=Join-Path $armDir 'world-b5-rocks.txt'
    $env:SANDBOX_B2_CAPTURE_PATH=Join-Path $armDir 'terrain.png'
    $env:RUST_LOG='info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
    $env:WGPU_BACKEND='vulkan'
    $stdout=Join-Path $armDir 'stdout.log'
    $stderr=Join-Path $armDir 'stderr.log'
    Write-Host "B10 A/B arm $($arm.name): mixed=$($arm.mixed) water_hidden=$($arm.hide)"
    $p=Start-Process -FilePath $exe -WorkingDirectory $runtimeDir -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $p.WaitForExit(85000)){
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        throw "B10 arm timeout: $($arm.name)"
    }
    $log=(Get-Content -LiteralPath $stderr -Raw)-replace '\x1b\[[0-9;]*m',''
    $screens=@(Get-ChildItem $armDir -Filter 'terrain-??.png' -File)
    $last=$log -split '[\r\n]+'|Where-Object{$_ -match 'B3 horizon coverage'}|Select-Object -Last 1
    $record=[ordered]@{arm=$arm.name;mixed_lod=$arm.mixed;hide_ocean=$arm.hide;
        screenshots=$screens.Count;gpu_errors=([regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked')).Count;
        last_coverage=$last}
    $results+=,[pscustomobject]$record
    if($screens.Count -ne 2){throw "B10 arm $($arm.name) screenshot count=$($screens.Count), expected two"}
    if($record.gpu_errors -gt 0){throw "B10 arm $($arm.name) GPU/runtime error"}
    if($log -notmatch 'B2 visual CI: screenshot captured at[^\r\n]*sequence_index=1'){throw "B10 arm $($arm.name) final screenshot not confirmed"}
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $reportDir 'B10_AB_REPORT.json') -Encoding UTF8
$results|Format-Table -AutoSize|Out-String|Write-Host
Write-Host 'B10_AB_VULKAN_8_SCREENSHOTS_PASS'
