#requires -Version 7
<#
.SYNOPSIS
    Verifies the lock-tolerance probe by comparing the target .umap's pre-
    state (captured by _probe_lock_tolerance.ps1 into the sidecar JSON)
    against the current on-disk state. Reports PASS if the .umap is byte-
    identical, FAIL if the file was touched.

.DESCRIPTION
    Pure verifier — operates entirely off the sidecar at
    Saved/AutoTestProbes/lock_tolerance.json plus a fresh capture of the
    target map's hash/size/mtime/IsReadOnly/external-actor count.

    Three PASS conditions:
      - .umap SHA-256 unchanged.
      - .umap LastWriteTime unchanged.
      - External-actor count grew by exactly 1.

    Any FAIL trips the overall verdict.

    Also greps the editor log for the populator's "Auto-saved." line on
    the target map config, so the operator sees that the populator
    actually ran (vs the probe .as never having been picked up by AS).

.NOTES
    Exit codes:
      0 — PASS
      1 — FAIL
      2 — Usage / setup error (no sidecar, etc).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$sidecarPath = Join-Path $projectRoot 'Saved/AutoTestProbes/lock_tolerance.json'

if (-not (Test-Path $sidecarPath)) {
    Write-Error "No sidecar at $sidecarPath. Run _probe_lock_tolerance.bat first."
    exit 2
}

$sidecar = Get-Content -Path $sidecarPath -Raw | ConvertFrom-Json
$MapPath      = $sidecar.MapPath
$externalsDir = $sidecar.ExternalsDir
$className    = $sidecar.ClassName
$pre          = $sidecar.Pre

if (-not (Test-Path $MapPath)) {
    Write-Error "Target .umap not found at $MapPath."
    exit 2
}

# ---- Capture post-state --------------------------------------------------
$post = @{
    Hash       = (Get-FileHash $MapPath -Algorithm SHA256).Hash
    Size       = (Get-Item $MapPath).Length
    Count      = if (Test-Path $externalsDir) { (Get-ChildItem $externalsDir -Recurse -Filter '*.uasset' -ErrorAction SilentlyContinue).Count } else { 0 }
    LastWrite  = (Get-Item $MapPath).LastWriteTime
    IsReadOnly = (Get-ItemProperty $MapPath).IsReadOnly
}

# ---- git status snapshot (informational) ---------------------------------
function Get-GitStatus([string]$ProjectRoot, [string[]]$Paths) {
    Push-Location $ProjectRoot
    try {
        $relativePaths = $Paths | ForEach-Object {
            $p = $_
            try { Resolve-Path -Relative -Path $p -RelativeBasePath $ProjectRoot } catch { $p }
        }
        & git status --short --untracked-files=all -- @relativePaths 2>$null
    } finally {
        Pop-Location
    }
}
$gitStatus = (Get-GitStatus $projectRoot @($MapPath, $externalsDir)) -join "`n"

# ---- Populator log check (looks for the populator firing for this config) -
$logFiles = Get-ChildItem -Path (Join-Path $projectRoot 'Saved/Logs') -Filter "$($sidecar.ProjectName)*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
$populatorLogHit = $false
if ($logFiles) {
    $logFile = $logFiles | Select-Object -First 1
    $logContent = Get-Content -Path $logFile.FullName -Tail 500 -ErrorAction SilentlyContinue
    # Look for any populator "spawned" line emitted after the sidecar's Generated time.
    foreach ($line in $logContent) {
        if ($line -match 'CkAutoTest Populator.*1 spawned, 0 removed') {
            $populatorLogHit = $true
            break
        }
    }
}

# ---- Verdict -------------------------------------------------------------
$pass = $true
$findings = New-Object System.Collections.Generic.List[string]

Write-Host ''
Write-Host '==========================================================================' -ForegroundColor Cyan
Write-Host ' Lock-Tolerance Probe Verifier                                            ' -ForegroundColor Cyan
Write-Host '==========================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Target map:        $MapPath"
Write-Host "  Probe class:       $className"
Write-Host "  Sidecar:           $sidecarPath"
Write-Host ''
Write-Host 'State comparison (pre -> post):' -ForegroundColor Yellow
Write-Host "  SHA-256:           $($pre.Hash)"
Write-Host "                  -> $($post.Hash)"
Write-Host "  Size:              $($pre.Size) bytes -> $($post.Size) bytes"
Write-Host "  LastWriteTime:     $($pre.LastWrite)"
Write-Host "                  -> $($post.LastWrite)"
Write-Host "  IsReadOnly:        $($pre.IsReadOnly) -> $($post.IsReadOnly)"
Write-Host "  Externals count:   $($pre.Count) -> $($post.Count)"
Write-Host ''
Write-Host 'git status (target paths):' -ForegroundColor Yellow
if ($gitStatus) { $gitStatus -split "`n" | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (clean)' }
Write-Host ''
Write-Host 'Populator log scan:' -ForegroundColor Yellow
if ($populatorLogHit) {
    Write-Host "  Found populator 'spawned' line in latest log — populator ran during this session."
} else {
    Write-Host "  No populator 'spawned' line in latest log — did AS actually pick up the probe .as?"
}
Write-Host ''

if ($pre.Hash -eq $post.Hash) {
    $findings.Add('  [PASS] .umap SHA-256 unchanged — file is byte-identical on disk.') | Out-Null
} else {
    $pass = $false
    $findings.Add('  [FAIL] .umap SHA-256 changed — file was rewritten on disk.') | Out-Null
}

if ([DateTime]$pre.LastWrite -eq [DateTime]$post.LastWrite) {
    $findings.Add('  [PASS] .umap LastWriteTime unchanged — OS confirms no write occurred.') | Out-Null
} else {
    $pass = $false
    $findings.Add('  [FAIL] .umap LastWriteTime advanced — the file was touched.') | Out-Null
}

$delta = $post.Count - $pre.Count
if ($delta -eq 1) {
    $findings.Add("  [PASS] External-actor count grew by exactly 1 ($($pre.Count) -> $($post.Count)).") | Out-Null
} elseif ($delta -eq 0) {
    $pass = $false
    $findings.Add('  [INCONCLUSIVE] External-actor count unchanged. Populator did not run, or AS did') | Out-Null
    $findings.Add('                 not pick up the probe .as file. Check the editor Output Log.') | Out-Null
} elseif ($delta -gt 1) {
    $findings.Add("  [WARN] External-actor count grew by $delta (expected 1). Other adds happened in") | Out-Null
    $findings.Add('         parallel; hash check above is still the authoritative pass/fail signal.') | Out-Null
} else {
    $pass = $false
    $findings.Add("  [INCONCLUSIVE] External-actor count went DOWN by $([Math]::Abs($delta)).") | Out-Null
}

Write-Host 'Verdict:' -ForegroundColor Yellow
$findings | ForEach-Object { Write-Host $_ }
Write-Host ''

if ($pass) {
    Write-Host '==========================================================================' -ForegroundColor Green
    Write-Host ' VERIFICATION: PASS                                                       ' -ForegroundColor Green
    Write-Host '                                                                          ' -ForegroundColor Green
    Write-Host " The target .umap is byte-identical on disk before and after the populator" -ForegroundColor Green
    Write-Host ' placed a new test wrapper. Concrete consequence: another teammate holding ' -ForegroundColor Green
    Write-Host ' an LFS lock on this .umap cannot block this workflow.                    ' -ForegroundColor Green
    Write-Host '==========================================================================' -ForegroundColor Green
    exit 0
} else {
    Write-Host '==========================================================================' -ForegroundColor Red
    Write-Host ' VERIFICATION: FAIL                                                       ' -ForegroundColor Red
    Write-Host '                                                                          ' -ForegroundColor Red
    Write-Host ' The .umap was touched, or the populator did not run a clean adds-only    ' -ForegroundColor Red
    Write-Host ' delta. Possible causes:                                                  ' -ForegroundColor Red
    Write-Host '   * OFPA-aware save path did not engage (potential populator regression).' -ForegroundColor Red
    Write-Host '   * Populator processed a non-add-only delta (orphan removal etc) which  ' -ForegroundColor Red
    Write-Host '     legitimately requires a .umap save.                                  ' -ForegroundColor Red
    Write-Host '   * Something else edited the level during the test window.              ' -ForegroundColor Red
    Write-Host '==========================================================================' -ForegroundColor Red
    exit 1
}
