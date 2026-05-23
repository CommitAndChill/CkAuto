#requires -Version 7
<#
.SYNOPSIS
    Restores Probe E's canonical edit from the sidecar's base64 snapshot,
    then deletes the probe .as file and sidecar. Idempotent.
#>

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path

$asPath  = Join-Path $projectRoot 'Script\_probe_wbp_class_synth.as'
$sidecar = Join-Path $projectRoot 'Script\_probe_wbp_class_synth.targets.json'

$any = $false

if (Test-Path $sidecar) {
    $sc = Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($sc.CanonicalFile -and $sc.OriginalBase64) {
        if (Test-Path $sc.CanonicalFile) {
            $bytes = [Convert]::FromBase64String($sc.OriginalBase64)
            [System.IO.File]::WriteAllBytes($sc.CanonicalFile, $bytes)
            Write-Host "Restored canonical: $($sc.CanonicalFile)" -ForegroundColor Green
            $any = $true
        } else {
            Write-Warning "Canonical path from sidecar no longer exists: $($sc.CanonicalFile) - skipping restore."
        }
    } else {
        Write-Warning "Sidecar missing CanonicalFile/OriginalBase64 fields - cannot restore canonical."
    }
    Remove-Item -Force $sidecar
    Write-Host "Deleted $sidecar" -ForegroundColor Green
    $any = $true
} else {
    Write-Host "[SKIP] not present: $sidecar" -ForegroundColor DarkGray
}

if (Test-Path $asPath) {
    Remove-Item -Force $asPath
    Write-Host "Deleted $asPath" -ForegroundColor Green
    $any = $true
} else {
    Write-Host "[SKIP] not present: $asPath" -ForegroundColor DarkGray
}

if (-not $any) { Write-Host 'Nothing to restore.' }
