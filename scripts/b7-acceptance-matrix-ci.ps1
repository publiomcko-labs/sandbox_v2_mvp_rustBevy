# B7 explicit PASS/FAIL/HOLD matrix. Do NOT turn missing validation into PASS.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$report=Join-Path (Get-Location).Path 'b6-b7-report'
$path=Join-Path $report 'benchmark.json'
if (-not (Test-Path $path)) { throw 'Missing B6 benchmark source' }
$m=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$gates=@()
function Add-Gate([string]$name,[string]$status,[string]$reason) {
    $script:gates+= [pscustomobject]@{name=$name;status=$status;reason=$reason}
}
Add-Gate 'B0/B1/B2 GPU build and extract' 'PASS' 'Separate historical Vulkan and Bevy Release evidence; B6 build passes'
Add-Gate '130m streaming required coverage' $(if($m.missing_samples -eq 0 -and $m.moving_coverage_samples -ge 20){'PASS'}else{'FAIL'}) "moving missing=$($m.missing_samples) samples=$($m.moving_coverage_samples)"
Add-Gate '18m/s continuous route' $(if($m.distance_m -ge 500){'PASS'}else{'FAIL'}) "distance=$($m.distance_m)m"
Add-Gate 'three LOD tiers and seams' $(if($m.mixed_lod_samples -ge 3){'PASS'}else{'FAIL'}) "mixed_samples=$($m.mixed_lod_samples); topology hardware tests previously passed"
Add-Gate 'visually no cracks/flicker in moving interactive session' 'HOLD' 'Headless screenshots cannot prove absence of temporal flicker'
Add-Gate '60FPS full presented frames <=16.7ms' $(if($m.frame_ms_max -gt 16.7){'FAIL'}else{'HOLD'}) "headless frame max=$($m.frame_ms_max)ms; actual Windows present/flip not measured"
Add-Gate 'B4 add/sub edit commands and GPU-ready revision' $(if($m.edit_persisted -and $m.edited_gpu_publication){'PASS'}else{'FAIL'}) "journal=$($m.edit_persisted) revised_gpu=$($m.edited_gpu_publication)"
Add-Gate 'B4 <=100ms click to presented edited pixel' 'HOLD' "headless GPU-revision ready latency=$($m.edit_compute_latency_ms_max)ms; no pixel-present timestamp"
Add-Gate 'B4 edit reopen' $(if($m.reopened_edit){'PASS'}else{'FAIL'}) "reopen=$($m.reopened_edit)"
Add-Gate 'B5 rocks rendered in 130m horizon' $(if($m.rocks_resident_max -ge 400){'PASS'}else{'FAIL'}) "resident_max=$($m.rocks_resident_max)"
Add-Gate 'B5 dynamic Avian collision and cave parity' 'HOLD' '4m CPU SDF occupancy collider proxy lacks rigorous GPU shape parity'
Add-Gate 'B5 water buoyancy/drag for dense rocks' 'HOLD' 'Numerical unit test exists; moving physical scene and player flotation not visually qualified'
Add-Gate 'B5 persistent rock state reopen' $(if($m.reopened_rocks){'PASS'}else{'FAIL'}) "reopen=$($m.reopened_rocks)"
Add-Gate 'B6 RAM metrics' $(if($m.peak_working_set_bytes -gt 0){'PASS'}else{'FAIL'}) "peak_working_set_bytes=$($m.peak_working_set_bytes)"
Add-Gate 'B6 GPU VRAM peak' 'HOLD' 'nvidia-smi point samples are not VRAM peak or GPU per-block residency'
Add-Gate 'B7 fully compliant MVP' 'HOLD' 'Not complete until every external and performance/latency/physics gate passes'
$counts=@{PASS=@($gates|Where-Object status -eq PASS).Count;FAIL=@($gates|Where-Object status -eq FAIL).Count;HOLD=@($gates|Where-Object status -eq HOLD).Count}
$matrix=[pscustomobject]@{decision= $(if($counts.FAIL -gt 0){'MVP_FUNCTIONAL_WITH_FAILED_GATES'}else{'MVP_FUNCTIONAL_WITH_UNQUALIFIED_GATES'}); counts=$counts; gates=$gates; source='benchmark.json'}
$matrix|ConvertTo-Json -Depth 6|Set-Content -Path (Join-Path $report 'B7_ACCEPTANCE.json') -Encoding UTF8
$gates|Format-Table -AutoSize|Out-String|Write-Host
Write-Host "B7 matrix PASS=$($counts.PASS) FAIL=$($counts.FAIL) HOLD=$($counts.HOLD)"
