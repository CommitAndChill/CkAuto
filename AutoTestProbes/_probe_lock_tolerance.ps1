#requires -Version 7
<#
.SYNOPSIS
    Lock-tolerance probe — drops a minimal UCk_AutoTest_Base subclass at
    runtime and proves that the resulting populator-driven test add does NOT
    modify the target .umap on disk. Demonstrates the OFPA-aware save path's
    headline guarantee: another teammate holding an LFS lock on the .umap
    cannot block test additions.

.DESCRIPTION
    Drops `Script/_probe_lock_tolerance.as` (by default; override with
    -TestSourceDir) containing a freshly timestamped UCk_AutoTest_Base
    subclass. AS picks up the new file within ~2-3s; the wrapper generator
    emits the matching A<X>_Actor wrapper; the populator's post-AS-compile
    sync places the wrapper in its configured AutoTests map and saves.

    The sidecar JSON written to Saved/AutoTestProbes/lock_tolerance.json
    records the .umap pre-state (SHA-256, size, mtime, IsReadOnly, external-
    actor count) and the planned class/file paths so _probe_verify.ps1 can
    do the post-state comparison.

    Project-agnostic: discovers project root + name from the .uproject lookup.
    -MapPath is REQUIRED because the populator can have multiple configured
    target maps and the probe has no editor-side way to enumerate them.

.PARAMETER MapPath
    REQUIRED. Path to the target .umap (the AutoTests level for the populator
    config you want to verify). Can be absolute or repo-relative.

    Common values:
      Content/<Project>/Map/AutoTests/AutoTests_<XX>_MAP.umap
      Plugins/CkTests/Content/AutoTests/AutoTests_CkTests_Level.umap

.PARAMETER TestSourceDir
    Directory where the probe .as gets dropped. Default: <ProjectRoot>/Script/.
    Pick a directory under the AutoTestMapConfig's ClassScanRoot so the
    populator considers the probe's wrapper in scope — e.g. for CkTests-side
    use 'Plugins/CkTests/Script/'.

.NOTES
    Editor MUST be running. The probe refuses if no editor log lock is
    detected.

    Class name is timestamped (UCk_AutoTestProbeLockTolerance<TS>) so AS
    class-registration cannot collide with stale state from prior probe
    runs in the same editor session.

    Companion scripts:
      _probe_lock_tolerance_restore.bat — remove the dropped probe .as +
                                          sidecar.
      _probe_verify.ps1 lock_tolerance  — capture post-state, print PASS/FAIL.

    Cleanup note: the populator places a wrapper actor in the AutoTests level
    after the probe runs. The _restore script deletes the probe .as source,
    but a full reset to pre-probe disk state requires an editor restart so
    the populator can orphan-remove the placed wrapper + its external .uasset
    (and the orphan-remove pass itself DOES touch the .umap because it's a
    map mutation — expected, contrast with the add path's behavior).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MapPath,

    [string]$TestSourceDir
)

$ErrorActionPreference = 'Stop'

# ---- Resolve project root + name ------------------------------------------
$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$uproject = Get-ChildItem -Path $projectRoot -Filter '*.uproject' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uproject) {
    Write-Error "No .uproject found at $projectRoot."
    exit 1
}
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($uproject.Name)

Write-Host "Project: $projectName ($projectRoot)" -ForegroundColor Cyan

# ---- Editor-running check (probe needs editor up) ------------------------
$logDir = Join-Path $projectRoot 'Saved/Logs'
$editorRunning = $false
if (Test-Path $logDir) {
    foreach ($lf in (Get-ChildItem -Path $logDir -Filter "$projectName*.log" -File -ErrorAction SilentlyContinue)) {
        try {
            $fs = [System.IO.File]::Open($lf.FullName, 'Open', 'Write', 'None')
            $fs.Close()
        } catch {
            $editorRunning = $true
            break
        }
    }
}
if (-not $editorRunning) {
    Write-Error "No $projectName*.log file is locked — editor does not appear to be running. The lock-tolerance probe requires a live editor so the populator's post-AS-compile sync fires."
    exit 1
}

# ---- Path resolution -----------------------------------------------------
function Resolve-MaybeRelative([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $projectRoot $Path)
}

$MapPath = Resolve-MaybeRelative $MapPath
if (-not (Test-Path $MapPath)) {
    Write-Error "Target .umap not found at $MapPath."
    exit 1
}

if (-not $TestSourceDir) {
    $TestSourceDir = Join-Path $projectRoot 'Script'
}
$TestSourceDir = Resolve-MaybeRelative $TestSourceDir
if (-not (Test-Path $TestSourceDir -PathType Container)) {
    Write-Error "Test source directory not found at $TestSourceDir. Must be an existing AS-watched directory."
    exit 1
}

# Derive __ExternalActors__ folder from the map path. UE places externals at
# <ContentRoot>/__ExternalActors__/<MapPath-relative-to-Content>/<MapName>/.
$mapDir = Split-Path $MapPath -Parent
$mapName = [System.IO.Path]::GetFileNameWithoutExtension($MapPath)
$contentRoot = $MapPath
while ($contentRoot -and (Split-Path $contentRoot -Leaf) -ne 'Content') {
    $contentRoot = Split-Path $contentRoot -Parent
}
if (-not $contentRoot) {
    Write-Error "Could not locate Content/ ancestor of map path: $MapPath"
    exit 1
}
$relativeUnderContent = Resolve-Path -Relative -Path $mapDir -RelativeBasePath $contentRoot
$relativeUnderContent = $relativeUnderContent -replace '^\.[\\/]?', '' -replace '\\', '/'
$externalsDir = Join-Path $contentRoot (Join-Path '__ExternalActors__' (Join-Path $relativeUnderContent $mapName))

# ---- Probe artifact paths ------------------------------------------------
$probeAsPath = Join-Path $TestSourceDir '_probe_lock_tolerance.as'
$sidecarDir = Join-Path $projectRoot 'Saved/AutoTestProbes'
$sidecarPath = Join-Path $sidecarDir 'lock_tolerance.json'

if (Test-Path $probeAsPath) {
    Write-Error "Probe AS file already exists at $probeAsPath — run _probe_lock_tolerance_restore.bat first."
    exit 1
}

# ---- Capture pre-state ---------------------------------------------------
function Capture-State {
    [hashtable]@{
        Hash       = (Get-FileHash $MapPath -Algorithm SHA256).Hash
        Size       = (Get-Item $MapPath).Length
        Count      = if (Test-Path $externalsDir) { (Get-ChildItem $externalsDir -Recurse -Filter '*.uasset' -ErrorAction SilentlyContinue).Count } else { 0 }
        LastWrite  = (Get-Item $MapPath).LastWriteTime
        IsReadOnly = (Get-ItemProperty $MapPath).IsReadOnly
    }
}

$pre = Capture-State

Write-Host ''
Write-Host 'Pre-state captured:' -ForegroundColor Yellow
Write-Host "  .umap path:               $MapPath"
Write-Host "  .umap SHA-256:            $($pre.Hash)"
Write-Host "  .umap size:               $($pre.Size) bytes"
Write-Host "  .umap LastWriteTime:      $($pre.LastWrite)"
Write-Host "  .umap IsReadOnly:         $($pre.IsReadOnly)  (FS-level lock indicator)"
Write-Host "  External-actor count:     $($pre.Count)"

# ---- Generate timestamped class name -------------------------------------
$timestamp = Get-Date -Format 'yyMMddHHmmss'
$className = "UCk_AutoTestProbeLockTolerance$timestamp"

# ---- Write probe AS file -------------------------------------------------
$asContent = @"
// Language=angelscript
//
// LOCK-TOLERANCE PROBE — auto-generated by
// CkAuto/AutoTestProbes/_probe_lock_tolerance.ps1.
//
// Sole purpose: drive the populator into spawning a new external-actor
// wrapper so we can observe whether the .umap on disk is touched.
//
// Safe to delete; _probe_lock_tolerance_restore.bat removes it.

class $className : UCk_AutoTest_Base
{
    UFUNCTION(BlueprintOverride)
    void DoBeginPlay(FCk_Handle InHandle)
    {
        FinishSuccess();
    }
}
"@
Set-Content -Path $probeAsPath -Value $asContent -Encoding UTF8
Write-Host ''
Write-Host "Probe AS dropped: $probeAsPath" -ForegroundColor Green
Write-Host "Class name:       $className"

# ---- Write sidecar -------------------------------------------------------
New-Item -ItemType Directory -Force -Path $sidecarDir | Out-Null
$sidecar = [ordered]@{
    Schema           = 1
    Generated        = (Get-Date).ToString('o')
    ProjectName      = $projectName
    ProjectRoot      = $projectRoot
    MapPath          = $MapPath
    ExternalsDir     = $externalsDir
    TestSourceDir    = $TestSourceDir
    ProbeAsPath      = $probeAsPath
    ClassName        = $className
    Pre              = $pre
}
$sidecar | ConvertTo-Json -Depth 5 | Set-Content -Path $sidecarPath -Encoding UTF8
Write-Host "Sidecar:          $sidecarPath"

# ---- Next-steps instructions ---------------------------------------------
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. The editor should pick up the new probe .as within ~2-3s and the'
Write-Host '     populator should run within ~5-10s.'
Write-Host "  2. Watch the editor's Output Log (filter to 'cktestseditor') for the"
Write-Host '     line: "[CkAutoTest Populator] [<MapConfig>] 1 spawned, ... Auto-saved."'
Write-Host ''
Write-Host '  3. Run the verifier:'
Write-Host "       pwsh CkAuto/AutoTestProbes/_probe_verify.ps1"
Write-Host ''
Write-Host '  4. Once verified, clean up:'
Write-Host "       CkAuto/AutoTestProbes/_probe_lock_tolerance_restore.bat"
Write-Host '     (full reset to pre-probe disk state also requires an editor restart)'
Write-Host ''
