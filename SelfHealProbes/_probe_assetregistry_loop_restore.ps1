#requires -Version 7
<#
.SYNOPSIS
    Deletes Probe C's injected .as file and sidecar. Idempotent.
#>

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path

$paths = @(
    (Join-Path $projectRoot 'Script\_probe_assetregistry_loop.as'),
    (Join-Path $projectRoot 'Script\_probe_assetregistry_loop.targets.json')
)

$any = $false
foreach ($p in $paths) {
    if (Test-Path $p) {
        Remove-Item -Force $p
        Write-Host "Deleted $p" -ForegroundColor Green
        $any = $true
    }
    else {
        Write-Host "[SKIP] not present: $p" -ForegroundColor DarkGray
    }
}
if (-not $any) { Write-Host 'Nothing to restore.' }
