#requires -Version 7
<#
.SYNOPSIS
    Writes a probe .as file calling a deliberately-fake asset accessor to
    validate the dispatcher's Tier 3 refusal behavior.
#>

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$uproject = Get-ChildItem -Path $projectRoot -Filter '*.uproject' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uproject) {
    Write-Error "No .uproject found at $projectRoot."
    exit 1
}
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($uproject.Name)
$probe = Join-Path $projectRoot 'Script\_ProbeTier3Caller.as'

if (Test-Path $probe) {
    Write-Error "Probe file already exists: $probe — restore first."
    exit 1
}

# ---- Refuse if editor is running (probe any <Project>*.log for a write lock) ----
$logDir = Join-Path $projectRoot 'Saved\Logs'
if (Test-Path $logDir) {
    $logFiles = Get-ChildItem -Path $logDir -Filter "$projectName*.log" -File -ErrorAction SilentlyContinue
    foreach ($lf in $logFiles) {
        try {
            $fs = [System.IO.File]::Open($lf.FullName, 'Open', 'Write', 'None')
            $fs.Close()
        }
        catch {
            Write-Error "Editor appears to be running ($($lf.Name) is locked). Close ${projectName}Editor.exe and retry."
            exit 1
        }
    }
}

$body = @'
// Probe file for Tier 3 self-heal refusal verification.
// Calls a deliberately-fake asset accessor whose .uasset does NOT exist on
// disk, forcing the dispatcher's AssetRegistry synthesizer past Tier 1/2 and
// into the Tier 3 fallback path (which is now refused).
void CkTier3Probe_DoNotCallMe()
{
    auto X = assets::CK_TIER3_PROBE_NONEXISTENT_ASSET();
}
'@

[System.IO.File]::WriteAllText($probe, $body, [System.Text.UTF8Encoding]::new($false))

Write-Host "Probe Tier 3 written: $probe"
Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. Launch ${projectName}Editor.exe; self-heal should fire AND refuse Tier 3 fallback"
Write-Host '  2. Grep log for: [SelfHeal] AssetRegistry stub synthesis failed for assets::CK_TIER3_PROBE_NONEXISTENT_ASSET'
Write-Host '  3. _probe_tier3_restore.bat'
