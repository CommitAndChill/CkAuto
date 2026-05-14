#requires -Version 7
<#
.SYNOPSIS
    Restores Probe A targets from sidecar-recorded backups. Idempotent.
#>

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$genDir = Join-Path $projectRoot 'Script\Generated'
$sidecar = Join-Path $genDir '_probe_merge_conflict.targets.json'

if (-not (Test-Path $sidecar)) {
    Write-Host 'Nothing to restore (no sidecar found).'
    exit 0
}

$targets = Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
$restored = 0
foreach ($strategy in 'AssetRegistry', 'DynamicHandle', 'EntitySpawnParams') {
    $drift = $targets.Drifts.$strategy
    if (-not $drift) { continue }
    if (Test-Path $drift.Backup) {
        Move-Item -Force $drift.Backup $drift.File
        Write-Host "  Restored ($strategy): $($drift.File)" -ForegroundColor Green
        $restored++
    }
    else {
        Write-Host "  [SKIP] $strategy backup missing: $($drift.Backup)" -ForegroundColor DarkYellow
    }
}

Remove-Item $sidecar -Force
Write-Host ''
Write-Host "Restored $restored target(s). Sidecar deleted."
