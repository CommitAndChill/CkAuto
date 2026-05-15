#requires -Version 7
<#
.SYNOPSIS
    Removes the lock-tolerance probe's dropped .as file + sidecar JSON.

.DESCRIPTION
    Companion to _probe_lock_tolerance.bat / .ps1. Reads the sidecar at
    Saved/AutoTestProbes/lock_tolerance.json to find the probe .as file,
    deletes both, and notes what else the operator needs to do for a
    complete reset.

.NOTES
    The populator places a wrapper actor in the AutoTests level when the
    probe .as is picked up. Deleting the probe .as here does NOT trigger
    the populator's orphan-remove pass mid-session (AS doesn't reliably
    drop class registrations on source-file deletion while the editor is
    running). To fully reset to pre-probe disk state:

      1. Run this restore (here).
      2. Restart the editor — on next startup, AS does a fresh disk-scan
         compile, the probe class is gone, the wrapper generator re-emits
         without it, and the populator's first sync orphan-removes the
         placed wrapper + deletes its external .uasset via
         FPackageSourceControlHelper::Delete. The orphan-remove pass DOES
         touch the .umap because it's a map mutation (expected — contrast
         with the add path).
      3. Optionally: `git checkout -- <MapPath>` to discard the orphan-
         remove's .umap save if you want the on-disk .umap to match HEAD
         exactly.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$sidecarPath = Join-Path $projectRoot 'Saved/AutoTestProbes/lock_tolerance.json'

if (-not (Test-Path $sidecarPath)) {
    Write-Warning "No sidecar at $sidecarPath — either the probe was never run, or restore already happened. Nothing to do."
    exit 0
}

$sidecar = Get-Content -Path $sidecarPath -Raw | ConvertFrom-Json
$probeAsPath = $sidecar.ProbeAsPath

if (Test-Path $probeAsPath) {
    Remove-Item -Path $probeAsPath -Force
    Write-Host "Removed: $probeAsPath" -ForegroundColor Green
} else {
    Write-Warning "Probe AS file already absent at $probeAsPath. Continuing."
}

Remove-Item -Path $sidecarPath -Force
Write-Host "Removed: $sidecarPath" -ForegroundColor Green

Write-Host ''
Write-Host 'Restore complete.' -ForegroundColor Cyan
Write-Host '  The probe .as and sidecar are deleted.'
Write-Host '  To fully reset on-disk state to the pre-probe baseline:'
Write-Host '    1. Restart the editor — populator will orphan-remove the placed'
Write-Host "       wrapper + delete its external .uasset on next sync."
Write-Host "    2. Optional: 'git checkout -- $($sidecar.MapPath)' to also discard"
Write-Host '       the orphan-remove .umap save (which is a map mutation — expected,'
Write-Host '       NOT proof of a regression).'
Write-Host ''
