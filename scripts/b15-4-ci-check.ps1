# Validate that new per-frame costs are present and have the same cadence
# on every branch of the existing Windows B15.2 A/B/C Vulkan matrix.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$base = Join-Path (Get-Location).Path 'b15-2-evidence'
$arms = @('b15_1_edit_control', 'b15_2_atomic_shell_on', 'b15_2_atomic_shell_off')
foreach ($arm in $arms) {
    $folder = Join-Path $base $arm
    $costPath = Join-Path $folder 'trace\b15-4-costs.csv'
    $framePath = Join-Path $folder 'trace\b14-frames.csv'
    if (-not (Test-Path -LiteralPath $costPath) -or
        -not (Test-Path -LiteralPath $framePath)) {
        throw "B15_4_CI_TRACE_MISSING arm=$arm"
    }
    $cost = @(Import-Csv -LiteralPath $costPath)
    $frame = @(Import-Csv -LiteralPath $framePath)
    if ($cost.Count -lt 1000 -or $cost.Count -ne $frame.Count) {
        throw "B15_4_CI_FRAME_CADENCE_MISMATCH arm=$arm cost=$($cost.Count) b14=$($frame.Count)"
    }
    foreach ($col in @('stream_cpu_us','b14_observation_us',
        'cancelled_lod_total','post_edit_repair_total','edit_transactions_total')) {
        if (-not $cost[0].PSObject.Properties[$col]) {
            throw "B15_4_CI_COLUMN_MISSING arm=$arm column=$col"
        }
    }
    $priorCanceled=0L
    $priorRepairs=0L
    $maxCpu=0L
    foreach ($row in $cost) {
        $cancel=[long]$row.cancelled_lod_total
        $repair=[long]$row.post_edit_repair_total
        $cpu=[long]$row.stream_cpu_us
        if ($cancel -lt $priorCanceled -or $repair -lt $priorRepairs) {
            throw "B15_4_CI_NON_MONOTONIC_TOTAL arm=$arm"
        }
        if ($cpu -gt $maxCpu) { $maxCpu = $cpu }
        $priorCanceled = $cancel
        $priorRepairs = $repair
    }
    if ($maxCpu -eq 0) { throw "B15_4_CI_ZERO_STREAM_TIMING arm=$arm" }
    Write-Host "B15_4_CI_FRAME_COST_PASS arm=$arm frames=$($cost.Count) max_stream_cpu_us=$maxCpu canceled=$priorCanceled repairs=$priorRepairs"
}
Write-Host 'B15_4_CI_CORRELATED_COSTS_PASS'
