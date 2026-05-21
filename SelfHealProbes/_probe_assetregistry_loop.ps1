#requires -Version 7
<#
.SYNOPSIS
    Probe C: AssetRegistry stub-deletion-loop reproduction.

.DESCRIPTION
    Drops an AS file referencing exactly ONE unresolved asset accessor — no
    class, no handle. The minimal trigger for the post-2026-05-21 self-heal
    PostCompile-ordering bug where Delete_AllStubRecoveryFiles runs
    synchronously before Maybe_RegenAssetRegistry_OnPostCompile's deferred
    FTSTicker has actually rewritten the canonical *Assets.as.

    On a buggy CkFoundation, the sequence is:
      1. AS compile fails (asset not in canonical).
      2. Self-heal synthesizes _StubRecovery_*Assets.as.
      3. AS compile succeeds via merged stub namespace.
      4. PostCompile lambda queues deferred AR regen, then SYNCHRONOUSLY
         deletes the stub sibling.
      5. Hot-reload sees mtime change, recompiles. Canonical hasn't been
         rewritten yet (ticker hasn't fired), so AS fails again.
      6. Mid-session cycle 2 fires. Stub re-synthesized. Loop.

    The verifier (`_probe_verify.ps1 assetregistry_loop`) detects the loop by
    counting `OnReloadHadErrors fired (mid-session mode, cycle X of 3)` lines
    after the first `Asset Registry generation completed`. >0 such lines =
    bug present = PROBE FAIL.

.NOTES
    Editor MUST already be running (same lifecycle requirement as Probe B).
    Run `_probe_assetregistry_loop_restore.bat` afterward.
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
# Shared logic with _probe_mid_session_add — kept inline to avoid coupling
# the two probes. Diverge if either probe's requirements drift.
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
    Write-Error "Probe C requires an unaccessed asset under a /Game/<X>/ discovery root, but none was found. Either this project has no AR configs, or every discovered asset already has an accessor in *Assets.as. Probe cannot trigger the AssetRegistry path without a target."
    exit 1
}

# ---- Build AS body — AR strategy ONLY ----
# A single-strategy probe makes the loop-detection assertions in the verifier
# unambiguous. With multi-strategy (the mid_session_add probe), interleaved
# DH/ESP recovery events would dilute the AR-specific timeline.
#
# We wrap the assets::X() call inside an entity script method to guarantee
# AS compiles it (UClass reflection emits all methods of registered classes,
# unlike namespace-scoped free functions where dead-strip behavior is harder
# to reason about). The class itself has no ExposeOnSpawn properties — no
# Params() call → no EntitySpawnParams strategy triggered. No handle field →
# no DynamicHandle strategy. Only AR.
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
