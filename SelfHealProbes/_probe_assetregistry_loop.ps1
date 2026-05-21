#requires -Version 7
<#
.SYNOPSIS
    Probe C — drops a single-strategy AR-only trigger AS file. Pairs with
    `_probe_verify.ps1 assetregistry_loop`, which asserts AR-sibling
    deletion happens AFTER the regen ticker runs (post-fix) vs BEFORE
    (pre-fix). Editor MUST be running.
#>

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$uproject = Get-ChildItem -Path $projectRoot -Filter '*.uproject' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uproject) {
    Write-Error "No .uproject found at $projectRoot."
    exit 1
}
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($uproject.Name)
$genDir = Join-Path $projectRoot 'Script\Generated'

Write-Host "Project: $projectName ($projectRoot)" -ForegroundColor Cyan

$asPath = Join-Path $projectRoot 'Script\_probe_assetregistry_loop.as'
$sidecar = Join-Path $projectRoot 'Script\_probe_assetregistry_loop.targets.json'

if (Test-Path $asPath) {
    Write-Error "Probe AS file already exists: $asPath — run _probe_assetregistry_loop_restore.bat first."
    exit 1
}

# ---- Editor-running advisory (Probe C *needs* the editor running) ----
$logDir = Join-Path $projectRoot 'Saved\Logs'
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
    Write-Warning "No $projectName*.log file is locked — editor may not be running. Probe C requires a running editor."
}

# ---- Pick an unaccessed asset (parse Discovery roots from *Assets.as) ----
# The ordering assertion in the verifier doesn't care whether the picked
# accessor's class is emitted by the project's UCkAssetRegistryConfig — it
# only needs SOME assets::X() that fails to resolve. _BP / _BP_C suffixes
# are skipped because Blueprint parent-class resolution defeats Tier 1/2 AR
# stub synthesis (hits the Tier 3 refusal correctly — that's a different
# code path, not the one we're testing).
$pickedAsset = $null
$arFiles = Get-ChildItem -Path $genDir -Filter '*Assets.as' -File -ErrorAction SilentlyContinue
if ($arFiles) {
    $accessorRegex = [regex]'(?m)^\s*TSoftObjectPtr<\w+>\s+(\w+)\s*\(\s*\)'
    $existing = @{}
    foreach ($f in $arFiles) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in $accessorRegex.Matches($txt)) {
            $existing[$m.Groups[1].Value] = $true
        }
    }
    $discoveryRegex = [regex]'// Discovery root: (/[^\s\r\n]+)'
    $scanDirs = @()
    foreach ($f in $arFiles) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in $discoveryRegex.Matches($txt)) {
            $root = $m.Groups[1].Value
            if ($root -match '^/Game/(.+)') {
                $diskPath = Join-Path $projectRoot "Content\$($matches[1])"
                if (Test-Path $diskPath) { $scanDirs += $diskPath }
            }
        }
    }
    foreach ($d in $scanDirs) {
        $files = Get-ChildItem -Path $d -Recurse -Filter '*.uasset' -ErrorAction SilentlyContinue | Select-Object -First 5000
        foreach ($u in $files) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($u.Name)
            if ($stem -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ($existing.ContainsKey($stem)) { continue }
            if ($stem -match '_BP$|_BP_C$') { continue }
            $pickedAsset = $stem
            break
        }
        if ($pickedAsset) { break }
    }
}

if (-not $pickedAsset) {
    Write-Error "Probe C requires an unaccessed asset under a /Game/<X>/ discovery root, but none was found. Either this project has no AR configs, or every discovered asset already has an accessor in *Assets.as."
    exit 1
}

# ---- Build AS body — AR strategy ONLY ----
# Class has no ExposeOnSpawn (no ESP stub), no handle field (no DH stub).
# Body wraps assets::X() in a UClass method so AS reliably compiles it.
$probeStamp = (Get-Date -Format 'yyMMddHHmmss')
$className = "UCk_ProbeAssetRegistryLoop${probeStamp}_EntityScript"

$asLines = @(
    "// Probe C — AssetRegistry stub-deletion-loop trigger."
    "// Stamp: $probeStamp"
    "// Restore: CkAuto\SelfHealProbes\_probe_assetregistry_loop_restore.bat"
    ''
    "class $className : UCk_GenericEntityScript_UE"
    '{'
    '    UFUNCTION(BlueprintOverride)'
    '    ECk_EntityScript_ConstructionFlow DoConstruct(FCk_Handle& InHandle)'
    '    {'
    '        // Single unresolved accessor — triggers ONLY the AR strategy.'
    "        auto SoftRef = assets::${pickedAsset}();"
    '        return ECk_EntityScript_ConstructionFlow::Finished;'
    '    }'
    '}'
    ''
)
$asBody = ($asLines -join "`r`n")
[System.IO.File]::WriteAllText($asPath, $asBody, [System.Text.UTF8Encoding]::new($false))

$targets = [ordered]@{
    ProjectName = $projectName
    AssetName   = $pickedAsset
    ClassName   = $className
    ProbeStamp  = $probeStamp
}
$targets | ConvertTo-Json | Set-Content -Path $sidecar -Encoding UTF8

Write-Host "Probe C written: $asPath"
Write-Host "  - PickedAsset: $pickedAsset"
Write-Host "  - ClassName:   $className"
Write-Host "  - Sidecar:     $sidecar"
Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. Watch Saved/Logs/$projectName*.log — wait ~30s after the first 'Asset Registry generation completed' line."
Write-Host '  2. pwsh _probe_verify.ps1 assetregistry_loop -Tail'
Write-Host '  3. _probe_assetregistry_loop_restore.bat'
