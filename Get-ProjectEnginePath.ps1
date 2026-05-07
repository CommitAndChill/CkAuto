# Resolves the Unreal Engine root for the project containing this script.
#
# Looks at the project's .uproject EngineAssociation field:
#   - If a GUID, queries HKCU/HKLM "Epic Games\Unreal Engine\Builds\<GUID>".
#   - If a path, returns it (resolved relative to the .uproject if not rooted).
#   - Empty / missing -> error.
#
# Prints the engine root to stdout. On failure: writes a diagnostic to stderr
# and exits with code 1.
#
# Used by build invocations so callers don't have to hardcode the engine path:
#   $engine = & "$env:CLAUDE_PROJECT_DIR\CkAuto\Get-ProjectEnginePath.ps1"
#   & "$engine\Engine\Build\BatchFiles\Build.bat" <Target> Win64 Development `
#       -Project="<full path to .uproject>" -WaitMutex -FromMsBuild

[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Find-ProjectRoot([string]$StartDir) {
    if (-not $StartDir) { return $null }
    $dir = $StartDir
    while ($dir -and -not (Get-ChildItem -LiteralPath $dir -Filter '*.uproject' -ErrorAction SilentlyContinue)) {
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
    return $dir
}

# ---- 1. Resolve project root ----------------------------------------------
if (-not $ProjectRoot) {
    if ($env:CLAUDE_PROJECT_DIR -and (Test-Path -LiteralPath $env:CLAUDE_PROJECT_DIR)) {
        $ProjectRoot = Find-ProjectRoot $env:CLAUDE_PROJECT_DIR
    }
}
if (-not $ProjectRoot) {
    $ProjectRoot = Find-ProjectRoot (Split-Path -Parent $PSCommandPath)
}
if (-not $ProjectRoot -or -not (Test-Path -LiteralPath $ProjectRoot)) {
    Fail "Could not locate a project root containing a .uproject (searched CLAUDE_PROJECT_DIR and walked up from script location)."
}

# ---- 2. Read the .uproject ------------------------------------------------
$uproject = Get-ChildItem -LiteralPath $ProjectRoot -Filter '*.uproject' -File | Select-Object -First 1
if (-not $uproject) { Fail "No .uproject file found in '$ProjectRoot'." }

try {
    $manifest = Get-Content -LiteralPath $uproject.FullName -Raw | ConvertFrom-Json
} catch {
    Fail "Failed to parse '$($uproject.FullName)': $_"
}

$assoc = $manifest.EngineAssociation
if (-not $assoc) { Fail "EngineAssociation is empty in '$($uproject.FullName)'." }

# ---- 3. Resolve EngineAssociation -----------------------------------------
$enginePath = $null

# GUID form: lookup in registry
if ($assoc -match '^\{[0-9A-Fa-f-]+\}$') {
    $regRoots = @(
        'HKCU:\Software\Epic Games\Unreal Engine\Builds',
        'HKLM:\SOFTWARE\Epic Games\Unreal Engine\Builds'
    )
    foreach ($regRoot in $regRoots) {
        if (-not (Test-Path -LiteralPath $regRoot)) { continue }
        $entry = Get-ItemProperty -LiteralPath $regRoot -ErrorAction SilentlyContinue
        if ($entry -and $entry.PSObject.Properties.Name -contains $assoc) {
            $enginePath = $entry.$assoc
            break
        }
    }
    if (-not $enginePath) {
        Fail "EngineAssociation '$assoc' not found in HKCU or HKLM 'Epic Games\Unreal Engine\Builds'. Register the engine via the .uproject right-click 'Switch Unreal Engine version', or run GenerateProjectFiles."
    }
} else {
    # Path form: absolute or relative to the .uproject directory
    if ([System.IO.Path]::IsPathRooted($assoc)) {
        $enginePath = $assoc
    } else {
        $enginePath = Join-Path $ProjectRoot $assoc
    }
}

if (-not (Test-Path -LiteralPath $enginePath)) {
    Fail "Resolved engine path does not exist: '$enginePath' (from EngineAssociation '$assoc')."
}

# Sanity-check: Engine\Build\BatchFiles\Build.bat should live under here.
$buildBat = Join-Path $enginePath 'Engine\Build\BatchFiles\Build.bat'
if (-not (Test-Path -LiteralPath $buildBat)) {
    Fail "Resolved engine root '$enginePath' does not contain Engine\Build\BatchFiles\Build.bat."
}

# Normalize and emit
(Resolve-Path -LiteralPath $enginePath).Path
