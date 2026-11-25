param(
    [ValidateSet('cold','warm')][string]$Profile = 'cold',
    [string]$OutputRoot = '',
    [string]$StateRoot = '',
    [string]$RuntimeDir = '',
    [switch]$Build,
    [switch]$HeadlessDiagnostic
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (!$RuntimeDir) { $RuntimeDir = Join-Path $root 'comparison-v1-runtime' }
if ($Build) {
    Push-Location $root
    try {
        & cargo +1.100.0 build --release --locked -p sandbox-game
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
    } finally { Pop-Location }
    New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeDir 'assets') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'target\release\sandbox-game.exe') -Destination (Join-Path $RuntimeDir 'sandbox-game.exe') -Force
    Copy-Item -Path (Join-Path $root 'assets\shaders') -Destination (Join-Path $RuntimeDir 'assets') -Recurse -Force
}
$exe = Join-Path $RuntimeDir 'sandbox-game.exe'
if (!(Test-Path -LiteralPath $exe) -or !(Test-Path -LiteralPath (Join-Path $RuntimeDir 'assets\shaders'))) {
    throw 'Build the comparison branch with -Build first, or supply -RuntimeDir containing matching exe and shaders.'
}
if ((Get-Process -Id $PID).SessionId -eq 0 -and !$HeadlessDiagnostic) {
    throw 'Interactive comparison requires a Windows desktop session, not a Session 0 Actions service.'
}
if (!$OutputRoot) { $OutputRoot = Join-Path $root 'reports\comparison-v1' }
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$run = Join-Path $OutputRoot "bevy-$Profile-$stamp"
New-Item -ItemType Directory -Force -Path $run | Out-Null
$runState = Join-Path $run 'world'
New-Item -ItemType Directory -Force -Path $runState | Out-Null
if ($Profile -eq 'warm') {
    if (!$StateRoot) { throw 'Warm profile requires -StateRoot from a previous cold run.' }
    if (!(Test-Path (Join-Path $StateRoot 'world-b4.edits'))) { throw "Warm edit save missing: $StateRoot" }
    Copy-Item -Path (Join-Path $StateRoot '*') -Destination $runState -Recurse -Force
} elseif ($StateRoot) {
    throw 'Cold profile always creates a new isolated state. Omit -StateRoot.'
}
$env:SANDBOX_COMPARISON_V1 = '1'
$env:SANDBOX_COMPARISON_TRACE_CSV = Join-Path $run 'frames.csv'
$env:SANDBOX_STAGE = 'B11'
$env:SANDBOX_B11_FAR_FIELD = '1'
$env:SANDBOX_B3_MIXED_LOD = '1'
$env:SANDBOX_B15_2_EDIT_ATOMIC = '1'
$env:SANDBOX_B15_2_FAR_FIELD = '1'
$env:SANDBOX_B15_1_STABLE_SLABS = '1'
$env:SANDBOX_B15_5_FIXED_SLABS = '1'
$env:SANDBOX_B15_6_CONSERVATIVE_CULLING = '1'
$env:SANDBOX_B16_ASYNC_FAR_SHELL = '1'
$env:SANDBOX_B15_1_SCRIPTED_EDITS = '1'
$env:SANDBOX_B15_1_ROUTE = 'survey'
$env:SANDBOX_B3_ROUTE = ''
$env:SANDBOX_B3_HEADLESS = if ($HeadlessDiagnostic) { '1' } else { '0' }
$env:SANDBOX_B2_HEADLESS = if ($HeadlessDiagnostic) { '1' } else { '0' }
$env:SANDBOX_B3_RENDER_1080P = '1'
$env:SANDBOX_B3_BENCH_UNCAPPED = '0'
$env:SANDBOX_B14_TRACE_DIR = ''
$env:SANDBOX_B15_4_CORRELATE = '0'
$env:SANDBOX_B2_CAPTURE_PATH = ''
$env:SANDBOX_B10_CAPTURE_TIMES = ''
$env:SANDBOX_B15_5_CAPTURE_TIMES = ''
$env:SANDBOX_B15_RASTER_DIR = ''
$env:SANDBOX_B4_SAVE_PATH = Join-Path $runState 'world-b4.edits'
$env:SANDBOX_B5_SAVE_PATH = Join-Path $runState 'world-b5-rocks.txt'
$env:WGPU_BACKEND = 'vulkan'
$env:RUST_LOG = 'info,sandbox_gpu_terrain::b2=warn,sandbox_gpu_terrain::b2::b3=info'
$stdout = Join-Path $run 'stdout.log'
$stderr = Join-Path $run 'stderr.log'
Write-Host "COMPARISON_V1_BEVY session=$run headless=$HeadlessDiagnostic"
$proc = Start-Process -FilePath $exe -WorkingDirectory $RuntimeDir -PassThru -Wait -RedirectStandardError $stderr -RedirectStandardOutput $stdout
if ($proc.ExitCode -ne 0) { throw "Bevy comparison failed exit=$($proc.ExitCode)" }
$log = (Get-Content -LiteralPath $stderr -Raw) -replace '\x1b\[[0-9;]*m',''
if ($log -notmatch 'COMPARISON_V1_COMPLETE') { throw 'Benchmark completion marker missing' }
$requested = ([regex]::Matches($log, 'B15\.1 scripted edit requested')).Count
$accepted = ([regex]::Matches($log, 'B4 edit persisted; GPU rebuild queued')).Count
$editMs = @()
$ic = [Globalization.CultureInfo]::InvariantCulture
foreach ($match in [regex]::Matches($log, 'latency_ms=([0-9.]+)')) {
    $editMs += [double]::Parse($match.Groups[1].Value, $ic)
}
$native = [ordered]@{
    edits_requested = $requested
    edits_persisted = $accepted
    edits_rejected = $requested - $accepted
    max_gpu_ready_publication_ms = if ($editMs.Count) { ($editMs | Measure-Object -Maximum).Maximum } else { $null }
    edit_first_presented_pixel_ms = $null
    note = 'B4 edit persisted and GPU-ready metrics are NOT first physically presented pixel.'
}
$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) / $($_.DriverVersion)" })
$cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$meta = [ordered]@{
    engine = 'rust_bevy'
    scenario_id = 'survey46-six-edits-v1'
    render_mode = if ($HeadlessDiagnostic) { 'gpu_headless' } else { 'interactive' }
    profile = $Profile
    git_sha = (& git -C $root rev-parse HEAD).Trim()
    cpu = $cpu
    gpu = $gpu
    hostname = $env:COMPUTERNAME
    resolution = '1920x1080'
    backend = 'Bevy 0.20.1 / Vulkan'
    run_id = (Split-Path $run -Leaf)
    functional_proxies = $native
}
$metadata = Join-Path $run 'metadata.json'
$meta | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $metadata -Encoding UTF8
& python.exe (Join-Path $root 'scripts\comparison-v1-reduce.py') --csv $env:SANDBOX_COMPARISON_TRACE_CSV --contract (Join-Path $root 'benchmarks\comparison-v1.json') --metadata $metadata --out (Join-Path $run 'comparison-v1-result.json')
if ($LASTEXITCODE -ne 0) { throw 'Comparison reducer rejected Bevy data' }
Write-Host "COMPARISON_V1_DONE report=$run state=$runState"
