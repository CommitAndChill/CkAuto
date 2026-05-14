#requires -Version 7
<#
.SYNOPSIS
    Deletes the Tier 3 probe .as file. Idempotent.
#>

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$probe = Join-Path $projectRoot 'Script\_ProbeTier3Caller.as'

if (Test-Path $probe) {
    Remove-Item $probe -Force
    Write-Host "Deleted probe file: $probe" -ForegroundColor Green
}
else {
    Write-Host 'Probe file not present — already restored.'
}
