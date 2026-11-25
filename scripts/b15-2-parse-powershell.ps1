# Validate only syntax; does not execute the scripts or require FFmpeg.
$ErrorActionPreference = 'Stop'
foreach ($script in @('scripts/b15-2-windows-matrix.ps1', 'scripts/b15-2-local-60fps.ps1', 'scripts/b15-3-local-dxgi-matrix.ps1')) {
    $tokens = $null
    $errors = $null
    $path = Join-Path (Get-Location).Path $script
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -gt 0) {
        foreach ($err in $errors) { Write-Host "PARSER_ERROR $($err.ToString())" }
        throw "PowerShell parser failed: $script"
    }
    Write-Host "B15_2_PARSER_PASS $script"
}
