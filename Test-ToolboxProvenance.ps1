<#
.SYNOPSIS
    Refuse to vendor an UnrealToolbox.exe whose source is not safely published. Run it BEFORE copying
    a new build into CkAuto.

.DESCRIPTION
    On 2026-08-22 toolbox v1.43/v1.44 were vendored here from commits that never reached the source
    repo's origin. On 2026-09-24 v1.48 was built from origin/dev, which did not contain them, and
    replaced them - silently deleting --project-prefix and two other features while the build-test
    skill kept documenting them. Each deploy was reasonable on its own; nothing compared them.

    This script compares them. It reads the source commit each binary was built from (`--version`,
    v1.49+; older binaries fall back to the "Built from ... `<sha>`" line of the last CkAuto commit that
    touched UnrealToolbox.exe) and refuses unless:

      1. the NEW binary names a clean commit (no "-dirty", not "unknown")         - its source exists;
      2. that commit is on the source repo's origin/dev                          - its source is published;
      3. the CURRENT binary's commit is an ancestor of the new one               - nothing it had is dropped.

    Exit 0 = safe to vendor. Exit 1 = refused (the reasons are printed). Exit 2 = could not check.
    -Force turns a refusal into exit 0 and prints the line to put in the deploy commit message; a
    forced deploy must say so where the next deployer will read it.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File CkAuto/Test-ToolboxProvenance.ps1 -NewExe ../FtxCatalyst_Build/apps/UnrealToolbox/Release/UnrealToolbox.exe

.NOTES
    Windows PowerShell 5.1 compatible (agents' `powershell` is 5.1). ASCII only.
#>
param(
    [Parameter(Mandatory = $true)] [string] $NewExe,
    [string] $CurrentExe,
    [string] $CurrentSha,      # override when the current binary predates --version and its commit message lacks a sha
    [string] $SourceRepo,      # FtxCatalyst (formerly FtxUiFramework) clone; default: $env:FTX_CATALYST_REPO or a sibling of the project
    [string] $SourceRef = 'origin/dev',   # the branch a vendored binary's source must be on
    [switch] $NoFetch,
    [switch] $Force
)

# 'Continue', not 'Stop': in Windows PowerShell 5.1 a native command's redirected stderr becomes an
# ErrorRecord, which 'Stop' turns into a terminating error. Every git call checks $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # $PSScriptRoot is empty in 5.1 param defaults

function Get-ExeVersionSha([string] $InExe) {
    if (-not (Test-Path -LiteralPath $InExe)) { return $null }
    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = (Resolve-Path -LiteralPath $InExe).Path
    $Psi.Arguments = '--version'
    $Psi.UseShellExecute = $false
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.CreateNoWindow = $true
    $Proc = [System.Diagnostics.Process]::Start($Psi)
    if (-not $Proc.WaitForExit(15000)) {
        # A pre-v1.49 binary may not know --version; never leave it running.
        try { $Proc.Kill() } catch { }
        return $null
    }
    $Text = $Proc.StandardOutput.ReadToEnd() + $Proc.StandardError.ReadToEnd()
    if ($Text -match 'git ([0-9a-f]{7,40}(-dirty)?|unknown)') { return $Matches[1] }
    return $null
}

function Get-DeployCommitSha([string] $InCkAutoDir) {
    $Body = & git -C $InCkAutoDir log -1 --format=%B -- UnrealToolbox.exe 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $Body) { return $null }
    $Joined = ($Body -join "`n")
    if ($Joined -match 'Built from [^`]*`([0-9a-f]{7,40})`') { return $Matches[1] }
    return $null
}

function Resolve-SourceRepo([string] $InExplicit) {
    $Candidates = @()
    if ($InExplicit) { $Candidates += $InExplicit }
    if ($env:FTX_CATALYST_REPO) { $Candidates += $env:FTX_CATALYST_REPO }
    # <ProjectParent>/<Project>/CkAuto -> look beside the project. A standalone CkAuto checkout has no
    # grandparent to look in; it needs -SourceRepo or FTX_CATALYST_REPO.
    $ProjectRoot = Split-Path -Parent $ScriptDir
    $ProjectParent = if ($ProjectRoot) { Split-Path -Parent $ProjectRoot } else { '' }
    if ($ProjectParent) {
        $Candidates += (Join-Path $ProjectParent 'FtxCatalyst'), (Join-Path $ProjectParent 'FtxUiFramework')
    }
    foreach ($C in $Candidates) {
        if (Test-Path -LiteralPath (Join-Path $C 'apps\UnrealToolbox\CMakeLists.txt')) { return (Resolve-Path -LiteralPath $C).Path }
    }
    return $null
}

function Test-GitCommit([string] $InRepo, [string] $InSha) {
    & git -C $InRepo cat-file -e "$InSha^{commit}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitAncestor([string] $InRepo, [string] $InAncestor, [string] $InDescendant) {
    & git -C $InRepo merge-base --is-ancestor $InAncestor $InDescendant 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (-not $CurrentExe) { $CurrentExe = Join-Path $ScriptDir 'UnrealToolbox.exe' }

$Repo = Resolve-SourceRepo $SourceRepo
if (-not $Repo) {
    Write-Host "[provenance] ERROR: cannot find the toolbox source repo. Pass -SourceRepo <FtxCatalyst clone> or set FTX_CATALYST_REPO."
    exit 2
}

$NewSha = Get-ExeVersionSha $NewExe
if (-not $NewSha) {
    Write-Host "[provenance] ERROR: '$NewExe' did not report a source commit via --version (needs toolbox v1.49+)."
    exit 2
}

if (-not $CurrentSha) {
    $CurrentSha = Get-ExeVersionSha $CurrentExe
    $CurrentFrom = '--version'
    if (-not $CurrentSha) {
        $CurrentSha = Get-DeployCommitSha $ScriptDir
        $CurrentFrom = 'the last CkAuto deploy commit message'
    }
} else {
    $CurrentFrom = '-CurrentSha'
}

if (-not $NoFetch) {
    & git -C $Repo fetch --quiet origin 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "[provenance] WARNING: 'git fetch origin' failed in $Repo; checking against the local $SourceRef." }
}

Write-Host "[provenance] source repo : $Repo"
Write-Host "[provenance] new binary  : $NewSha"
if ($CurrentSha) { Write-Host "[provenance] current     : $CurrentSha (from $CurrentFrom)" }
else             { Write-Host "[provenance] current     : unknown" }

$Refusals = @()

if ($NewSha -eq 'unknown') {
    $Refusals += "the new binary was built without git metadata - its source cannot be identified."
} elseif ($NewSha.EndsWith('-dirty')) {
    $Refusals += "the new binary was built from a tree with uncommitted edits ($NewSha) - that code is in no commit. Commit, push, rebuild."
} elseif (-not (Test-GitCommit $Repo $NewSha)) {
    $Refusals += "the new binary's commit $NewSha is not in $Repo - its source was never shared with this clone."
} elseif (-not (Test-GitAncestor $Repo $NewSha $SourceRef)) {
    $Refusals += "the new binary's commit $NewSha is not on $SourceRef - push (or merge) the source before vendoring the binary."
}

$NewClean = $NewSha -replace '-dirty$', ''
if (-not $CurrentSha) {
    $Refusals += "cannot tell which commit the current binary came from - pass -CurrentSha after checking by hand what it contains."
} else {
    $CurClean = $CurrentSha -replace '-dirty$', ''
    if ($CurClean -eq 'unknown' -or -not (Test-GitCommit $Repo $CurClean)) {
        $Refusals += "the current binary's commit $CurrentSha is not in $Repo - replacing it would drop whatever it contains (how v1.43/v1.44 were lost). Recover that source first."
    } elseif ((Test-GitCommit $Repo $NewClean) -and -not (Test-GitAncestor $Repo $CurClean $NewClean)) {
        $Refusals += "the current binary's commit $CurClean is not an ancestor of $NewClean - the new build does not contain everything the current one does."
    }
}

if ($Refusals.Count -eq 0) {
    Write-Host "[provenance] OK - source is on $SourceRef and contains the current binary's commit."
    exit 0
}

foreach ($R in $Refusals) { Write-Host "[provenance] REFUSED: $R" }
if ($Force) {
    Write-Host "[provenance] -Force given. Put this line in the deploy commit message:"
    Write-Host "  Provenance check overridden: $($Refusals -join ' ')"
    exit 0
}
exit 1
