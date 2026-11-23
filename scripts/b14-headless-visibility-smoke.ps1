# B14: GPU/headless time series; script does not modify gameplay/world.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Location).Path
$report = Join-Path $root 'b14-evidence'
$trace = Join-Path $report 'trace'
$runtime = Join-Path $root 'b14-runtime'
$exe = Join-Path $runtime 'sandbox-game.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'B14 runtime missing' }
New-Item -ItemType Directory -Force -Path $report,$trace | Out-Null
$env:SANDBOX_STAGE = 'B11'
$env:SANDBOX_B11_FAR_FIELD = '1'
$env:SANDBOX_B3_HEADLESS = '1'
$env:SANDBOX_B3_ROUTE = 'straight'
$env:SANDBOX_B3_MIXED_LOD = '1'
$env:SANDBOX_B3_RENDER_1080P = '1'
$env:SANDBOX_B10_CAPTURE_TIMES = '12,40,72'
$env:SANDBOX_B14_TRACE_DIR = $trace
$env:SANDBOX_B4_SAVE_PATH = Join-Path $report 'world-b4.edits'
$env:SANDBOX_B5_SAVE_PATH = Join-Path $report 'world-b5-rocks.txt'
$env:SANDBOX_B2_CAPTURE_PATH = Join-Path $report 'b14.png'
$env:WGPU_BACKEND = 'vulkan'
$env:RUST_LOG = 'info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$stdout = Join-Path $report 'stdout.log'
$stderr = Join-Path $report 'stderr.log'
$p = Start-Process -FilePath $exe -WorkingDirectory $runtime -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $p.WaitForExit(115000)) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw 'B14 capture exceeded 115 seconds'
}
$log = (Get-Content -LiteralPath $stderr -Raw) -replace '\x1b\[[0-9;]*m',''
$images = @(Get-ChildItem -LiteralPath $report -Filter 'b14-??.png' -File)
$framesPath = Join-Path $trace 'b14-frames.csv'
$eventsPath = Join-Path $trace 'b14-mesh-events.csv'
if (-not (Test-Path -LiteralPath $framesPath)) { throw 'B14 frame CSV missing' }
if (-not (Test-Path -LiteralPath $eventsPath)) { throw 'B14 mesh events CSV missing' }
$frames = @(Import-Csv -LiteralPath $framesPath)
$events = @(Import-Csv -LiteralPath $eventsPath)
$holes = @($frames | Where-Object { [int]$_.missing -gt 0 })
$probes = @($frames | Where-Object { [int]$_.probe_missing -gt 0 })
$swaps = @($events | Where-Object { $_.event -eq 'mesh_swap' })
$removed = @($events | Where-Object { $_.event -eq 'remove' })
$summary = [ordered]@{
    source_checkpoint = 'checkpoint/b13-functional-20261123'
    branch = 'diag/b14-per-frame-visibility-20261123'
    stage = 'B11'
    screenshots = $images.Count
    frame_rows = $frames.Count
    mesh_event_rows = $events.Count
    missing_frames = $holes.Count
    probe_missing_frames = $probes.Count
    mesh_swaps = $swaps.Count
    removed_mesh_events = $removed.Count
    first_frame = if ($frames.Count -gt 0) { $frames[0].frame } else { $null }
    last_frame = if ($frames.Count -gt 0) { $frames[-1].frame } else { $null }
    zero_gpu_runtime_errors = ([regex]::Matches($log,'(?i)\bERROR\b|Validation Error|panicked')).Count -eq 0
    screenshot_last_confirmed = $log -match 'B2 visual CI: screenshot captured at[^\r\n]*sequence_index=2'
    audit_enabled = $log -match 'B14 per-frame visibility trace enabled'
    physics_guard_enabled = $log -match 'B13 physics rock/collider residency guard'
    terrain_frustum_protection = $log -match 'B13 GPU mesh visibility: frustum culling disabled'
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $report 'B14_SUMMARY.json') -Encoding UTF8
$summary | Format-List | Out-String | Write-Host
if ($images.Count -ne 3) { throw 'B14 expected 3 screenshots' }
if (@($images | Where-Object { $_.Length -lt 3000 }).Count -ne 0) { throw 'B14 empty screenshot' }
if ($frames.Count -lt 250) { throw 'B14 frame telemetry incomplete' }
if ($events.Count -lt 5) { throw 'B14 missing mesh event transitions' }
if (-not $summary.zero_gpu_runtime_errors) { throw 'B14 GPU runtime error' }
if (-not $summary.screenshot_last_confirmed) { throw 'B14 last screenshot not confirmed' }
if (-not $summary.audit_enabled) { throw 'B14 instrumentation inactive' }
if (-not $summary.physics_guard_enabled) { throw 'B13 physics guard absent' }
if (-not $summary.terrain_frustum_protection) { throw 'B13 frustum protection absent' }
Write-Host 'B14_PER_FRAME_DIAGNOSTICS_CAPTURE_PASS_VISUAL_REVIEW_PENDING'
